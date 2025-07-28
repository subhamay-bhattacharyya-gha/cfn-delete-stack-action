#!/bin/bash

# Real-time CloudFormation event monitoring for stack deletion action
# Provides continuous polling and display of CloudFormation stack events

set -euo pipefail

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Event monitoring configuration
readonly DEFAULT_POLL_INTERVAL=5
readonly MAX_EVENTS_PER_POLL=50
readonly EVENT_DISPLAY_WIDTH=120

# Event status colors for better visibility
readonly STATUS_COLOR_SUCCESS='\033[0;32m'    # Green
readonly STATUS_COLOR_FAILED='\033[0;31m'     # Red
readonly STATUS_COLOR_IN_PROGRESS='\033[0;33m' # Yellow
readonly STATUS_COLOR_INFO='\033[0;36m'       # Cyan
readonly STATUS_COLOR_RESET='\033[0m'         # Reset

# Stack completion states
readonly COMPLETION_STATES=(
    "DELETE_COMPLETE"
    "DELETE_FAILED"
    "CREATE_COMPLETE"
    "UPDATE_COMPLETE"
    "ROLLBACK_COMPLETE"
    "CREATE_FAILED"
    "UPDATE_FAILED"
    "ROLLBACK_FAILED"
)

# Get stack events since a specific timestamp with enhanced error handling
get_stack_events_since() {
    local stack_name="$1"
    local since_timestamp="$2"
    local region="${3:-}"
    
    log_debug "Fetching events for stack '$stack_name' since '$since_timestamp'"
    
    # Build AWS CLI command with optional region
    local aws_cmd="aws cloudformation describe-stack-events --stack-name '$stack_name' --output json"
    if [[ -n "$region" ]]; then
        aws_cmd="$aws_cmd --region '$region'"
    fi
    
    # Execute command with enhanced retry logic and timeout
    local result
    result=$(retry_aws_operation_with_backoff "$aws_cmd" "Get stack events for '$stack_name'" 5 1 30 120)
    local exit_code=$?
    
    # Handle the result using enhanced error handling
    if ! handle_aws_operation_error "$exit_code" "$result" "Get stack events" "$stack_name"; then
        # Check if stack doesn't exist (which is expected for completed deletions)
        if [[ "$result" =~ "does not exist" ]] || [[ "$result" =~ "ValidationError" ]]; then
            log_debug "Stack '$stack_name' no longer exists - deletion completed"
            echo "[]"
            return 0
        else
            log_debug "Failed to get stack events: $(format_aws_error_message "$result")"
            echo "[]"
            return 1
        fi
    fi
    
    # Filter events since the specified timestamp using jq
    local filtered_events
    if [[ -n "$since_timestamp" ]] && [[ "$since_timestamp" != "null" ]]; then
        filtered_events=$(echo "$result" | jq --arg since "$since_timestamp" '
            .StackEvents 
            | map(select(.Timestamp > $since))
            | sort_by(.Timestamp)
        ')
    else
        # If no timestamp provided, get all events (sorted by timestamp)
        filtered_events=$(echo "$result" | jq '.StackEvents | sort_by(.Timestamp)')
    fi
    
    echo "$filtered_events"
    return 0
}

# Format and display a single CloudFormation event
format_and_display_event() {
    local event_json="$1"
    
    # Extract event details using jq
    local timestamp logical_id resource_type resource_status status_reason
    timestamp=$(echo "$event_json" | jq -r '.Timestamp // "N/A"')
    logical_id=$(echo "$event_json" | jq -r '.LogicalResourceId // "N/A"')
    resource_type=$(echo "$event_json" | jq -r '.ResourceType // "N/A"')
    resource_status=$(echo "$event_json" | jq -r '.ResourceStatus // "N/A"')
    status_reason=$(echo "$event_json" | jq -r '.ResourceStatusReason // ""')
    
    # Format timestamp for display
    local display_timestamp
    if [[ "$timestamp" != "N/A" ]]; then
        # Convert ISO timestamp to readable format
        display_timestamp=$(date -d "$timestamp" '+%H:%M:%S' 2>/dev/null || echo "$timestamp")
    else
        display_timestamp="--:--:--"
    fi
    
    # Choose color based on resource status
    local status_color="$STATUS_COLOR_RESET"
    case "$resource_status" in
        *"COMPLETE")
            status_color="$STATUS_COLOR_SUCCESS"
            ;;
        *"FAILED")
            status_color="$STATUS_COLOR_FAILED"
            ;;
        *"IN_PROGRESS")
            status_color="$STATUS_COLOR_IN_PROGRESS"
            ;;
        *)
            status_color="$STATUS_COLOR_INFO"
            ;;
    esac
    
    # Format the event line with proper spacing
    local resource_info="${resource_type}/${logical_id}"
    local status_display="${status_color}${resource_status}${STATUS_COLOR_RESET}"
    
    # Truncate long resource info and status reason if needed
    if [[ ${#resource_info} -gt 50 ]]; then
        resource_info="${resource_info:0:47}..."
    fi
    
    if [[ -n "$status_reason" ]] && [[ ${#status_reason} -gt 60 ]]; then
        status_reason="${status_reason:0:57}..."
    fi
    
    # Display the formatted event
    printf "  %s  %-50s  %s" "$display_timestamp" "$resource_info" "$status_display" >&2
    if [[ -n "$status_reason" ]]; then
        printf "  %s" "$status_reason" >&2
    fi
    printf "\n" >&2
}

# Display events header
display_events_header() {
    local stack_name="$1"
    
    print_section "CloudFormation Events for Stack: $stack_name"
    printf "  %-8s  %-50s  %-20s  %s\n" "Time" "Resource" "Status" "Reason" >&2
    printf "  %s\n" "$(printf '=%.0s' $(seq 1 $EVENT_DISPLAY_WIDTH))" >&2
}

# Check if stack has reached a completion state
is_stack_in_completion_state() {
    local stack_status="$1"
    
    for completion_state in "${COMPLETION_STATES[@]}"; do
        if [[ "$stack_status" == "$completion_state" ]]; then
            return 0
        fi
    done
    return 1
}

# Get current stack status for monitoring completion with enhanced error handling
get_current_stack_status() {
    local stack_name="$1"
    local region="${2:-}"
    
    # Build AWS CLI command
    local aws_cmd="aws cloudformation describe-stacks --stack-name '$stack_name' --query 'Stacks[0].StackStatus' --output text"
    if [[ -n "$region" ]]; then
        aws_cmd="$aws_cmd --region '$region'"
    fi
    
    # Execute command with enhanced retry logic
    local result
    result=$(retry_aws_operation_with_backoff "$aws_cmd" "Get stack status for '$stack_name'" 3 1 15 60)
    local exit_code=$?
    
    # Handle the result using enhanced error handling
    if ! handle_aws_operation_error "$exit_code" "$result" "Get stack status" "$stack_name"; then
        # Check if stack doesn't exist
        if [[ "$result" =~ "does not exist" ]] || [[ "$result" =~ "ValidationError" ]]; then
            echo "STACK_NOT_FOUND"
            return 0
        else
            log_debug "Failed to get stack status: $(format_aws_error_message "$result")"
            echo "UNKNOWN"
            return 1
        fi
    fi
    
    echo "$result"
    return 0
}

# Monitor stack events with real-time polling
monitor_stack_events() {
    local stack_name="$1"
    local region="${2:-}"
    local poll_interval="${3:-$DEFAULT_POLL_INTERVAL}"
    local max_duration="${4:-3600}"  # Default 1 hour timeout
    
    log_info "Starting real-time event monitoring for stack '$stack_name'"
    log_info "Poll interval: ${poll_interval}s, Max duration: ${max_duration}s"
    
    # Display events header
    display_events_header "$stack_name"
    
    # Initialize tracking variables
    local last_event_timestamp=""
    local start_time
    start_time=$(date +%s)
    local events_displayed=0
    local monitoring_active=true
    
    # Main monitoring loop
    while [[ "$monitoring_active" == true ]]; do
        # Check if we've exceeded maximum duration
        local current_time
        current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        
        if [[ $elapsed_time -gt $max_duration ]]; then
            log_warning "Monitoring timeout reached (${max_duration}s), stopping event monitoring"
            echo "MONITORING_RESULT=timeout"
            echo "EVENTS_DISPLAYED=$events_displayed"
            echo "FINAL_STATUS=timeout"
            return 1
        fi
        
        # Get current stack status to check for completion
        local current_status
        current_status=$(get_current_stack_status "$stack_name" "$region")
        local status_exit_code=$?
        
        if [[ $status_exit_code -eq 0 ]]; then
            # Check if stack has reached completion state
            if [[ "$current_status" == "STACK_NOT_FOUND" ]]; then
                log_success "Stack '$stack_name' has been successfully deleted"
                monitoring_active=false
                echo "MONITORING_RESULT=completed"
                echo "EVENTS_DISPLAYED=$events_displayed"
                echo "FINAL_STATUS=DELETE_COMPLETE"
                break
            elif is_stack_in_completion_state "$current_status"; then
                log_info "Stack '$stack_name' has reached completion state: $current_status"
                monitoring_active=false
                echo "MONITORING_RESULT=completed"
                echo "EVENTS_DISPLAYED=$events_displayed"
                echo "FINAL_STATUS=$current_status"
                break
            fi
        else
            log_debug "Could not determine stack status, continuing monitoring"
        fi
        
        # Get new events since last check
        local events_json
        events_json=$(get_stack_events_since "$stack_name" "$last_event_timestamp" "$region")
        local events_exit_code=$?
        
        if [[ $events_exit_code -eq 0 ]]; then
            # Process and display new events
            local event_count
            event_count=$(echo "$events_json" | jq 'length')
            
            if [[ "$event_count" -gt 0 ]]; then
                log_debug "Found $event_count new events"
                
                # Display each event
                local i=0
                while [[ $i -lt $event_count ]]; do
                    local event
                    event=$(echo "$events_json" | jq ".[$i]")
                    format_and_display_event "$event"
                    
                    # Update last event timestamp
                    local event_timestamp
                    event_timestamp=$(echo "$event" | jq -r '.Timestamp')
                    if [[ "$event_timestamp" != "null" ]]; then
                        last_event_timestamp="$event_timestamp"
                    fi
                    
                    ((events_displayed++))
                    ((i++))
                done
            else
                log_debug "No new events found"
            fi
        else
            log_warning "Failed to retrieve events, continuing monitoring"
        fi
        
        # Wait before next poll (unless we're stopping)
        if [[ "$monitoring_active" == true ]]; then
            sleep "$poll_interval"
        fi
    done
    
    # Final summary
    local total_duration
    total_duration=$(format_duration "$start_time" "$(date +%s)")
    log_info "Event monitoring completed. Duration: $total_duration, Events displayed: $events_displayed"
    
    return 0
}

# Monitor stack events with timeout and error handling
monitor_stack_events_with_timeout() {
    local stack_name="$1"
    local region="${2:-}"
    local poll_interval="${3:-$DEFAULT_POLL_INTERVAL}"
    local timeout_minutes="${4:-60}"
    
    local timeout_seconds=$((timeout_minutes * 60))
    
    print_header "Real-time Stack Event Monitoring"
    
    # Validate inputs
    if [[ -z "$stack_name" ]]; then
        handle_validation_error "Stack name is required for event monitoring"
    fi
    
    if [[ $poll_interval -lt 1 ]] || [[ $poll_interval -gt 60 ]]; then
        handle_validation_error "Poll interval must be between 1 and 60 seconds"
    fi
    
    # Start monitoring with error handling
    local monitoring_result
    monitoring_result=$(monitor_stack_events "$stack_name" "$region" "$poll_interval" "$timeout_seconds")
    local monitoring_exit_code=$?
    
    # Parse and return results
    echo "$monitoring_result"
    return $monitoring_exit_code
}

# Utility function to retry AWS operations with exponential backoff (enhanced version)
retry_aws_operation() {
    local command="$1"
    local operation_name="$2"
    local max_attempts="${3:-3}"
    local base_delay="${4:-2}"
    
    # Use the enhanced retry function from utils.sh
    retry_aws_operation_with_backoff "$command" "$operation_name" "$max_attempts" "$base_delay" 60 300
}

# Export functions for use in other scripts
export -f get_stack_events_since format_and_display_event display_events_header
export -f is_stack_in_completion_state get_current_stack_status
export -f monitor_stack_events monitor_stack_events_with_timeout

# Execute monitoring if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <stack-name> [aws-region] [poll-interval] [timeout-minutes]"
        echo ""
        echo "Arguments:"
        echo "  stack-name        Name of the CloudFormation stack to monitor"
        echo "  aws-region        AWS region (optional, uses default if not specified)"
        echo "  poll-interval     Polling interval in seconds (default: 5, range: 1-60)"
        echo "  timeout-minutes   Maximum monitoring duration in minutes (default: 60)"
        echo ""
        echo "Examples:"
        echo "  $0 my-stack"
        echo "  $0 my-stack us-west-2"
        echo "  $0 my-stack us-west-2 10 30"
        exit 1
    fi
    
    monitor_stack_events_with_timeout "$@"
fi
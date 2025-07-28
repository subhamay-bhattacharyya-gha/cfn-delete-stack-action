#!/bin/bash

# Completion detection and status reporting for CloudFormation stack deletion action
# Provides functions to detect deletion completion, track timing, and report final status

set -euo pipefail

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Completion state constants
readonly COMPLETION_SUCCESS_STATES=(
    "DELETE_COMPLETE"
)

readonly COMPLETION_FAILURE_STATES=(
    "DELETE_FAILED"
    "CREATE_FAILED"
    "UPDATE_FAILED"
    "ROLLBACK_FAILED"
)

readonly COMPLETION_STABLE_STATES=(
    "CREATE_COMPLETE"
    "UPDATE_COMPLETE"
    "ROLLBACK_COMPLETE"
)

readonly ALL_COMPLETION_STATES=(
    "${COMPLETION_SUCCESS_STATES[@]}"
    "${COMPLETION_FAILURE_STATES[@]}"
    "${COMPLETION_STABLE_STATES[@]}"
)

# Stack not found is considered successful deletion
readonly STACK_NOT_FOUND_STATE="STACK_NOT_FOUND"

# Check if a stack status indicates successful deletion completion
is_deletion_successful() {
    local stack_status="$1"
    
    # Stack not found means successful deletion
    if [[ "$stack_status" == "$STACK_NOT_FOUND_STATE" ]]; then
        return 0
    fi
    
    # Check against success states
    for success_state in "${COMPLETION_SUCCESS_STATES[@]}"; do
        if [[ "$stack_status" == "$success_state" ]]; then
            return 0
        fi
    done
    
    return 1
}

# Check if a stack status indicates failed deletion
is_deletion_failed() {
    local stack_status="$1"
    
    # Check against failure states
    for failure_state in "${COMPLETION_FAILURE_STATES[@]}"; do
        if [[ "$stack_status" == "$failure_state" ]]; then
            return 0
        fi
    done
    
    return 1
}

# Check if a stack status indicates completion (success or failure)
is_deletion_completed() {
    local stack_status="$1"
    
    # Stack not found means completed
    if [[ "$stack_status" == "$STACK_NOT_FOUND_STATE" ]]; then
        return 0
    fi
    
    # Check against all completion states
    for completion_state in "${ALL_COMPLETION_STATES[@]}"; do
        if [[ "$stack_status" == "$completion_state" ]]; then
            return 0
        fi
    done
    
    return 1
}

# Get current stack status for completion monitoring
get_stack_status_for_completion() {
    local stack_name="$1"
    local region="${2:-}"
    
    log_debug "Checking stack status for completion monitoring: $stack_name"
    
    # Build AWS CLI command
    local aws_cmd="aws cloudformation describe-stacks --stack-name '$stack_name' --query 'Stacks[0].StackStatus' --output text"
    if [[ -n "$region" ]]; then
        aws_cmd="$aws_cmd --region '$region'"
    fi
    
    # Execute command with error handling
    local result
    local exit_code
    
    result=$(eval "$aws_cmd" 2>&1)
    exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        echo "$result"
        return 0
    else
        # Check if stack doesn't exist (successful deletion)
        if [[ "$result" =~ "does not exist" ]] || [[ "$result" =~ "ValidationError" ]]; then
            echo "$STACK_NOT_FOUND_STATE"
            return 0
        else
            log_debug "Failed to get stack status: $result"
            echo "UNKNOWN"
            return 1
        fi
    fi
}

# Monitor stack for completion with timeout and status tracking
monitor_deletion_completion() {
    local stack_name="$1"
    local region="${2:-}"
    local timeout_seconds="${3:-3600}"  # Default 1 hour
    local poll_interval="${4:-10}"      # Default 10 seconds
    
    log_info "Starting deletion completion monitoring for stack '$stack_name'"
    log_info "Timeout: ${timeout_seconds}s, Poll interval: ${poll_interval}s"
    
    # Initialize tracking variables
    local start_time
    start_time=$(date +%s)
    local last_status=""
    local status_change_count=0
    local consecutive_failures=0
    local max_consecutive_failures=3
    
    # Main monitoring loop
    while true; do
        local current_time
        current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        
        # Check timeout
        if [[ $elapsed_time -gt $timeout_seconds ]]; then
            log_error "Completion monitoring timeout reached (${timeout_seconds}s)"
            echo "COMPLETION_RESULT=timeout"
            echo "FINAL_STATUS=timeout"
            echo "ELAPSED_TIME=$elapsed_time"
            echo "STATUS_CHANGES=$status_change_count"
            return 1
        fi
        
        # Get current stack status
        local current_status
        current_status=$(get_stack_status_for_completion "$stack_name" "$region")
        local status_exit_code=$?
        
        if [[ $status_exit_code -eq 0 ]]; then
            consecutive_failures=0
            
            # Track status changes
            if [[ "$current_status" != "$last_status" ]] && [[ -n "$last_status" ]]; then
                log_info "Stack status changed: $last_status -> $current_status"
                ((status_change_count++))
            fi
            last_status="$current_status"
            
            # Check for completion
            if is_deletion_completed "$current_status"; then
                local completion_time
                completion_time=$(date +%s)
                local total_duration=$((completion_time - start_time))
                
                if is_deletion_successful "$current_status"; then
                    log_success "Stack deletion completed successfully"
                    echo "COMPLETION_RESULT=success"
                    echo "FINAL_STATUS=$current_status"
                    echo "ELAPSED_TIME=$total_duration"
                    echo "STATUS_CHANGES=$status_change_count"
                    return 0
                else
                    log_error "Stack deletion failed with status: $current_status"
                    echo "COMPLETION_RESULT=failed"
                    echo "FINAL_STATUS=$current_status"
                    echo "ELAPSED_TIME=$total_duration"
                    echo "STATUS_CHANGES=$status_change_count"
                    return 1
                fi
            else
                log_debug "Stack still in progress state: $current_status"
            fi
        else
            ((consecutive_failures++))
            log_warning "Failed to get stack status (attempt $consecutive_failures/$max_consecutive_failures)"
            
            if [[ $consecutive_failures -ge $max_consecutive_failures ]]; then
                log_error "Too many consecutive failures getting stack status"
                echo "COMPLETION_RESULT=error"
                echo "FINAL_STATUS=status_check_failed"
                echo "ELAPSED_TIME=$elapsed_time"
                echo "STATUS_CHANGES=$status_change_count"
                return 1
            fi
        fi
        
        # Wait before next poll
        sleep "$poll_interval"
    done
}

# Wait for deletion completion with comprehensive tracking
wait_for_deletion_completion() {
    local stack_name="$1"
    local region="${2:-}"
    local timeout_minutes="${3:-60}"
    local poll_interval="${4:-10}"
    
    print_section "Waiting for Deletion Completion"
    
    # Validate inputs
    if [[ -z "$stack_name" ]]; then
        handle_validation_error "Stack name is required for completion monitoring"
    fi
    
    if [[ $timeout_minutes -lt 1 ]] || [[ $timeout_minutes -gt 1440 ]]; then
        handle_validation_error "Timeout must be between 1 and 1440 minutes"
    fi
    
    if [[ $poll_interval -lt 5 ]] || [[ $poll_interval -gt 300 ]]; then
        handle_validation_error "Poll interval must be between 5 and 300 seconds"
    fi
    
    local timeout_seconds=$((timeout_minutes * 60))
    
    # Start monitoring
    local monitoring_result
    monitoring_result=$(monitor_deletion_completion "$stack_name" "$region" "$timeout_seconds" "$poll_interval")
    local monitoring_exit_code=$?
    
    # Parse and return results
    echo "$monitoring_result"
    return $monitoring_exit_code
}

# Get detailed completion status information
get_completion_status_details() {
    local stack_name="$1"
    local region="${2:-}"
    
    log_debug "Getting detailed completion status for stack '$stack_name'"
    
    # Get current stack status
    local current_status
    current_status=$(get_stack_status_for_completion "$stack_name" "$region")
    local status_exit_code=$?
    
    if [[ $status_exit_code -ne 0 ]]; then
        echo "STATUS=UNKNOWN"
        echo "IS_COMPLETED=false"
        echo "IS_SUCCESSFUL=false"
        echo "IS_FAILED=false"
        echo "ERROR=Failed to get stack status"
        return 1
    fi
    
    # Analyze status
    local is_completed is_successful is_failed
    
    if is_deletion_completed "$current_status"; then
        is_completed="true"
        if is_deletion_successful "$current_status"; then
            is_successful="true"
            is_failed="false"
        else
            is_successful="false"
            is_failed="true"
        fi
    else
        is_completed="false"
        is_successful="false"
        is_failed="false"
    fi
    
    # Output structured information
    echo "STATUS=$current_status"
    echo "IS_COMPLETED=$is_completed"
    echo "IS_SUCCESSFUL=$is_successful"
    echo "IS_FAILED=$is_failed"
    
    # Add additional context for specific states
    case "$current_status" in
        "$STACK_NOT_FOUND_STATE")
            echo "DESCRIPTION=Stack has been successfully deleted and no longer exists"
            ;;
        "DELETE_COMPLETE")
            echo "DESCRIPTION=Stack deletion completed successfully"
            ;;
        "DELETE_FAILED")
            echo "DESCRIPTION=Stack deletion failed - manual intervention may be required"
            ;;
        "DELETE_IN_PROGRESS")
            echo "DESCRIPTION=Stack deletion is currently in progress"
            ;;
        *)
            echo "DESCRIPTION=Stack is in state: $current_status"
            ;;
    esac
    
    return 0
}

# Track deletion timing and duration
track_deletion_timing() {
    local operation_name="$1"
    local start_time="$2"
    local end_time="${3:-$(date +%s)}"
    
    local duration=$((end_time - start_time))
    local formatted_duration
    formatted_duration=$(format_duration "$start_time" "$end_time")
    
    log_info "$operation_name completed in $formatted_duration"
    
    # Output timing information
    echo "OPERATION=$operation_name"
    echo "START_TIME=$start_time"
    echo "END_TIME=$end_time"
    echo "DURATION_SECONDS=$duration"
    echo "DURATION_FORMATTED=$formatted_duration"
    
    # Add performance context
    if [[ $duration -lt 60 ]]; then
        echo "PERFORMANCE=very_fast"
    elif [[ $duration -lt 300 ]]; then
        echo "PERFORMANCE=fast"
    elif [[ $duration -lt 900 ]]; then
        echo "PERFORMANCE=normal"
    elif [[ $duration -lt 1800 ]]; then
        echo "PERFORMANCE=slow"
    else
        echo "PERFORMANCE=very_slow"
    fi
    
    return 0
}

# Comprehensive completion detection with all tracking
detect_completion_with_tracking() {
    local stack_name="$1"
    local region="${2:-}"
    local start_time="${3:-$(date +%s)}"
    local timeout_minutes="${4:-60}"
    
    print_header "Deletion Completion Detection"
    
    log_info "Starting comprehensive completion detection for stack '$stack_name'"
    
    # Get initial status
    local initial_status
    initial_status=$(get_stack_status_for_completion "$stack_name" "$region")
    log_info "Initial stack status: $initial_status"
    
    # Check if already completed
    if is_deletion_completed "$initial_status"; then
        local current_time
        current_time=$(date +%s)
        
        log_info "Stack is already in completion state: $initial_status"
        
        # Track timing even for immediate completion
        local timing_result
        timing_result=$(track_deletion_timing "Stack deletion" "$start_time" "$current_time")
        
        # Get detailed status
        local status_details
        status_details=$(get_completion_status_details "$stack_name" "$region")
        
        # Combine results
        echo "DETECTION_RESULT=already_completed"
        echo "$timing_result"
        echo "$status_details"
        
        if is_deletion_successful "$initial_status"; then
            return 0
        else
            return 1
        fi
    fi
    
    # Wait for completion
    log_info "Stack not yet completed, starting monitoring..."
    local completion_result
    completion_result=$(wait_for_deletion_completion "$stack_name" "$region" "$timeout_minutes")
    local completion_exit_code=$?
    
    # Parse completion result
    local final_status elapsed_time
    while IFS='=' read -r key value; do
        case "$key" in
            "FINAL_STATUS")
                final_status="$value"
                ;;
            "ELAPSED_TIME")
                elapsed_time="$value"
                ;;
        esac
    done <<< "$completion_result"
    
    # Track final timing
    local end_time
    end_time=$(date +%s)
    local timing_result
    timing_result=$(track_deletion_timing "Stack deletion monitoring" "$start_time" "$end_time")
    
    # Get final detailed status
    local status_details
    status_details=$(get_completion_status_details "$stack_name" "$region")
    
    # Combine all results
    echo "DETECTION_RESULT=monitoring_completed"
    echo "$completion_result"
    echo "$timing_result"
    echo "$status_details"
    
    return $completion_exit_code
}

# Export functions for use in other scripts
export -f is_deletion_successful is_deletion_failed is_deletion_completed
export -f get_stack_status_for_completion monitor_deletion_completion
export -f wait_for_deletion_completion get_completion_status_details
export -f track_deletion_timing detect_completion_with_tracking

# Execute completion detection if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <stack-name> [aws-region] [start-time] [timeout-minutes]"
        echo ""
        echo "Arguments:"
        echo "  stack-name        Name of the CloudFormation stack to monitor"
        echo "  aws-region        AWS region (optional, uses default if not specified)"
        echo "  start-time        Start time in epoch seconds (optional, uses current time)"
        echo "  timeout-minutes   Maximum monitoring duration in minutes (default: 60)"
        echo ""
        echo "Examples:"
        echo "  $0 my-stack"
        echo "  $0 my-stack us-west-2"
        echo "  $0 my-stack us-west-2 1640995200 30"
        exit 1
    fi
    
    detect_completion_with_tracking "$@"
fi
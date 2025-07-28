#!/bin/bash

# Stack existence and state checking functionality for CloudFormation stack deletion action
# Provides functions to check stack existence, retrieve stack state, and analyze stack status

set -euo pipefail

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Stack state constants
readonly STACK_STATE_DELETE_IN_PROGRESS="DELETE_IN_PROGRESS"
readonly STACK_STATE_DELETE_COMPLETE="DELETE_COMPLETE"
readonly STACK_STATE_DELETE_FAILED="DELETE_FAILED"
readonly STACK_STATE_CREATE_COMPLETE="CREATE_COMPLETE"
readonly STACK_STATE_UPDATE_COMPLETE="UPDATE_COMPLETE"
readonly STACK_STATE_ROLLBACK_COMPLETE="ROLLBACK_COMPLETE"
readonly STACK_STATE_CREATE_IN_PROGRESS="CREATE_IN_PROGRESS"
readonly STACK_STATE_UPDATE_IN_PROGRESS="UPDATE_IN_PROGRESS"
readonly STACK_STATE_ROLLBACK_IN_PROGRESS="ROLLBACK_IN_PROGRESS"

# Check if CloudFormation stack exists
# Returns: 0 if stack exists, 1 if stack does not exist, 2 if error occurred
check_stack_exists() {
    local stack_name="$1"
    local region="${2:-}"
    
    log_info "Checking if stack '$stack_name' exists..."
    
    # Build AWS CLI command with optional region
    local aws_cmd="aws cloudformation describe-stacks --stack-name '$stack_name'"
    if [[ -n "$region" ]]; then
        aws_cmd="$aws_cmd --region '$region'"
    fi
    
    # Execute command and capture output
    local result
    local exit_code
    
    result=$(eval "$aws_cmd" 2>&1)
    exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        log_info "Stack '$stack_name' exists"
        return 0
    else
        # Check if it's a "does not exist" error vs other errors
        if [[ "$result" =~ "does not exist" ]] || [[ "$result" =~ "ValidationError" ]]; then
            log_warning "Stack '$stack_name' does not exist"
            return 1
        else
            # Other error occurred
            log_error "Error checking stack existence: $result"
            return 2
        fi
    fi
}

# Get stack information including status and other details
# Returns: JSON object with stack information, or empty if stack doesn't exist
get_stack_info() {
    local stack_name="$1"
    local region="${2:-}"
    
    log_debug "Retrieving stack information for '$stack_name'..."
    
    # Build AWS CLI command with optional region
    local aws_cmd="aws cloudformation describe-stacks --stack-name '$stack_name' --output json"
    if [[ -n "$region" ]]; then
        aws_cmd="$aws_cmd --region '$region'"
    fi
    
    # Execute command with retry logic for transient failures
    local result
    result=$(retry_aws_operation "$aws_cmd" "Get stack info for '$stack_name'" 3 2)
    local exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        echo "$result"
        return 0
    else
        # Return empty result if stack doesn't exist or error occurred
        echo ""
        return 1
    fi
}

# Extract stack status from stack information
get_stack_status() {
    local stack_name="$1"
    local region="${2:-}"
    
    log_debug "Getting stack status for '$stack_name'..."
    
    local stack_info
    stack_info=$(get_stack_info "$stack_name" "$region")
    
    if [[ -z "$stack_info" ]]; then
        echo "STACK_NOT_FOUND"
        return 1
    fi
    
    # Extract status using jq
    local status
    status=$(echo "$stack_info" | jq -r '.Stacks[0].StackStatus // "UNKNOWN"')
    
    if [[ "$status" == "null" ]] || [[ "$status" == "UNKNOWN" ]]; then
        log_error "Unable to determine stack status for '$stack_name'"
        echo "UNKNOWN"
        return 1
    fi
    
    log_debug "Stack '$stack_name' status: $status"
    echo "$status"
    return 0
}

# Get detailed stack state information
get_stack_state_details() {
    local stack_name="$1"
    local region="${2:-}"
    
    log_debug "Getting detailed stack state for '$stack_name'..."
    
    local stack_info
    stack_info=$(get_stack_info "$stack_name" "$region")
    
    if [[ -z "$stack_info" ]]; then
        echo "STACK_NAME=$stack_name"
        echo "STACK_STATUS=STACK_NOT_FOUND"
        echo "STACK_EXISTS=false"
        return 1
    fi
    
    # Extract relevant information using jq
    local status creation_time last_updated_time status_reason
    status=$(echo "$stack_info" | jq -r '.Stacks[0].StackStatus // "UNKNOWN"')
    creation_time=$(echo "$stack_info" | jq -r '.Stacks[0].CreationTime // "N/A"')
    last_updated_time=$(echo "$stack_info" | jq -r '.Stacks[0].LastUpdatedTime // "N/A"')
    status_reason=$(echo "$stack_info" | jq -r '.Stacks[0].StackStatusReason // "N/A"')
    
    # Output structured information
    echo "STACK_NAME=$stack_name"
    echo "STACK_STATUS=$status"
    echo "STACK_EXISTS=true"
    echo "CREATION_TIME=$creation_time"
    echo "LAST_UPDATED_TIME=$last_updated_time"
    echo "STATUS_REASON=$status_reason"
    
    return 0
}

# Analyze stack state and determine appropriate action
analyze_stack_state() {
    local stack_name="$1"
    local region="${2:-}"
    
    log_info "Analyzing stack state for '$stack_name'..."
    
    # Check if stack exists first
    if ! check_stack_exists "$stack_name" "$region"; then
        local check_exit_code=$?
        if [[ $check_exit_code -eq 1 ]]; then
            # Stack doesn't exist - this is actually a success case for deletion
            log_warning "Stack '$stack_name' does not exist - nothing to delete"
            echo "ACTION=SKIP_ALREADY_DELETED"
            echo "MESSAGE=Stack does not exist, deletion not needed"
            echo "EXIT_CODE=0"
            return 0
        else
            # Error occurred while checking
            log_error "Error occurred while checking stack existence"
            echo "ACTION=ERROR"
            echo "MESSAGE=Failed to check stack existence"
            echo "EXIT_CODE=2"
            return 2
        fi
    fi
    
    # Get stack status
    local stack_status
    stack_status=$(get_stack_status "$stack_name" "$region")
    local status_exit_code=$?
    
    if [[ $status_exit_code -ne 0 ]]; then
        log_error "Failed to retrieve stack status"
        echo "ACTION=ERROR"
        echo "MESSAGE=Failed to retrieve stack status"
        echo "EXIT_CODE=2"
        return 2
    fi
    
    # Analyze status and determine action
    case "$stack_status" in
        "$STACK_STATE_DELETE_IN_PROGRESS")
            log_info "Stack '$stack_name' is already being deleted"
            echo "ACTION=MONITOR_EXISTING_DELETION"
            echo "MESSAGE=Stack deletion already in progress, will monitor existing deletion"
            echo "EXIT_CODE=0"
            return 0
            ;;
        "$STACK_STATE_DELETE_COMPLETE")
            log_warning "Stack '$stack_name' is already deleted"
            echo "ACTION=SKIP_ALREADY_DELETED"
            echo "MESSAGE=Stack is already in DELETE_COMPLETE state"
            echo "EXIT_CODE=0"
            return 0
            ;;
        "$STACK_STATE_DELETE_FAILED")
            log_warning "Stack '$stack_name' has a previous failed deletion"
            echo "ACTION=RETRY_DELETION"
            echo "MESSAGE=Stack has failed deletion status, will attempt deletion again"
            echo "EXIT_CODE=0"
            return 0
            ;;
        "$STACK_STATE_CREATE_COMPLETE"|"$STACK_STATE_UPDATE_COMPLETE"|"$STACK_STATE_ROLLBACK_COMPLETE")
            log_info "Stack '$stack_name' is in stable state and can be deleted"
            echo "ACTION=PROCEED_WITH_DELETION"
            echo "MESSAGE=Stack is in stable state, proceeding with deletion"
            echo "EXIT_CODE=0"
            return 0
            ;;
        "$STACK_STATE_CREATE_IN_PROGRESS"|"$STACK_STATE_UPDATE_IN_PROGRESS"|"$STACK_STATE_ROLLBACK_IN_PROGRESS")
            log_warning "Stack '$stack_name' is currently in progress state: $stack_status"
            echo "ACTION=WAIT_FOR_STABLE_STATE"
            echo "MESSAGE=Stack is in progress state ($stack_status), should wait for stable state before deletion"
            echo "EXIT_CODE=3"
            return 3
            ;;
        *)
            log_warning "Stack '$stack_name' is in unexpected state: $stack_status"
            echo "ACTION=PROCEED_WITH_CAUTION"
            echo "MESSAGE=Stack is in unexpected state ($stack_status), proceeding with caution"
            echo "EXIT_CODE=0"
            return 0
            ;;
    esac
}

# Display stack state information in a formatted way
display_stack_state() {
    local stack_name="$1"
    local region="${2:-}"
    
    print_section "Stack State Information"
    
    # Get detailed stack state
    local state_details
    state_details=$(get_stack_state_details "$stack_name" "$region")
    local details_exit_code=$?
    
    if [[ $details_exit_code -ne 0 ]]; then
        log_error "Stack '$stack_name' not found or inaccessible"
        return 1
    fi
    
    # Parse and display the details
    local stack_status creation_time last_updated_time status_reason
    while IFS='=' read -r key value; do
        case "$key" in
            "STACK_STATUS")
                stack_status="$value"
                ;;
            "CREATION_TIME")
                creation_time="$value"
                ;;
            "LAST_UPDATED_TIME")
                last_updated_time="$value"
                ;;
            "STATUS_REASON")
                status_reason="$value"
                ;;
        esac
    done <<< "$state_details"
    
    echo "  Stack Name: $stack_name" >&2
    echo "  Current Status: $stack_status" >&2
    echo "  Created: $creation_time" >&2
    if [[ "$last_updated_time" != "N/A" ]]; then
        echo "  Last Updated: $last_updated_time" >&2
    fi
    if [[ "$status_reason" != "N/A" ]]; then
        echo "  Status Reason: $status_reason" >&2
    fi
    
    # Add region if specified
    if [[ -n "$region" ]]; then
        echo "  Region: $region" >&2
    fi
    
    echo "" >&2
}

# Main function to perform complete stack state analysis with risk assessment
perform_stack_analysis() {
    local stack_name="$1"
    local region="${2:-}"
    
    print_header "Stack State Analysis"
    
    # Display current stack state
    if display_stack_state "$stack_name" "$region"; then
        # Perform deletion risk analysis
        print_section "Deletion Risk Analysis"
        if analyze_stack_for_deletion_risks "$stack_name" "$region"; then
            log_info "Risk analysis completed - no significant risks detected"
        else
            log_warning "Potential deletion risks identified - review warnings above"
        fi
        
        # Analyze and determine action
        local analysis_result
        analysis_result=$(analyze_stack_state "$stack_name" "$region")
        local analysis_exit_code=$?
        
        # Parse analysis result
        local action message exit_code
        while IFS='=' read -r key value; do
            case "$key" in
                "ACTION")
                    action="$value"
                    ;;
                "MESSAGE")
                    message="$value"
                    ;;
                "EXIT_CODE")
                    exit_code="$value"
                    ;;
            esac
        done <<< "$analysis_result"
        
        # Display analysis results
        print_section "Analysis Results"
        echo "  Recommended Action: $action" >&2
        echo "  Reason: $message" >&2
        echo ""
        
        # Return the analysis result for use by calling scripts
        echo "$analysis_result"
        return "$exit_code"
    else
        # Stack analysis failed
        echo "ACTION=ERROR"
        echo "MESSAGE=Failed to analyze stack state"
        echo "EXIT_CODE=2"
        return 2
    fi
}

# Retry AWS operations with exponential backoff (enhanced version)
retry_aws_operation() {
    local command="$1"
    local operation_name="$2"
    local max_attempts="${3:-3}"
    local base_delay="${4:-2}"
    
    # Use the enhanced retry function from utils.sh
    retry_aws_operation_with_backoff "$command" "$operation_name" "$max_attempts" "$base_delay" 60 300
}

# Initiate CloudFormation stack deletion with enhanced error handling
initiate_stack_deletion() {
    local stack_name="$1"
    local region="${2:-}"
    
    log_info "Initiating deletion of stack '$stack_name'..."
    
    # Build AWS CLI command with optional region
    local aws_cmd="aws cloudformation delete-stack --stack-name '$stack_name'"
    if [[ -n "$region" ]]; then
        aws_cmd="$aws_cmd --region '$region'"
    fi
    
    # Execute deletion command with direct timeout
    log_debug "Executing AWS command: $aws_cmd"
    local result
    local exit_code
    
    # Use timeout command directly if available
    if command -v timeout >/dev/null 2>&1; then
        result=$(timeout 30 bash -c "$aws_cmd" 2>&1)
        exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            log_error "AWS delete-stack command timed out after 30 seconds"
            result="Command timed out"
            exit_code=124
        fi
    else
        result=$(eval "$aws_cmd" 2>&1)
        exit_code=$?
    fi
    
    log_debug "AWS command completed with exit code: $exit_code"
    
    # Handle the result using enhanced error handling
    if ! handle_aws_operation_error "$exit_code" "$result" "Stack deletion initiation" "$stack_name"; then
        local error_exit_code=$?
        
        # Try specific deletion error scenario handling
        if handle_deletion_error_scenarios "$result" "$stack_name"; then
            local scenario_exit_code=$?
            case "$scenario_exit_code" in
                0)
                    # Handled successfully (e.g., stack doesn't exist)
                    echo "DELETION_INITIATED=false"
                    echo "STACK_STATUS=HANDLED"
                    echo "MESSAGE=Deletion scenario handled successfully"
                    return 0
                    ;;
                2)
                    # Permission error
                    echo "DELETION_INITIATED=false"
                    echo "STACK_STATUS=PERMISSION_ERROR"
                    echo "MESSAGE=Insufficient permissions for stack deletion"
                    return 2
                    ;;
                *)
                    # Other handled error
                    echo "DELETION_INITIATED=false"
                    echo "STACK_STATUS=ERROR"
                    echo "MESSAGE=$(format_aws_error_message "$result")"
                    return 1
                    ;;
            esac
        fi
        
        # Check for specific known scenarios
        if [[ "$result" =~ "does not exist" ]] || [[ "$result" =~ "ValidationError" ]]; then
            log_warning "Stack '$stack_name' does not exist - nothing to delete"
            echo "DELETION_INITIATED=false"
            echo "STACK_STATUS=STACK_NOT_FOUND"
            echo "MESSAGE=Stack does not exist, deletion not needed"
            return 0
        elif [[ "$result" =~ "DELETE_IN_PROGRESS" ]]; then
            log_info "Stack '$stack_name' is already being deleted"
            echo "DELETION_INITIATED=false"
            echo "STACK_STATUS=DELETE_IN_PROGRESS"
            echo "MESSAGE=Stack deletion already in progress"
            return 0
        else
            echo "DELETION_INITIATED=false"
            echo "STACK_STATUS=ERROR"
            echo "MESSAGE=$(format_aws_error_message "$result")"
            return "$error_exit_code"
        fi
    fi
    
    log_success "Stack deletion initiated successfully for '$stack_name'"
    
    # The delete-stack command returns immediately if successful, so we can assume it worked
    log_info "Deletion initiation confirmed - stack deletion has been requested"
    echo "DELETION_INITIATED=true"
    echo "STACK_STATUS=DELETE_IN_PROGRESS"
    echo "MESSAGE=Stack deletion initiated successfully"
    return 0
}

# Verify that stack deletion was successfully initiated
verify_deletion_initiated() {
    local stack_name="$1"
    local region="${2:-}"
    local max_attempts=3
    local delay=1
    
    log_info "Verifying deletion initiation for stack '$stack_name'..."
    
    for ((attempt=1; attempt<=max_attempts; attempt++)); do
        log_debug "Verification attempt $attempt/$max_attempts"
        local stack_status
        stack_status=$(get_stack_status "$stack_name" "$region")
        local status_exit_code=$?
        log_debug "Stack status check returned: exit_code=$status_exit_code, status='$stack_status'"
        
        if [[ $status_exit_code -eq 0 ]]; then
            case "$stack_status" in
                "$STACK_STATE_DELETE_IN_PROGRESS")
                    log_debug "Deletion verification successful - stack is in DELETE_IN_PROGRESS state"
                    return 0
                    ;;
                "$STACK_STATE_DELETE_COMPLETE")
                    log_debug "Stack deletion completed very quickly"
                    return 0
                    ;;
                "STACK_NOT_FOUND")
                    log_debug "Stack no longer exists - deletion completed"
                    return 0
                    ;;
                *)
                    if [[ $attempt -lt $max_attempts ]]; then
                        log_debug "Stack still in state '$stack_status', waiting ${delay}s before retry (attempt $attempt/$max_attempts)"
                        sleep "$delay"
                        continue
                    else
                        log_warning "Stack is in unexpected state '$stack_status' after deletion initiation"
                        echo "Stack in unexpected state: $stack_status"
                        return 1
                    fi
                    ;;
            esac
        else
            if [[ $attempt -lt $max_attempts ]]; then
                log_debug "Failed to get stack status, retrying in ${delay}s (attempt $attempt/$max_attempts)"
                sleep "$delay"
                continue
            else
                log_error "Failed to verify deletion initiation after $max_attempts attempts"
                echo "Failed to verify deletion status"
                return 1
            fi
        fi
    done
    
    return 1
}

# Handle stack deletion with comprehensive error handling and validation
delete_stack_with_validation() {
    local stack_name="$1"
    local region="${2:-}"
    
    print_header "Stack Deletion Process"
    
    # First, analyze the current stack state
    log_info "Analyzing current stack state before deletion..."
    local analysis_result
    analysis_result=$(analyze_stack_state "$stack_name" "$region")
    local analysis_exit_code=$?
    
    # Parse analysis result
    local action message
    while IFS='=' read -r key value; do
        case "$key" in
            "ACTION")
                action="$value"
                ;;
            "MESSAGE")
                message="$value"
                ;;
        esac
    done <<< "$analysis_result"
    
    # Handle different actions based on analysis
    case "$action" in
        "SKIP_ALREADY_DELETED")
            log_success "$message"
            echo "DELETION_RESULT=skipped"
            echo "FINAL_STATUS=already_deleted"
            echo "MESSAGE=$message"
            return 0
            ;;
        "MONITOR_EXISTING_DELETION")
            log_info "$message"
            echo "DELETION_RESULT=monitoring"
            echo "FINAL_STATUS=delete_in_progress"
            echo "MESSAGE=$message"
            return 0
            ;;
        "WAIT_FOR_STABLE_STATE")
            log_warning "$message"
            echo "DELETION_RESULT=error"
            echo "FINAL_STATUS=unstable_state"
            echo "MESSAGE=$message"
            return 3
            ;;
        "PROCEED_WITH_DELETION"|"RETRY_DELETION"|"PROCEED_WITH_CAUTION")
            log_info "$message - proceeding with deletion"
            
            # Check for dependencies before proceeding
            print_section "Dependency Check"
            if ! check_stack_deletion_dependencies "$stack_name" "$region"; then
                log_error "Stack has dependencies that prevent deletion"
                echo "DELETION_RESULT=error"
                echo "FINAL_STATUS=dependency_error"
                echo "MESSAGE=Stack has dependencies that prevent deletion"
                return 3
            fi
            log_info "Dependency check passed"
            ;;
        "ERROR")
            log_error "$message"
            echo "DELETION_RESULT=error"
            echo "FINAL_STATUS=analysis_failed"
            echo "MESSAGE=$message"
            return 2
            ;;
        *)
            log_warning "Unknown analysis action '$action' - proceeding with deletion"
            ;;
    esac
    
    # Proceed with deletion initiation
    print_section "Initiating Stack Deletion"
    local deletion_result
    deletion_result=$(initiate_stack_deletion "$stack_name" "$region")
    local deletion_exit_code=$?
    
    # Parse deletion result
    local deletion_initiated stack_status deletion_message
    while IFS='=' read -r key value; do
        case "$key" in
            "DELETION_INITIATED")
                deletion_initiated="$value"
                ;;
            "STACK_STATUS")
                stack_status="$value"
                ;;
            "MESSAGE")
                deletion_message="$value"
                ;;
        esac
    done <<< "$deletion_result"
    
    # Return final result
    case "$deletion_initiated" in
        "true")
            log_success "Stack deletion initiated successfully"
            echo "DELETION_RESULT=initiated"
            echo "FINAL_STATUS=$stack_status"
            echo "MESSAGE=$deletion_message"
            return 0
            ;;
        "false")
            if [[ "$stack_status" == "STACK_NOT_FOUND" ]] || [[ "$stack_status" == "DELETE_IN_PROGRESS" ]]; then
                log_info "$deletion_message"
                echo "DELETION_RESULT=not_needed"
                echo "FINAL_STATUS=$stack_status"
                echo "MESSAGE=$deletion_message"
                return 0
            elif [[ "$stack_status" == "DELETE_FAILED" ]]; then
                log_error "$deletion_message"
                log_error "Stack deletion failed - providing recovery guidance"
                handle_stack_deletion_failure_scenario "$stack_name" "$region"
                echo "DELETION_RESULT=failed"
                echo "FINAL_STATUS=$stack_status"
                echo "MESSAGE=$deletion_message"
                return 1
            else
                log_error "$deletion_message"
                echo "DELETION_RESULT=failed"
                echo "FINAL_STATUS=$stack_status"
                echo "MESSAGE=$deletion_message"
                return 1
            fi
            ;;
        *)
            log_error "Unknown deletion result: $deletion_message"
            
            # Try to get current stack status for better error reporting
            local current_status
            current_status=$(get_stack_status "$stack_name" "$region" 2>/dev/null || echo "UNKNOWN")
            
            if [[ "$current_status" == "DELETE_FAILED" ]]; then
                log_error "Stack is in DELETE_FAILED state - providing recovery guidance"
                handle_stack_deletion_failure_scenario "$stack_name" "$region"
            fi
            
            echo "DELETION_RESULT=unknown"
            echo "FINAL_STATUS=$current_status"
            echo "MESSAGE=$deletion_message"
            return 1
            ;;
    esac
}

# Handle stack deletion failure scenarios with recovery guidance
handle_stack_deletion_failure_scenario() {
    local stack_name="$1"
    local region="${2:-}"
    
    log_info "Analyzing stack deletion failure for '$stack_name'..."
    
    # Get current stack status and details
    local stack_details
    stack_details=$(get_stack_state_details "$stack_name" "$region")
    local details_exit_code=$?
    
    if [[ $details_exit_code -ne 0 ]]; then
        log_error "Cannot retrieve stack details for failure analysis"
        return 1
    fi
    
    # Parse stack details
    local stack_status status_reason
    while IFS='=' read -r key value; do
        case "$key" in
            "STACK_STATUS")
                stack_status="$value"
                ;;
            "STATUS_REASON")
                status_reason="$value"
                ;;
        esac
    done <<< "$stack_details"
    
    # Handle the failure based on status
    handle_stack_deletion_failure "$stack_name" "$status_reason" "$stack_status"
    
    # Get recent stack events to provide more context
    print_section "Recent Stack Events (Last 10)"
    local recent_events
    recent_events=$(aws cloudformation describe-stack-events \
        --stack-name "$stack_name" \
        --max-items 10 \
        --output table \
        --query 'StackEvents[*].[Timestamp,ResourceStatus,ResourceType,LogicalResourceId,ResourceStatusReason]' \
        2>/dev/null || echo "Could not retrieve recent events")
    
    if [[ "$recent_events" != "Could not retrieve recent events" ]]; then
        echo "$recent_events"
    else
        log_warning "Could not retrieve recent stack events"
    fi
    
    echo ""
    log_info "For detailed troubleshooting, check the CloudFormation console or run:"
    log_info "  aws cloudformation describe-stack-events --stack-name '$stack_name'"
}

# Check for stack deletion dependencies before deletion
check_stack_deletion_dependencies() {
    local stack_name="$1"
    local region="${2:-}"
    
    log_info "Checking for stack deletion dependencies..."
    
    # Check for stacks that might depend on this stack's exports
    local stack_outputs
    stack_outputs=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --query 'Stacks[0].Outputs[?ExportName!=null].[ExportName]' \
        --output text \
        2>/dev/null || echo "")
    
    if [[ -n "$stack_outputs" ]] && [[ "$stack_outputs" != "None" ]]; then
        log_warning "Stack has exports that may be used by other stacks:"
        
        local dependency_found=false
        while IFS= read -r export_name; do
            if [[ -n "$export_name" ]] && [[ "$export_name" != "None" ]]; then
                log_info "  Checking export: $export_name"
                
                # Check if export is imported by other stacks
                local importing_stacks
                importing_stacks=$(aws cloudformation list-imports \
                    --export-name "$export_name" \
                    --query 'Imports[*]' \
                    --output text \
                    2>/dev/null || echo "")
                
                if [[ -n "$importing_stacks" ]] && [[ "$importing_stacks" != "None" ]]; then
                    log_error "    Export '$export_name' is used by: $importing_stacks"
                    dependency_found=true
                else
                    log_info "    Export '$export_name' is not in use"
                fi
            fi
        done <<< "$stack_outputs"
        
        if [[ "$dependency_found" == true ]]; then
            log_error "Stack has active dependencies - deletion will fail"
            log_error "Delete or update dependent stacks first"
            return 1
        fi
    else
        log_info "No exports found - no dependency concerns"
    fi
    
    return 0
}

# Export functions for use in other scripts
export -f retry_aws_operation initiate_stack_deletion verify_deletion_initiated delete_stack_with_validation
export -f check_stack_exists get_stack_info get_stack_status get_stack_state_details
export -f analyze_stack_state display_stack_state perform_stack_analysis
export -f handle_stack_deletion_failure_scenario check_stack_deletion_dependencies

# Execute main analysis if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 1 ]]; then
        echo "Usage: $0 <stack-name> [aws-region]"
        echo ""
        echo "Examples:"
        echo "  $0 my-stack"
        echo "  $0 my-stack us-west-2"
        exit 1
    fi
    
    perform_stack_analysis "$@"
fi
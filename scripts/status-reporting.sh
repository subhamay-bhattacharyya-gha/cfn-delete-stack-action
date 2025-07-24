#!/bin/bash

# Final status reporting and outputs for CloudFormation stack deletion action
# Provides functions to report final status, set GitHub Actions outputs, and generate summaries

set -euo pipefail

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Exit code constants
readonly EXIT_SUCCESS=0
readonly EXIT_VALIDATION_ERROR=1
readonly EXIT_AUTH_ERROR=2
readonly EXIT_STACK_ERROR=3
readonly EXIT_DELETION_ERROR=4
readonly EXIT_TIMEOUT_ERROR=5

# Status reporting constants
readonly STATUS_SUCCESS="success"
readonly STATUS_FAILED="failed"
readonly STATUS_TIMEOUT="timeout"
readonly STATUS_SKIPPED="skipped"
readonly STATUS_ERROR="error"

# Set GitHub Actions output
set_github_output() {
    local output_name="$1"
    local output_value="$2"
    
    if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
        echo "$output_name=$output_value" >> "$GITHUB_OUTPUT"
        log_debug "Set GitHub Actions output: $output_name=$output_value"
    else
        log_debug "GITHUB_OUTPUT not set, would set: $output_name=$output_value"
    fi
}

# Set multiple GitHub Actions outputs from key-value pairs
set_multiple_github_outputs() {
    local -n output_data_ref=$1
    
    for key in "${!output_data_ref[@]}"; do
        set_github_output "$key" "${output_data_ref[$key]}"
    done
}

# Generate final status summary message
generate_status_summary() {
    local stack_name="$1"
    local final_status="$2"
    local deletion_time="$3"
    local operation_result="$4"
    
    local summary_message=""
    
    case "$operation_result" in
        "$STATUS_SUCCESS")
            if [[ "$final_status" == "STACK_NOT_FOUND" ]] || [[ "$final_status" == "DELETE_COMPLETE" ]]; then
                summary_message="✅ Stack '$stack_name' has been successfully deleted"
            else
                summary_message="✅ Stack '$stack_name' deletion completed successfully (Status: $final_status)"
            fi
            ;;
        "$STATUS_SKIPPED")
            summary_message="⏭️ Stack '$stack_name' deletion was skipped (already deleted or not found)"
            ;;
        "$STATUS_FAILED")
            summary_message="❌ Stack '$stack_name' deletion failed (Status: $final_status)"
            ;;
        "$STATUS_TIMEOUT")
            summary_message="⏰ Stack '$stack_name' deletion timed out after $deletion_time"
            ;;
        "$STATUS_ERROR")
            summary_message="🚨 Error occurred during stack '$stack_name' deletion process"
            ;;
        *)
            summary_message="❓ Stack '$stack_name' deletion completed with unknown result: $operation_result"
            ;;
    esac
    
    if [[ -n "$deletion_time" ]] && [[ "$deletion_time" != "N/A" ]] && [[ "$operation_result" != "$STATUS_TIMEOUT" ]]; then
        summary_message="$summary_message (Duration: $deletion_time)"
    fi
    
    echo "$summary_message"
}

# Report final deletion status with comprehensive information
report_final_status() {
    local stack_name="$1"
    local final_status="$2"
    local deletion_time="$3"
    local operation_result="$4"
    local additional_info="${5:-}"
    
    print_header "Final Deletion Status Report"
    
    # Generate summary message
    local summary_message
    summary_message=$(generate_status_summary "$stack_name" "$final_status" "$deletion_time" "$operation_result")
    
    # Display summary
    echo "Stack Name: $stack_name"
    echo "Final Status: $final_status"
    echo "Operation Result: $operation_result"
    echo "Duration: $deletion_time"
    
    if [[ -n "$additional_info" ]]; then
        echo "Additional Info: $additional_info"
    fi
    
    echo ""
    echo "$summary_message"
    echo ""
    
    # Set GitHub Actions outputs
    set_github_output "stack-status" "$final_status"
    set_github_output "deletion-time" "$deletion_time"
    set_github_output "operation-result" "$operation_result"
    set_github_output "summary" "$summary_message"
    
    # Log appropriate level based on result
    case "$operation_result" in
        "$STATUS_SUCCESS"|"$STATUS_SKIPPED")
            log_success "$summary_message"
            ;;
        "$STATUS_FAILED"|"$STATUS_ERROR")
            log_error "$summary_message"
            ;;
        "$STATUS_TIMEOUT")
            log_warning "$summary_message"
            ;;
        *)
            log_info "$summary_message"
            ;;
    esac
}

# Generate detailed deletion report
generate_deletion_report() {
    local stack_name="$1"
    local start_time="$2"
    local end_time="$3"
    local final_status="$4"
    local operation_result="$5"
    local events_count="${6:-0}"
    local status_changes="${7:-0}"
    
    local duration_seconds=$((end_time - start_time))
    local formatted_duration
    formatted_duration=$(format_duration "$start_time" "$end_time")
    
    print_section "Deletion Process Report"
    
    echo "  Stack Information:"
    echo "    Name: $stack_name"
    echo "    Final Status: $final_status"
    echo "    Operation Result: $operation_result"
    echo ""
    
    echo "  Timing Information:"
    echo "    Start Time: $(date -d "@$start_time" '+%Y-%m-%d %H:%M:%S UTC')"
    echo "    End Time: $(date -d "@$end_time" '+%Y-%m-%d %H:%M:%S UTC')"
    echo "    Total Duration: $formatted_duration ($duration_seconds seconds)"
    echo ""
    
    echo "  Process Statistics:"
    echo "    Events Monitored: $events_count"
    echo "    Status Changes: $status_changes"
    echo ""
    
    # Performance analysis
    local performance_rating
    if [[ $duration_seconds -lt 60 ]]; then
        performance_rating="Excellent (< 1 minute)"
    elif [[ $duration_seconds -lt 300 ]]; then
        performance_rating="Good (< 5 minutes)"
    elif [[ $duration_seconds -lt 900 ]]; then
        performance_rating="Normal (< 15 minutes)"
    elif [[ $duration_seconds -lt 1800 ]]; then
        performance_rating="Slow (< 30 minutes)"
    else
        performance_rating="Very Slow (> 30 minutes)"
    fi
    
    echo "  Performance: $performance_rating"
    echo ""
    
    # Generate recommendations based on results
    case "$operation_result" in
        "$STATUS_SUCCESS")
            echo "  ✅ Deletion completed successfully. No further action required."
            ;;
        "$STATUS_SKIPPED")
            echo "  ⏭️ Deletion was skipped as the stack was already deleted or not found."
            ;;
        "$STATUS_FAILED")
            echo "  ❌ Deletion failed. Check CloudFormation console for detailed error information."
            echo "     Consider manual cleanup of remaining resources if necessary."
            ;;
        "$STATUS_TIMEOUT")
            echo "  ⏰ Deletion timed out. The stack may still be deleting in the background."
            echo "     Check CloudFormation console to monitor progress."
            ;;
        "$STATUS_ERROR")
            echo "  🚨 An error occurred during the deletion process."
            echo "     Review the logs above for specific error details."
            ;;
    esac
    
    echo ""
}

# Create GitHub Actions job summary
create_job_summary() {
    local stack_name="$1"
    local final_status="$2"
    local deletion_time="$3"
    local operation_result="$4"
    local start_time="${5:-}"
    local end_time="${6:-}"
    
    if [[ -z "${GITHUB_STEP_SUMMARY:-}" ]]; then
        log_debug "GITHUB_STEP_SUMMARY not set, skipping job summary creation"
        return 0
    fi
    
    local summary_file="$GITHUB_STEP_SUMMARY"
    
    # Generate status emoji and color
    local status_emoji status_color
    case "$operation_result" in
        "$STATUS_SUCCESS")
            status_emoji="✅"
            status_color="green"
            ;;
        "$STATUS_SKIPPED")
            status_emoji="⏭️"
            status_color="yellow"
            ;;
        "$STATUS_FAILED")
            status_emoji="❌"
            status_color="red"
            ;;
        "$STATUS_TIMEOUT")
            status_emoji="⏰"
            status_color="orange"
            ;;
        "$STATUS_ERROR")
            status_emoji="🚨"
            status_color="red"
            ;;
        *)
            status_emoji="❓"
            status_color="gray"
            ;;
    esac
    
    # Create markdown summary
    cat >> "$summary_file" << EOF
# CloudFormation Stack Deletion Report

## Summary
$status_emoji **Stack deletion $operation_result**

## Details
| Property | Value |
|----------|-------|
| Stack Name | \`$stack_name\` |
| Final Status | \`$final_status\` |
| Operation Result | $status_emoji $operation_result |
| Duration | $deletion_time |

EOF
    
    # Add timing details if available
    if [[ -n "$start_time" ]] && [[ -n "$end_time" ]]; then
        cat >> "$summary_file" << EOF
## Timing Information
- **Start Time:** $(date -d "@$start_time" '+%Y-%m-%d %H:%M:%S UTC')
- **End Time:** $(date -d "@$end_time" '+%Y-%m-%d %H:%M:%S UTC')
- **Total Duration:** $deletion_time

EOF
    fi
    
    # Add status-specific information
    case "$operation_result" in
        "$STATUS_SUCCESS")
            cat >> "$summary_file" << EOF
## Result
The CloudFormation stack has been successfully deleted. All resources associated with the stack have been removed.

EOF
            ;;
        "$STATUS_SKIPPED")
            cat >> "$summary_file" << EOF
## Result
The stack deletion was skipped because the stack was already deleted or does not exist.

EOF
            ;;
        "$STATUS_FAILED")
            cat >> "$summary_file" << EOF
## Result
The stack deletion failed. Please check the CloudFormation console for detailed error information and consider manual cleanup if necessary.

EOF
            ;;
        "$STATUS_TIMEOUT")
            cat >> "$summary_file" << EOF
## Result
The stack deletion monitoring timed out. The stack may still be deleting in the background. Please check the CloudFormation console to monitor progress.

EOF
            ;;
        "$STATUS_ERROR")
            cat >> "$summary_file" << EOF
## Result
An error occurred during the deletion process. Please review the action logs for specific error details.

EOF
            ;;
    esac
    
    log_debug "Created GitHub Actions job summary"
}

# Determine appropriate exit code based on operation result
get_exit_code_for_result() {
    local operation_result="$1"
    local final_status="${2:-}"
    
    case "$operation_result" in
        "$STATUS_SUCCESS"|"$STATUS_SKIPPED")
            echo $EXIT_SUCCESS
            ;;
        "$STATUS_FAILED")
            case "$final_status" in
                "DELETE_FAILED")
                    echo $EXIT_DELETION_ERROR
                    ;;
                *)
                    echo $EXIT_STACK_ERROR
                    ;;
            esac
            ;;
        "$STATUS_TIMEOUT")
            echo $EXIT_TIMEOUT_ERROR
            ;;
        "$STATUS_ERROR")
            echo $EXIT_STACK_ERROR
            ;;
        *)
            echo $EXIT_STACK_ERROR
            ;;
    esac
}

# Complete status reporting with all outputs and summaries
complete_status_reporting() {
    local stack_name="$1"
    local final_status="$2"
    local deletion_time="$3"
    local operation_result="$4"
    local start_time="${5:-}"
    local end_time="${6:-}"
    local events_count="${7:-0}"
    local status_changes="${8:-0}"
    local additional_info="${9:-}"
    
    print_header "Completion Status Reporting"
    
    # Report final status
    report_final_status "$stack_name" "$final_status" "$deletion_time" "$operation_result" "$additional_info"
    
    # Generate detailed report if timing information is available
    if [[ -n "$start_time" ]] && [[ -n "$end_time" ]]; then
        generate_deletion_report "$stack_name" "$start_time" "$end_time" "$final_status" "$operation_result" "$events_count" "$status_changes"
    fi
    
    # Create GitHub Actions job summary
    create_job_summary "$stack_name" "$final_status" "$deletion_time" "$operation_result" "$start_time" "$end_time"
    
    # Determine and return appropriate exit code
    local exit_code
    exit_code=$(get_exit_code_for_result "$operation_result" "$final_status")
    
    log_info "Status reporting completed. Exit code: $exit_code"
    return "$exit_code"
}

# Handle successful deletion reporting
report_successful_deletion() {
    local stack_name="$1"
    local final_status="$2"
    local deletion_time="$3"
    local additional_info="${4:-}"
    
    complete_status_reporting "$stack_name" "$final_status" "$deletion_time" "$STATUS_SUCCESS" "" "" "0" "0" "$additional_info"
}

# Handle failed deletion reporting
report_failed_deletion() {
    local stack_name="$1"
    local final_status="$2"
    local deletion_time="$3"
    local error_message="${4:-}"
    
    complete_status_reporting "$stack_name" "$final_status" "$deletion_time" "$STATUS_FAILED" "" "" "0" "0" "$error_message"
}

# Handle skipped deletion reporting
report_skipped_deletion() {
    local stack_name="$1"
    local reason="${2:-Stack already deleted or not found}"
    
    complete_status_reporting "$stack_name" "STACK_NOT_FOUND" "N/A" "$STATUS_SKIPPED" "" "" "0" "0" "$reason"
}

# Handle timeout reporting
report_timeout() {
    local stack_name="$1"
    local timeout_duration="$2"
    local last_known_status="${3:-UNKNOWN}"
    
    complete_status_reporting "$stack_name" "$last_known_status" "$timeout_duration" "$STATUS_TIMEOUT" "" "" "0" "0" "Operation timed out"
}

# Handle error reporting
report_error() {
    local stack_name="$1"
    local error_message="$2"
    local error_status="${3:-ERROR}"
    
    complete_status_reporting "$stack_name" "$error_status" "N/A" "$STATUS_ERROR" "" "" "0" "0" "$error_message"
}

# Export functions for use in other scripts
export -f set_github_output set_multiple_github_outputs generate_status_summary
export -f report_final_status generate_deletion_report create_job_summary
export -f get_exit_code_for_result complete_status_reporting
export -f report_successful_deletion report_failed_deletion report_skipped_deletion
export -f report_timeout report_error

# Execute status reporting if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -lt 4 ]]; then
        echo "Usage: $0 <stack-name> <final-status> <deletion-time> <operation-result> [start-time] [end-time] [events-count] [status-changes] [additional-info]"
        echo ""
        echo "Arguments:"
        echo "  stack-name        Name of the CloudFormation stack"
        echo "  final-status      Final status of the stack"
        echo "  deletion-time     Time taken for deletion (formatted)"
        echo "  operation-result  Result of the operation (success|failed|timeout|skipped|error)"
        echo "  start-time        Start time in epoch seconds (optional)"
        echo "  end-time          End time in epoch seconds (optional)"
        echo "  events-count      Number of events monitored (optional)"
        echo "  status-changes    Number of status changes (optional)"
        echo "  additional-info   Additional information (optional)"
        echo ""
        echo "Examples:"
        echo "  $0 my-stack DELETE_COMPLETE '2m 30s' success"
        echo "  $0 my-stack DELETE_FAILED '5m 15s' failed 1640995200 1640995515 25 3 'Dependency error'"
        exit 1
    fi
    
    complete_status_reporting "$@"
fi
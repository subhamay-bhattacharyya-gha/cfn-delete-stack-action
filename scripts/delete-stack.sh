#!/bin/bash

# Main orchestration script for CloudFormation stack deletion action
# Integrates all components into a comprehensive deletion workflow

set -euo pipefail

# Source utility functions and component scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/validate-inputs.sh"
source "${SCRIPT_DIR}/validate-aws-config.sh"
source "${SCRIPT_DIR}/check-stack.sh"
source "${SCRIPT_DIR}/monitor-events.sh"
source "${SCRIPT_DIR}/completion-detection.sh"
source "${SCRIPT_DIR}/status-reporting.sh"

# Script configuration (only define if not already defined)
if [[ -z "${SCRIPT_NAME:-}" ]]; then
    readonly SCRIPT_NAME="CloudFormation Stack Deletion"
fi
if [[ -z "${SCRIPT_VERSION:-}" ]]; then
    readonly SCRIPT_VERSION="1.0.0"
fi

# Default configuration values (only define if not already defined)
if [[ -z "${DEFAULT_POLL_INTERVAL:-}" ]]; then
    readonly DEFAULT_POLL_INTERVAL=5
fi
if [[ -z "${DEFAULT_TIMEOUT_MINUTES:-}" ]]; then
    readonly DEFAULT_TIMEOUT_MINUTES=60
fi
if [[ -z "${DEFAULT_WAIT_FOR_COMPLETION:-}" ]]; then
    readonly DEFAULT_WAIT_FOR_COMPLETION="true"
fi

# Global variables for tracking
DELETION_START_TIME=""
DELETION_END_TIME=""
EVENTS_MONITORED=0
STATUS_CHANGES=0

# Display script header and version information
display_script_header() {
    print_header "$SCRIPT_NAME v$SCRIPT_VERSION"
    log_info "Starting CloudFormation stack deletion process"
    log_info "Timestamp: $(get_timestamp)"
    echo ""
}

# Parse and validate command line arguments
parse_arguments() {
    local stack_name="${1:-}"
    local aws_region="${2:-}"
    local wait_for_completion="${3:-$DEFAULT_WAIT_FOR_COMPLETION}"
    
    # Validate all inputs using the validation module
    local validation_result
    validation_result=$(validate_all_inputs "$stack_name" "$aws_region" "$wait_for_completion")
    
    # Parse validation results and set global variables
    while IFS='=' read -r key value; do
        case "$key" in
            "STACK_NAME")
                export VALIDATED_STACK_NAME="$value"
                ;;
            "AWS_REGION")
                export VALIDATED_AWS_REGION="$value"
                ;;
            "WAIT_FOR_COMPLETION")
                export VALIDATED_WAIT_FOR_COMPLETION="$value"
                ;;
        esac
    done <<< "$validation_result"
    
    log_info "Input validation completed successfully"
    log_info "Stack Name: $VALIDATED_STACK_NAME"
    if [[ -n "${VALIDATED_AWS_REGION:-}" ]]; then
        log_info "AWS Region: $VALIDATED_AWS_REGION"
    fi
    log_info "Wait for Completion: $VALIDATED_WAIT_FOR_COMPLETION"
}

# Perform comprehensive AWS configuration validation
validate_aws_environment() {
    print_section "AWS Environment Validation"
    
    # Set AWS region if provided
    if [[ -n "${VALIDATED_AWS_REGION:-}" ]]; then
        export AWS_REGION="$VALIDATED_AWS_REGION"
        export AWS_DEFAULT_REGION="$VALIDATED_AWS_REGION"
    fi
    
    # Run AWS configuration validation
    if ! validate_aws_cli_installation; then
        handle_auth_error "AWS CLI validation failed"
    fi
    
    if ! validate_aws_credentials; then
        handle_auth_error "AWS credentials validation failed"
    fi
    
    if ! validate_aws_region; then
        handle_auth_error "AWS region validation failed"
    fi
    
    if ! validate_cloudformation_access; then
        handle_auth_error "CloudFormation access validation failed"
    fi
    
    if ! test_aws_service_connectivity; then
        handle_auth_error "AWS service connectivity test failed"
    fi
    
    log_success "AWS environment validation completed successfully"
}

# Analyze stack state and determine deletion strategy
analyze_stack_for_deletion() {
    print_section "Stack State Analysis"
    
    local analysis_result
    analysis_result=$(perform_stack_analysis "$VALIDATED_STACK_NAME" "${VALIDATED_AWS_REGION:-}")
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
    
    # Store analysis results for later use
    export STACK_ANALYSIS_ACTION="$action"
    export STACK_ANALYSIS_MESSAGE="$message"
    export STACK_ANALYSIS_EXIT_CODE="$exit_code"
    
    log_info "Stack analysis completed: $action"
    log_info "Analysis message: $message"
    
    return "$exit_code"
}

# Execute stack deletion based on analysis results
execute_stack_deletion() {
    print_section "Stack Deletion Execution"
    
    # Record deletion start time
    DELETION_START_TIME=$(date +%s)
    
    case "$STACK_ANALYSIS_ACTION" in
        "SKIP_ALREADY_DELETED")
            log_info "Skipping deletion - stack already deleted or not found"
            export DELETION_RESULT="skipped"
            export FINAL_STACK_STATUS="STACK_NOT_FOUND"
            return 0
            ;;
        "MONITOR_EXISTING_DELETION")
            log_info "Stack deletion already in progress - monitoring existing deletion"
            export DELETION_RESULT="monitoring"
            export FINAL_STACK_STATUS="DELETE_IN_PROGRESS"
            return 0
            ;;
        "WAIT_FOR_STABLE_STATE")
            log_warning "Stack is in unstable state - cannot proceed with deletion"
            export DELETION_RESULT="error"
            export FINAL_STACK_STATUS="UNSTABLE_STATE"
            return 3
            ;;
        "PROCEED_WITH_DELETION"|"RETRY_DELETION"|"PROCEED_WITH_CAUTION")
            log_info "Proceeding with stack deletion initiation"
            ;;
        "ERROR")
            log_error "Stack analysis failed - cannot proceed"
            export DELETION_RESULT="error"
            export FINAL_STACK_STATUS="ANALYSIS_FAILED"
            return 2
            ;;
        *)
            log_warning "Unknown analysis action - proceeding with caution"
            ;;
    esac
    
    # Initiate stack deletion
    local deletion_result
    deletion_result=$(delete_stack_with_validation "$VALIDATED_STACK_NAME" "${VALIDATED_AWS_REGION:-}")
    local deletion_exit_code=$?
    
    # Parse deletion result
    local deletion_status final_status deletion_message
    while IFS='=' read -r key value; do
        case "$key" in
            "DELETION_RESULT")
                deletion_status="$value"
                ;;
            "FINAL_STATUS")
                final_status="$value"
                ;;
            "MESSAGE")
                deletion_message="$value"
                ;;
        esac
    done <<< "$deletion_result"
    
    # Store deletion results
    export DELETION_RESULT="$deletion_status"
    export FINAL_STACK_STATUS="$final_status"
    export DELETION_MESSAGE="$deletion_message"
    
    log_info "Deletion execution completed with result: $deletion_status"
    log_info "Final stack status: $final_status"
    
    return "$deletion_exit_code"
}

# Monitor deletion progress with real-time events
monitor_deletion_progress() {
    # Skip monitoring if deletion was skipped or failed to initiate
    if [[ "$DELETION_RESULT" == "skipped" ]] || [[ "$DELETION_RESULT" == "error" ]] || [[ "$DELETION_RESULT" == "failed" ]]; then
        log_info "Skipping deletion monitoring due to result: $DELETION_RESULT"
        return 0
    fi
    
    # Skip monitoring if wait for completion is disabled
    if [[ "$VALIDATED_WAIT_FOR_COMPLETION" == "false" ]]; then
        log_info "Wait for completion disabled - skipping monitoring"
        export MONITORING_RESULT="skipped"
        return 0
    fi
    
    print_section "Deletion Progress Monitoring"
    
    # Start event monitoring in background
    local monitoring_result
    monitoring_result=$(monitor_stack_events_with_timeout "$VALIDATED_STACK_NAME" "${VALIDATED_AWS_REGION:-}" "$DEFAULT_POLL_INTERVAL" "$DEFAULT_TIMEOUT_MINUTES")
    local monitoring_exit_code=$?
    
    # Parse monitoring result
    local monitoring_status events_displayed final_monitoring_status
    while IFS='=' read -r key value; do
        case "$key" in
            "MONITORING_RESULT")
                monitoring_status="$value"
                ;;
            "EVENTS_DISPLAYED")
                events_displayed="$value"
                ;;
            "FINAL_STATUS")
                final_monitoring_status="$value"
                ;;
        esac
    done <<< "$monitoring_result"
    
    # Store monitoring results
    export MONITORING_RESULT="$monitoring_status"
    export EVENTS_MONITORED="${events_displayed:-0}"
    
    # Update final status if monitoring provided more recent information
    if [[ -n "$final_monitoring_status" ]] && [[ "$final_monitoring_status" != "timeout" ]]; then
        export FINAL_STACK_STATUS="$final_monitoring_status"
    fi
    
    log_info "Deletion monitoring completed with result: $monitoring_status"
    log_info "Events monitored: $EVENTS_MONITORED"
    
    return "$monitoring_exit_code"
}

# Detect and confirm deletion completion
detect_deletion_completion() {
    # Skip completion detection if we're not waiting for completion
    if [[ "$VALIDATED_WAIT_FOR_COMPLETION" == "false" ]]; then
        log_info "Wait for completion disabled - skipping completion detection"
        export COMPLETION_RESULT="skipped"
        return 0
    fi
    
    # Skip if deletion was skipped or failed
    if [[ "$DELETION_RESULT" == "skipped" ]] || [[ "$DELETION_RESULT" == "error" ]] || [[ "$DELETION_RESULT" == "failed" ]]; then
        log_info "Skipping completion detection due to deletion result: $DELETION_RESULT"
        export COMPLETION_RESULT="not_applicable"
        return 0
    fi
    
    print_section "Deletion Completion Detection"
    
    # Perform comprehensive completion detection
    local completion_result
    completion_result=$(detect_completion_with_tracking "$VALIDATED_STACK_NAME" "${VALIDATED_AWS_REGION:-}" "$DELETION_START_TIME" "$DEFAULT_TIMEOUT_MINUTES")
    local completion_exit_code=$?
    
    # Parse completion result
    local detection_result completion_status final_completion_status
    while IFS='=' read -r key value; do
        case "$key" in
            "DETECTION_RESULT")
                detection_result="$value"
                ;;
            "COMPLETION_RESULT")
                completion_status="$value"
                ;;
            "FINAL_STATUS")
                final_completion_status="$value"
                ;;
            "STATUS_CHANGES")
                STATUS_CHANGES="$value"
                ;;
        esac
    done <<< "$completion_result"
    
    # Store completion results
    export COMPLETION_RESULT="$completion_status"
    
    # Update final status with completion detection results
    if [[ -n "$final_completion_status" ]]; then
        export FINAL_STACK_STATUS="$final_completion_status"
    fi
    
    log_info "Completion detection finished with result: $completion_status"
    
    return "$completion_exit_code"
}

# Generate final status report and set outputs
generate_final_report() {
    print_section "Final Status Report Generation"
    
    # Record deletion end time
    DELETION_END_TIME=$(date +%s)
    
    # Calculate total duration
    local duration_formatted="N/A"
    if [[ -n "$DELETION_START_TIME" ]] && [[ -n "$DELETION_END_TIME" ]]; then
        duration_formatted=$(format_duration "$DELETION_START_TIME" "$DELETION_END_TIME")
    fi
    
    # Determine overall operation result
    local operation_result
    case "$DELETION_RESULT" in
        "initiated"|"monitoring")
            if [[ "$COMPLETION_RESULT" == "success" ]] || [[ "$FINAL_STACK_STATUS" == "DELETE_COMPLETE" ]] || [[ "$FINAL_STACK_STATUS" == "STACK_NOT_FOUND" ]]; then
                operation_result="success"
            elif [[ "$COMPLETION_RESULT" == "failed" ]] || [[ "$FINAL_STACK_STATUS" == "DELETE_FAILED" ]]; then
                operation_result="failed"
            elif [[ "$COMPLETION_RESULT" == "timeout" ]] || [[ "$MONITORING_RESULT" == "timeout" ]]; then
                operation_result="timeout"
            else
                operation_result="unknown"
            fi
            ;;
        "skipped"|"not_needed")
            operation_result="skipped"
            ;;
        "failed"|"error")
            operation_result="failed"
            ;;
        *)
            operation_result="error"
            ;;
    esac
    
    # Generate comprehensive status report
    local report_exit_code
    complete_status_reporting \
        "$VALIDATED_STACK_NAME" \
        "$FINAL_STACK_STATUS" \
        "$duration_formatted" \
        "$operation_result" \
        "$DELETION_START_TIME" \
        "$DELETION_END_TIME" \
        "$EVENTS_MONITORED" \
        "$STATUS_CHANGES" \
        "${DELETION_MESSAGE:-}"
    report_exit_code=$?
    
    log_info "Final report generation completed"
    return "$report_exit_code"
}

# Cleanup function for error handling and resource cleanup
cleanup_on_exit() {
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script exiting with error code: $exit_code"
        
        # Generate error report if we have enough information
        if [[ -n "${VALIDATED_STACK_NAME:-}" ]]; then
            local error_duration="N/A"
            if [[ -n "$DELETION_START_TIME" ]]; then
                local current_time
                current_time=$(date +%s)
                error_duration=$(format_duration "$DELETION_START_TIME" "$current_time")
            fi
            
            report_error "$VALIDATED_STACK_NAME" "Script execution failed with exit code $exit_code" "ERROR"
        fi
    fi
    
    log_debug "Cleanup completed"
}

# Set up error handling and cleanup
trap cleanup_on_exit EXIT

# Main execution function
main() {
    # Display script header
    display_script_header
    
    # Parse and validate arguments
    parse_arguments "$@"
    
    # Validate AWS environment
    validate_aws_environment
    
    # Analyze stack state
    if ! analyze_stack_for_deletion; then
        local analysis_exit_code=$?
        log_error "Stack analysis failed with exit code: $analysis_exit_code"
        
        # Generate error report and exit
        report_error "$VALIDATED_STACK_NAME" "$STACK_ANALYSIS_MESSAGE" "ANALYSIS_FAILED"
        exit "$analysis_exit_code"
    fi
    
    # Execute stack deletion
    if ! execute_stack_deletion; then
        local deletion_exit_code=$?
        log_error "Stack deletion execution failed with exit code: $deletion_exit_code"
        
        # Still proceed to monitoring if deletion was initiated but had issues
        if [[ "$DELETION_RESULT" != "initiated" ]] && [[ "$DELETION_RESULT" != "monitoring" ]]; then
            generate_final_report
            exit "$deletion_exit_code"
        fi
    fi
    
    # Monitor deletion progress
    if ! monitor_deletion_progress; then
        local monitoring_exit_code=$?
        log_warning "Deletion monitoring encountered issues (exit code: $monitoring_exit_code)"
        # Continue to completion detection as monitoring issues may not be fatal
    fi
    
    # Detect deletion completion
    if ! detect_deletion_completion; then
        local completion_exit_code=$?
        log_warning "Completion detection encountered issues (exit code: $completion_exit_code)"
        # Continue to final report generation
    fi
    
    # Generate final report and determine exit code
    if ! generate_final_report; then
        local report_exit_code=$?
        log_error "Final report generation failed with exit code: $report_exit_code"
        exit "$report_exit_code"
    fi
    
    log_success "CloudFormation stack deletion process completed successfully"
}

# Execute main function with all arguments
main "$@"
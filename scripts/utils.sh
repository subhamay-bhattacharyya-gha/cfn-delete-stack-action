#!/bin/bash

# Common utility functions for CloudFormation stack deletion action
# Provides logging, error handling, and formatting utilities

set -euo pipefail

# Color codes for console output (only define if not already defined)
if [[ -z "${RED:-}" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m' # No Color
fi

# GitHub Actions logging functions with proper formatting
log_info() {
    local message="$1"
    local timestamp=$(get_timestamp)
    echo -e "${BLUE}[INFO]${NC} ${timestamp} - ${message}"
    echo "::notice::${message}"
}

log_warning() {
    local message="$1"
    local timestamp=$(get_timestamp)
    echo -e "${YELLOW}[WARN]${NC} ${timestamp} - ${message}"
    echo "::warning::${message}"
}

log_error() {
    local message="$1"
    local timestamp=$(get_timestamp)
    echo -e "${RED}[ERROR]${NC} ${timestamp} - ${message}" >&2
    echo "::error::${message}"
}

log_success() {
    local message="$1"
    local timestamp=$(get_timestamp)
    echo -e "${GREEN}[SUCCESS]${NC} ${timestamp} - ${message}"
    echo "::notice::${message}"
}

log_debug() {
    local message="$1"
    local timestamp=$(get_timestamp)
    if [[ "${DEBUG:-false}" == "true" ]]; then
        echo -e "[DEBUG] ${timestamp} - ${message}"
        echo "::debug::${message}"
    fi
}

# Error handling functions with proper exit codes
handle_error() {
    local exit_code="$1"
    local error_message="$2"
    log_error "$error_message"
    exit "$exit_code"
}

handle_validation_error() {
    local error_message="$1"
    handle_error 1 "Validation Error: $error_message"
}

handle_auth_error() {
    local error_message="$1"
    handle_error 2 "Authentication Error: $error_message"
}

handle_stack_error() {
    local error_message="$1"
    handle_error 3 "Stack Operation Error: $error_message"
}

handle_deletion_error() {
    local error_message="$1"
    handle_error 4 "Stack Deletion Error: $error_message"
}

# Timestamp and formatting utilities
get_timestamp() {
    date -u '+%Y-%m-%d %H:%M:%S UTC'
}

get_iso_timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

format_duration() {
    local start_time="$1"
    local end_time="$2"
    local duration=$((end_time - start_time))
    
    local hours=$((duration / 3600))
    local minutes=$(((duration % 3600) / 60))
    local seconds=$((duration % 60))
    
    if [[ $hours -gt 0 ]]; then
        echo "${hours}h ${minutes}m ${seconds}s"
    elif [[ $minutes -gt 0 ]]; then
        echo "${minutes}m ${seconds}s"
    else
        echo "${seconds}s"
    fi
}

# Console output formatting utilities
print_header() {
    local title="$1"
    local length=${#title}
    local border=""
    
    # Create border string
    for ((i=0; i<length+4; i++)); do
        border="${border}="
    done
    
    echo ""
    echo "$border"
    echo "  $title"
    echo "$border"
    echo ""
}

print_section() {
    local title="$1"
    local length=${#title}
    local border=""
    
    # Create border string
    for ((i=0; i<length+2; i++)); do
        border="${border}-"
    done
    
    echo ""
    echo " $title"
    echo " $border"
}

# Progress indicator for long-running operations
show_spinner() {
    local pid=$1
    local message="$2"
    local spin='|/-\'
    local i=0
    
    while kill -0 "$pid" 2>/dev/null; do
        i=$(((i + 1) % 4))
        printf "\r${message} ${spin:$i:1}"
        sleep 0.1
    done
    printf "\r${message} ✓\n"
}

# Utility to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Utility to check if variable is set and non-empty
is_set() {
    [[ -n "${1:-}" ]]
}

# Utility to trim whitespace from string
trim() {
    local var="$1"
    # Remove leading whitespace
    var="${var#"${var%%[![:space:]]*}"}"
    # Remove trailing whitespace
    var="${var%"${var##*[![:space:]]}"}"
    echo "$var"
}

# Utility to convert string to uppercase
to_upper() {
    echo "$1" | tr '[:lower:]' '[:upper:]'
}

# Utility to convert string to lowercase
to_lower() {
    echo "$1" | tr '[:upper:]' '[:lower:]'
}

# AWS API error handling with retry logic and exponential backoff
retry_aws_operation_with_backoff() {
    local command="$1"
    local operation_name="$2"
    local max_attempts="${3:-5}"
    local base_delay="${4:-2}"
    local max_delay="${5:-60}"
    local timeout_seconds="${6:-300}"
    
    local attempt=1
    local delay="$base_delay"
    local start_time
    start_time=$(date +%s)
    
    log_debug "Starting AWS operation: $operation_name (max attempts: $max_attempts, timeout: ${timeout_seconds}s)"
    
    while [[ $attempt -le $max_attempts ]]; do
        # Check timeout
        local current_time
        current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        
        if [[ $elapsed_time -gt $timeout_seconds ]]; then
            log_error "$operation_name timed out after ${timeout_seconds}s"
            return 124  # Timeout exit code
        fi
        
        log_debug "Attempting $operation_name (attempt $attempt/$max_attempts)"
        
        local result
        local exit_code
        
        # Execute command with timeout
        if command -v timeout >/dev/null 2>&1; then
            result=$(timeout $((timeout_seconds - elapsed_time)) bash -c "$command" 2>&1)
            exit_code=$?
        else
            result=$(eval "$command" 2>&1)
            exit_code=$?
        fi
        
        if [[ $exit_code -eq 0 ]]; then
            log_debug "$operation_name succeeded on attempt $attempt"
            echo "$result"
            return 0
        fi
        
        # Analyze error and determine if retry is appropriate
        local error_type
        error_type=$(classify_aws_error "$result")
        
        case "$error_type" in
            "THROTTLING"|"RATE_LIMIT"|"SERVICE_UNAVAILABLE")
                if [[ $attempt -lt $max_attempts ]]; then
                    log_warning "$operation_name failed with $error_type, retrying in ${delay}s... (attempt $attempt/$max_attempts)"
                    log_debug "Error details: $result"
                    sleep "$delay"
                    delay=$(( delay * 2 ))
                    if [[ $delay -gt $max_delay ]]; then
                        delay=$max_delay
                    fi
                    ((attempt++))
                    continue
                fi
                ;;
            "TIMEOUT")
                if [[ $attempt -lt $max_attempts ]]; then
                    log_warning "$operation_name timed out, retrying in ${delay}s... (attempt $attempt/$max_attempts)"
                    sleep "$delay"
                    delay=$(( delay * 2 ))
                    if [[ $delay -gt $max_delay ]]; then
                        delay=$max_delay
                    fi
                    ((attempt++))
                    continue
                fi
                ;;
            "TRANSIENT"|"NETWORK")
                if [[ $attempt -lt $max_attempts ]]; then
                    log_warning "$operation_name failed with transient error, retrying in ${delay}s... (attempt $attempt/$max_attempts)"
                    log_debug "Error details: $result"
                    sleep "$delay"
                    delay=$(( delay * 2 ))
                    if [[ $delay -gt $max_delay ]]; then
                        delay=$max_delay
                    fi
                    ((attempt++))
                    continue
                fi
                ;;
            *)
                # Non-retryable error
                log_error "$operation_name failed with non-retryable error: $(format_aws_error_message "$result")"
                echo "$result"
                return $exit_code
                ;;
        esac
    done
    
    # Max attempts reached
    log_error "$operation_name failed after $max_attempts attempts"
    echo "$result"
    return $exit_code
}

# Classify AWS API errors for retry logic
classify_aws_error() {
    local error_message="$1"
    
    # Convert to lowercase for easier matching
    local error_lower
    error_lower=$(echo "$error_message" | tr '[:upper:]' '[:lower:]')
    
    # Throttling and rate limiting errors
    if [[ "$error_lower" =~ throttling ]] || \
       [[ "$error_lower" =~ "rate exceeded" ]] || \
       [[ "$error_lower" =~ "requestlimitexceeded" ]] || \
       [[ "$error_lower" =~ "too many requests" ]]; then
        echo "THROTTLING"
        return
    fi
    
    # Service unavailable errors
    if [[ "$error_lower" =~ "service unavailable" ]] || \
       [[ "$error_lower" =~ "serviceunavailable" ]] || \
       [[ "$error_lower" =~ "internal server error" ]] || \
       [[ "$error_lower" =~ "internalservererror" ]]; then
        echo "SERVICE_UNAVAILABLE"
        return
    fi
    
    # Timeout errors
    if [[ "$error_lower" =~ timeout ]] || \
       [[ "$error_lower" =~ "timed out" ]] || \
       [[ "$error_lower" =~ "connection timeout" ]]; then
        echo "TIMEOUT"
        return
    fi
    
    # Network and connection errors
    if [[ "$error_lower" =~ "connection" ]] || \
       [[ "$error_lower" =~ "network" ]] || \
       [[ "$error_lower" =~ "dns" ]] || \
       [[ "$error_lower" =~ "unable to locate credentials" ]]; then
        echo "NETWORK"
        return
    fi
    
    # Transient errors
    if [[ "$error_lower" =~ "temporary" ]] || \
       [[ "$error_lower" =~ "transient" ]] || \
       [[ "$error_lower" =~ "try again" ]]; then
        echo "TRANSIENT"
        return
    fi
    
    # Default to non-retryable
    echo "NON_RETRYABLE"
}

# Format AWS error messages for better readability
format_aws_error_message() {
    local error_message="$1"
    
    # Extract meaningful error information
    local formatted_message="$error_message"
    
    # Extract CloudFormation specific errors
    if [[ "$error_message" =~ ValidationError ]]; then
        formatted_message=$(echo "$error_message" | sed -n 's/.*ValidationError.*: \(.*\)/\1/p' | head -1)
        if [[ -z "$formatted_message" ]]; then
            formatted_message="$error_message"
        fi
    elif [[ "$error_message" =~ AccessDenied ]]; then
        formatted_message="Access denied - insufficient permissions for this operation"
    elif [[ "$error_message" =~ "does not exist" ]]; then
        formatted_message=$(echo "$error_message" | sed -n 's/.*\(Stack.*does not exist\).*/\1/p' | head -1)
        if [[ -z "$formatted_message" ]]; then
            formatted_message="Resource does not exist"
        fi
    fi
    
    echo "$formatted_message"
}

# Handle specific CloudFormation errors with detailed messages
handle_cloudformation_error() {
    local error_message="$1"
    local stack_name="${2:-}"
    local operation="${3:-CloudFormation operation}"
    
    local error_lower
    error_lower=$(echo "$error_message" | tr '[:upper:]' '[:lower:]')
    
    # Stack-specific errors
    if [[ "$error_lower" =~ "does not exist" ]]; then
        if [[ -n "$stack_name" ]]; then
            log_warning "Stack '$stack_name' does not exist"
            return 0  # This is often expected for deletion operations
        else
            log_error "Resource does not exist"
            return 1
        fi
    elif [[ "$error_lower" =~ "delete_in_progress" ]]; then
        log_info "Stack deletion is already in progress"
        return 0
    elif [[ "$error_lower" =~ "delete_failed" ]]; then
        log_error "Previous stack deletion failed. Manual intervention may be required."
        log_error "Check the CloudFormation console for detailed error information."
        return 1
    elif [[ "$error_lower" =~ "access.*denied" ]] || [[ "$error_lower" =~ "unauthorized" ]]; then
        log_error "Access denied: Insufficient permissions for $operation"
        log_error "Required permissions: cloudformation:DescribeStacks, cloudformation:DescribeStackEvents, cloudformation:DeleteStack"
        return 2
    elif [[ "$error_lower" =~ "throttling" ]] || [[ "$error_lower" =~ "rate.*exceeded" ]]; then
        log_warning "API rate limit exceeded. The operation will be retried automatically."
        return 3
    elif [[ "$error_lower" =~ "validation.*error" ]]; then
        local validation_msg
        validation_msg=$(format_aws_error_message "$error_message")
        log_error "Validation error: $validation_msg"
        return 1
    elif [[ "$error_lower" =~ "resource.*not.*ready" ]] || [[ "$error_lower" =~ "in.*progress" ]]; then
        log_warning "Stack is in a transitional state. Wait for current operation to complete."
        return 3
    else
        # Generic error handling
        local formatted_msg
        formatted_msg=$(format_aws_error_message "$error_message")
        log_error "$operation failed: $formatted_msg"
        return 1
    fi
}

# Timeout handler for long-running operations
setup_operation_timeout() {
    local timeout_seconds="$1"
    local operation_name="$2"
    local cleanup_function="${3:-}"
    
    # Set up timeout handler
    (
        sleep "$timeout_seconds"
        log_error "$operation_name timed out after ${timeout_seconds}s"
        if [[ -n "$cleanup_function" ]] && command -v "$cleanup_function" >/dev/null 2>&1; then
            log_info "Running cleanup function: $cleanup_function"
            "$cleanup_function"
        fi
        # Send SIGTERM to parent process group
        kill -TERM -$$
    ) &
    
    local timeout_pid=$!
    echo "$timeout_pid"
}

# Cancel operation timeout
cancel_operation_timeout() {
    local timeout_pid="$1"
    
    if [[ -n "$timeout_pid" ]] && kill -0 "$timeout_pid" 2>/dev/null; then
        kill "$timeout_pid" 2>/dev/null || true
        wait "$timeout_pid" 2>/dev/null || true
    fi
}

# Enhanced error handling for AWS operations with context
handle_aws_operation_error() {
    local exit_code="$1"
    local error_message="$2"
    local operation_context="$3"
    local stack_name="${4:-}"
    
    case "$exit_code" in
        0)
            return 0
            ;;
        124)
            handle_error 124 "Operation timeout: $operation_context timed out"
            ;;
        126)
            handle_error 126 "Permission denied: Cannot execute $operation_context"
            ;;
        127)
            handle_error 127 "Command not found: Required command for $operation_context not available"
            ;;
        *)
            # Use CloudFormation-specific error handling
            handle_cloudformation_error "$error_message" "$stack_name" "$operation_context"
            local cf_exit_code=$?
            
            case "$cf_exit_code" in
                0)
                    return 0
                    ;;
                2)
                    handle_auth_error "$error_message"
                    ;;
                3)
                    # Retryable error - let caller handle retry
                    return 3
                    ;;
                *)
                    handle_error "$exit_code" "$operation_context failed: $(format_aws_error_message "$error_message")"
                    ;;
            esac
            ;;
    esac
}

# Handle stack dependency errors and provide detailed guidance
handle_stack_dependency_error() {
    local error_message="$1"
    local stack_name="${2:-}"
    
    local error_lower
    error_lower=$(echo "$error_message" | tr '[:upper:]' '[:lower:]')
    
    # Check for dependency-related errors
    if [[ "$error_lower" =~ "dependent.*resource" ]] || [[ "$error_lower" =~ "resource.*dependency" ]]; then
        log_error "Stack '$stack_name' has dependent resources that prevent deletion"
        log_error "Common causes:"
        log_error "  - Other stacks reference resources from this stack"
        log_error "  - Resources have DeletionPolicy: Retain"
        log_error "  - Cross-stack references (Exports/Imports) exist"
        log_error ""
        log_error "Recommended actions:"
        log_error "  1. Check for stacks that import outputs from this stack"
        log_error "  2. Delete dependent stacks first"
        log_error "  3. Remove cross-stack references"
        log_error "  4. Check for retained resources that need manual cleanup"
        return 1
    elif [[ "$error_lower" =~ "export.*cannot.*be.*deleted" ]] || [[ "$error_lower" =~ "export.*is.*in.*use" ]]; then
        log_error "Stack '$stack_name' has exports that are being used by other stacks"
        log_error "Cannot delete stack while exports are in use"
        log_error ""
        log_error "To resolve this issue:"
        log_error "  1. Find stacks that import these exports:"
        log_error "     aws cloudformation list-imports --export-name <export-name>"
        log_error "  2. Delete or update dependent stacks to remove imports"
        log_error "  3. Then retry stack deletion"
        return 1
    elif [[ "$error_lower" =~ "resource.*not.*stabilized" ]] || [[ "$error_lower" =~ "resource.*in.*use" ]]; then
        log_error "Stack '$stack_name' contains resources that are not in a stable state"
        log_error "Some resources may be in use or have dependencies"
        log_error ""
        log_error "Recommended actions:"
        log_error "  1. Wait for resources to reach stable state"
        log_error "  2. Check for external dependencies (e.g., EC2 instances, RDS databases)"
        log_error "  3. Manually terminate or detach dependent resources if safe"
        log_error "  4. Retry deletion after resolving dependencies"
        return 1
    elif [[ "$error_lower" =~ "rollback.*failed" ]] || [[ "$error_lower" =~ "rollback.*incomplete" ]]; then
        log_error "Stack '$stack_name' is in a failed rollback state"
        log_error "Manual intervention may be required"
        log_error ""
        log_error "Recovery options:"
        log_error "  1. Continue rollback: aws cloudformation continue-update-rollback --stack-name '$stack_name'"
        log_error "  2. Skip failed resources (if safe): Use --resources-to-skip parameter"
        log_error "  3. Contact AWS Support if rollback cannot be completed"
        return 1
    elif [[ "$error_lower" =~ "delete.*failed" ]] && [[ "$error_lower" =~ "resource" ]]; then
        log_error "One or more resources in stack '$stack_name' failed to delete"
        log_error "This may be due to:"
        log_error "  - Resources with dependencies outside the stack"
        log_error "  - Resources that require manual cleanup"
        log_error "  - Permission issues for specific resource types"
        log_error ""
        log_error "Next steps:"
        log_error "  1. Check CloudFormation events for specific resource failures"
        log_error "  2. Manually clean up failed resources if safe"
        log_error "  3. Use 'Retain' deletion policy for problematic resources"
        log_error "  4. Retry stack deletion"
        return 1
    fi
    
    return 0  # Not a recognized dependency error
}

# Handle stack deletion failures with specific guidance
handle_stack_deletion_failure() {
    local stack_name="$1"
    local failure_reason="${2:-}"
    local stack_status="${3:-}"
    
    log_error "Stack deletion failed for '$stack_name'"
    
    case "$stack_status" in
        "DELETE_FAILED")
            log_error "Stack is in DELETE_FAILED state"
            log_error "Failure reason: $failure_reason"
            log_error ""
            log_error "Recovery options:"
            log_error "  1. Retry deletion (some failures are transient)"
            log_error "  2. Check CloudFormation events for specific resource failures"
            log_error "  3. Manually resolve resource dependencies"
            log_error "  4. Use AWS CLI to skip problematic resources:"
            log_error "     aws cloudformation delete-stack --stack-name '$stack_name' --retain-resources <resource-logical-id>"
            ;;
        "ROLLBACK_FAILED")
            log_error "Stack rollback failed during deletion"
            log_error "Manual intervention required"
            log_error ""
            log_error "Recovery steps:"
            log_error "  1. Continue rollback: aws cloudformation continue-update-rollback --stack-name '$stack_name'"
            log_error "  2. Check for resources that can be skipped safely"
            log_error "  3. Contact AWS Support if needed"
            ;;
        *)
            log_error "Stack is in unexpected state: $stack_status"
            log_error "Reason: $failure_reason"
            ;;
    esac
    
    # Provide general troubleshooting guidance
    log_error ""
    log_error "General troubleshooting steps:"
    log_error "  1. View detailed events: aws cloudformation describe-stack-events --stack-name '$stack_name'"
    log_error "  2. Check for resource dependencies in AWS Console"
    log_error "  3. Verify permissions for all resource types in the stack"
    log_error "  4. Consider using CloudFormation drift detection to identify manual changes"
}

# Analyze stack for potential deletion issues before attempting deletion
analyze_stack_for_deletion_risks() {
    local stack_name="$1"
    local region="${2:-}"
    
    log_info "Analyzing stack '$stack_name' for potential deletion risks..."
    
    # Get stack information
    local stack_info
    stack_info=$(get_stack_info_with_resources "$stack_name" "$region")
    local info_exit_code=$?
    
    if [[ $info_exit_code -ne 0 ]]; then
        log_warning "Could not retrieve detailed stack information for risk analysis"
        return 0
    fi
    
    local risks_found=0
    
    # Check for exports
    local exports
    exports=$(echo "$stack_info" | jq -r '.Stacks[0].Outputs[]? | select(.ExportName != null) | .ExportName' 2>/dev/null || echo "")
    
    if [[ -n "$exports" ]]; then
        log_warning "Stack has exports that may be used by other stacks:"
        while IFS= read -r export_name; do
            if [[ -n "$export_name" ]]; then
                log_warning "  - Export: $export_name"
                # Check if export is in use
                local import_check
                import_check=$(aws cloudformation list-imports --export-name "$export_name" --output json 2>/dev/null || echo '{"Imports":[]}')
                local import_count
                import_count=$(echo "$import_check" | jq '.Imports | length' 2>/dev/null || echo "0")
                
                if [[ "$import_count" -gt 0 ]]; then
                    log_warning "    Used by $import_count stack(s) - deletion will fail"
                    risks_found=1
                fi
            fi
        done <<< "$exports"
    fi
    
    # Check for nested stacks
    local nested_stacks
    nested_stacks=$(echo "$stack_info" | jq -r '.Stacks[0].StackResources[]? | select(.ResourceType == "AWS::CloudFormation::Stack") | .LogicalResourceId' 2>/dev/null || echo "")
    
    if [[ -n "$nested_stacks" ]]; then
        log_warning "Stack contains nested stacks:"
        while IFS= read -r nested_stack; do
            if [[ -n "$nested_stack" ]]; then
                log_warning "  - Nested stack: $nested_stack"
            fi
        done <<< "$nested_stacks"
        log_warning "Nested stacks will be deleted automatically with parent stack"
    fi
    
    # Check for resources with DeletionPolicy: Retain
    local retained_resources
    retained_resources=$(aws cloudformation get-template --stack-name "$stack_name" --output json 2>/dev/null | \
        jq -r '.TemplateBody | to_entries[] | select(.value.DeletionPolicy == "Retain") | .key' 2>/dev/null || echo "")
    
    if [[ -n "$retained_resources" ]]; then
        log_info "Stack has resources with DeletionPolicy: Retain (will not be deleted):"
        while IFS= read -r resource; do
            if [[ -n "$resource" ]]; then
                log_info "  - Resource: $resource"
            fi
        done <<< "$retained_resources"
    fi
    
    if [[ $risks_found -eq 1 ]]; then
        log_warning "Potential deletion risks detected. Review the warnings above before proceeding."
        return 1
    else
        log_info "No significant deletion risks detected"
        return 0
    fi
}

# Get stack information including resources
get_stack_info_with_resources() {
    local stack_name="$1"
    local region="${2:-}"
    
    # Build AWS CLI command
    local aws_cmd="aws cloudformation describe-stacks --stack-name '$stack_name' --output json"
    if [[ -n "$region" ]]; then
        aws_cmd="$aws_cmd --region '$region'"
    fi
    
    # Execute with retry logic
    retry_aws_operation_with_backoff "$aws_cmd" "Get stack info with resources for '$stack_name'" 3 2 30 120
}

# Handle specific CloudFormation deletion error scenarios
handle_deletion_error_scenarios() {
    local error_message="$1"
    local stack_name="$2"
    
    # First try dependency error handling
    if handle_stack_dependency_error "$error_message" "$stack_name"; then
        return 0
    fi
    
    local error_lower
    error_lower=$(echo "$error_message" | tr '[:upper:]' '[:lower:]')
    
    # Handle specific deletion scenarios
    if [[ "$error_lower" =~ "cannot.*delete.*stack" ]] && [[ "$error_lower" =~ "in.*progress" ]]; then
        log_error "Cannot delete stack '$stack_name' - another operation is in progress"
        log_error "Wait for the current operation to complete before retrying deletion"
        log_error ""
        log_error "To check current operation status:"
        log_error "  aws cloudformation describe-stacks --stack-name '$stack_name' --query 'Stacks[0].StackStatus'"
        return 1
    elif [[ "$error_lower" =~ "user.*initiated" ]] && [[ "$error_lower" =~ "cancel" ]]; then
        log_warning "Stack operation was cancelled by user"
        log_info "You can retry the deletion operation"
        return 0
    elif [[ "$error_lower" =~ "insufficient.*privileges" ]] || [[ "$error_lower" =~ "access.*denied" ]]; then
        log_error "Insufficient privileges to delete stack '$stack_name'"
        log_error "Required permissions:"
        log_error "  - cloudformation:DeleteStack"
        log_error "  - cloudformation:DescribeStacks"
        log_error "  - cloudformation:DescribeStackEvents"
        log_error "  - Permissions for all resource types in the stack"
        return 2
    elif [[ "$error_lower" =~ "stack.*not.*exist" ]]; then
        log_info "Stack '$stack_name' does not exist - deletion not needed"
        return 0
    fi
    
    return 1  # Unhandled error
}

# Export functions for use in other scripts
export -f log_info log_warning log_error log_success log_debug
export -f handle_error handle_validation_error handle_auth_error handle_stack_error handle_deletion_error
export -f get_timestamp get_iso_timestamp format_duration
export -f print_header print_section show_spinner
export -f command_exists is_set trim to_upper to_lower
export -f retry_aws_operation_with_backoff classify_aws_error format_aws_error_message
export -f handle_cloudformation_error setup_operation_timeout cancel_operation_timeout handle_aws_operation_error
export -f handle_stack_dependency_error handle_stack_deletion_failure analyze_stack_for_deletion_risks
export -f get_stack_info_with_resources handle_deletion_error_scenarios
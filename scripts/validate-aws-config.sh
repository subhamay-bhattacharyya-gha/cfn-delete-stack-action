#!/bin/bash

# AWS Configuration and Authentication Validation Script
# Validates AWS CLI installation, credentials, and region configuration

set -euo pipefail

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Validate AWS CLI installation
validate_aws_cli_installation() {
    log_info "Validating AWS CLI installation..."
    
    if ! command_exists aws; then
        handle_auth_error "AWS CLI is not installed or not in PATH"
    fi
    
    local aws_version
    aws_version=$(aws --version 2>&1 | head -n1)
    log_info "AWS CLI version: $aws_version"
    
    # Check for minimum required version (AWS CLI v2)
    if [[ "$aws_version" =~ aws-cli/1\. ]]; then
        log_warning "AWS CLI v1 detected. Consider upgrading to v2 for better performance"
    fi
}

# Validate AWS credentials with enhanced error handling
validate_aws_credentials() {
    log_info "Validating AWS credentials..."
    
    # Check if credentials are configured with enhanced retry
    local credential_check_result
    credential_check_result=$(retry_aws_operation_with_backoff "aws sts get-caller-identity --output json" "AWS credential validation" 3 2 30 120)
    local credential_exit_code=$?
    
    if ! handle_aws_operation_error "$credential_exit_code" "$credential_check_result" "AWS credential validation"; then
        handle_auth_error "AWS credentials are not configured or invalid. Please ensure AWS credentials are properly set up through environment variables, IAM roles, or AWS credential files."
    fi
    
    # Parse caller identity information
    if [[ -z "$credential_check_result" ]]; then
        handle_auth_error "Failed to retrieve AWS caller identity"
    fi
    
    local user_id account_id arn
    user_id=$(echo "$credential_check_result" | jq -r '.UserId // "N/A"')
    account_id=$(echo "$credential_check_result" | jq -r '.Account // "N/A"')
    arn=$(echo "$credential_check_result" | jq -r '.Arn // "N/A"')
    
    log_info "AWS Identity validated:"
    log_info "  User ID: $user_id"
    log_info "  Account ID: $account_id"
    log_info "  ARN: $arn"
}

# Validate AWS region configuration
validate_aws_region() {
    log_info "Validating AWS region configuration..."
    
    local configured_region="${AWS_REGION:-}"
    
    if [[ -z "$configured_region" ]]; then
        # Try to get region from AWS CLI configuration
        configured_region=$(aws configure get region 2>/dev/null || echo "")
        
        if [[ -z "$configured_region" ]]; then
            handle_auth_error "AWS region is not configured. Please set AWS_REGION environment variable or configure default region."
        fi
    fi
    
    # Validate region format (basic check)
    if [[ ! "$configured_region" =~ ^[a-z]{2}-[a-z]+-[0-9]+$ ]]; then
        handle_auth_error "Invalid AWS region format: $configured_region. Expected format: us-east-1, eu-west-1, etc."
    fi
    
    # Test region accessibility
    if ! aws ec2 describe-regions --region-names "$configured_region" >/dev/null 2>&1; then
        handle_auth_error "AWS region '$configured_region' is not accessible or does not exist"
    fi
    
    log_info "AWS region validated: $configured_region"
    
    # Set region for subsequent operations
    export AWS_DEFAULT_REGION="$configured_region"
}

# Validate CloudFormation service access with enhanced error handling
validate_cloudformation_access() {
    log_info "Validating CloudFormation service access..."
    
    # Test basic CloudFormation access by listing stacks (with limit to minimize API calls)
    local cf_access_result
    cf_access_result=$(retry_aws_operation_with_backoff "aws cloudformation list-stacks --max-items 1 --output json" "CloudFormation service access validation" 3 2 30 120)
    local cf_exit_code=$?
    
    if ! handle_aws_operation_error "$cf_exit_code" "$cf_access_result" "CloudFormation service access validation"; then
        handle_auth_error "Unable to access CloudFormation service. Please verify your AWS credentials have CloudFormation permissions."
    fi
    
    log_info "CloudFormation service access validated"
}

# Check required permissions for CloudFormation operations
validate_cloudformation_permissions() {
    log_info "Validating CloudFormation permissions..."
    
    # Create a temporary policy document to test permissions
    local test_policy='{
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Action": [
                    "cloudformation:DescribeStacks",
                    "cloudformation:DescribeStackEvents",
                    "cloudformation:DeleteStack"
                ],
                "Resource": "*"
            }
        ]
    }'
    
    # Test if we can simulate the required permissions
    # Note: This is a basic check - actual permissions may vary based on resource constraints
    local required_actions=(
        "cloudformation:DescribeStacks"
        "cloudformation:DescribeStackEvents"
        "cloudformation:DeleteStack"
    )
    
    local missing_permissions=()
    
    for action in "${required_actions[@]}"; do
        # Use IAM simulate-principal-policy if available, otherwise skip detailed permission check
        if command_exists jq && aws iam get-user >/dev/null 2>&1; then
            local user_arn
            user_arn=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null)
            
            if [[ -n "$user_arn" ]]; then
                local simulation_result
                simulation_result=$(aws iam simulate-principal-policy \
                    --policy-source-arn "$user_arn" \
                    --action-names "$action" \
                    --resource-arns "*" \
                    --query 'EvaluationResults[0].EvalDecision' \
                    --output text 2>/dev/null || echo "unknown")
                
                if [[ "$simulation_result" == "implicitDeny" || "$simulation_result" == "explicitDeny" ]]; then
                    missing_permissions+=("$action")
                fi
            fi
        fi
    done
    
    if [[ ${#missing_permissions[@]} -gt 0 ]]; then
        log_warning "Potential missing permissions detected: ${missing_permissions[*]}"
        log_warning "Stack deletion may fail if these permissions are not available"
    else
        log_info "CloudFormation permissions appear to be sufficient"
    fi
}

# Test AWS service connectivity with retry logic
test_aws_service_connectivity() {
    log_info "Testing AWS service connectivity..."
    
    local max_retries=3
    local retry_delay=2
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        if aws sts get-caller-identity >/dev/null 2>&1; then
            log_info "AWS STS service connectivity: OK"
            break
        else
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                log_warning "AWS STS connectivity failed (attempt $retry_count/$max_retries). Retrying in ${retry_delay}s..."
                sleep $retry_delay
                retry_delay=$((retry_delay * 2))  # Exponential backoff
            else
                handle_auth_error "Failed to connect to AWS STS service after $max_retries attempts"
            fi
        fi
    done
    
    # Test CloudFormation service connectivity with retry logic
    retry_count=0
    retry_delay=2
    
    while [[ $retry_count -lt $max_retries ]]; do
        if aws cloudformation list-stacks --max-items 1 >/dev/null 2>&1; then
            log_info "AWS CloudFormation service connectivity: OK"
            break
        else
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                log_warning "CloudFormation connectivity failed (attempt $retry_count/$max_retries). Retrying in ${retry_delay}s..."
                sleep $retry_delay
                retry_delay=$((retry_delay * 2))  # Exponential backoff
            else
                handle_auth_error "Failed to connect to AWS CloudFormation service after $max_retries attempts"
            fi
        fi
    done
}

# Validate specific CloudFormation operations with retry logic
validate_cloudformation_operations() {
    log_info "Validating CloudFormation operations..."
    
    local operations=(
        "list-stacks:List stacks operation"
        "describe-stacks:Describe stacks operation"
    )
    
    for operation_info in "${operations[@]}"; do
        local operation="${operation_info%%:*}"
        local description="${operation_info##*:}"
        
        if ! test_cloudformation_operation_with_retry "$operation" "$description"; then
            handle_auth_error "CloudFormation $description failed validation"
        fi
    done
    
    log_info "CloudFormation operations validation completed"
}

# Test individual CloudFormation operation with retry logic
test_cloudformation_operation_with_retry() {
    local operation="$1"
    local description="$2"
    local max_retries=3
    local retry_delay=1
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        local result
        case "$operation" in
            "list-stacks")
                result=$(aws cloudformation list-stacks --max-items 1 --output json 2>&1)
                ;;
            "describe-stacks")
                # Try to describe a non-existent stack to test the operation without side effects
                result=$(aws cloudformation describe-stacks --stack-name "non-existent-stack-test-$(date +%s)" 2>&1 || true)
                # For describe-stacks, we expect it to fail with "does not exist" which means the operation works
                if [[ "$result" =~ "does not exist" ]]; then
                    log_debug "$description: OK (expected 'does not exist' error)"
                    return 0
                fi
                ;;
        esac
        
        if [[ $? -eq 0 ]] || [[ "$result" =~ "does not exist" ]]; then
            log_debug "$description: OK"
            return 0
        else
            retry_count=$((retry_count + 1))
            if [[ $retry_count -lt $max_retries ]]; then
                # Check if it's a throttling error
                if [[ "$result" =~ "Throttling" ]] || [[ "$result" =~ "RequestLimitExceeded" ]]; then
                    log_warning "$description throttled (attempt $retry_count/$max_retries). Retrying in ${retry_delay}s..."
                    sleep $retry_delay
                    retry_delay=$((retry_delay * 2))  # Exponential backoff
                else
                    log_error "$description failed: $result"
                    return 1
                fi
            else
                log_error "$operation failed after $max_retries attempts: $result"
                return 1
            fi
        fi
    done
    
    return 1
}

# Handle transient AWS API issues with exponential backoff (enhanced version)
retry_aws_operation() {
    local operation_command="$1"
    local operation_description="$2"
    local max_retries="${3:-3}"
    local initial_delay="${4:-1}"
    
    # Use the enhanced retry function from utils.sh
    retry_aws_operation_with_backoff "$operation_command" "$operation_description" "$max_retries" "$initial_delay" 60 180
}

# Main validation function
main() {
    print_header "AWS Configuration Validation"
    
    # Perform all validation checks
    validate_aws_cli_installation
    validate_aws_credentials
    validate_aws_region
    test_aws_service_connectivity
    validate_cloudformation_access
    validate_cloudformation_operations
    validate_cloudformation_permissions
    
    log_success "AWS configuration validation completed successfully"
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
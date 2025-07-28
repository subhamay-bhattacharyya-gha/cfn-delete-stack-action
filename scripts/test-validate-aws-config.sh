#!/bin/bash

# Unit tests for AWS configuration validation functions in validate-aws-config.sh
# Tests AWS CLI installation, credentials, region configuration, and CloudFormation access

set -euo pipefail

# Get script directory and source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-framework.sh"
source "${SCRIPT_DIR}/utils.sh"

# Mock AWS CLI responses for testing
setup_aws_mocks() {
    # Mock successful AWS CLI version
    mock_command "aws" 'case "$1" in
        "--version") echo "aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0" ;;
        "sts") case "$2" in
            "get-caller-identity") echo "{\"UserId\":\"AIDACKCEVSQ6C2EXAMPLE\",\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}" ;;
        esac ;;
        "configure") case "$2" in
            "get") echo "us-east-1" ;;
        esac ;;
        "ec2") case "$2" in
            "describe-regions") return 0 ;;
        esac ;;
        "cloudformation") case "$2" in
            "list-stacks") echo "{\"StackSummaries\":[]}" ;;
            "describe-stacks") echo "An error occurred (ValidationError) when calling the DescribeStacks operation: Stack with id non-existent-stack-test does not exist" >&2; return 255 ;;
        esac ;;
        "iam") case "$2" in
            "get-user") echo "{\"User\":{\"UserName\":\"testuser\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}}" ;;
            "simulate-principal-policy") echo "{\"EvaluationResults\":[{\"EvalDecision\":\"allowed\"}]}" ;;
        esac ;;
        *) return 1 ;;
    esac'
}

setup_aws_cli_not_found_mock() {
    mock_command "aws" 'return 127'
}

setup_aws_credentials_invalid_mock() {
    mock_command "aws" 'case "$1" in
        "--version") echo "aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0" ;;
        "sts") case "$2" in
            "get-caller-identity") echo "Unable to locate credentials" >&2; return 255 ;;
        esac ;;
        *) return 1 ;;
    esac'
}

setup_aws_region_invalid_mock() {
    mock_command "aws" 'case "$1" in
        "--version") echo "aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0" ;;
        "sts") case "$2" in
            "get-caller-identity") echo "{\"UserId\":\"AIDACKCEVSQ6C2EXAMPLE\",\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}" ;;
        esac ;;
        "configure") case "$2" in
            "get") echo "" ;;
        esac ;;
        "ec2") case "$2" in
            "describe-regions") return 255 ;;
        esac ;;
        *) return 1 ;;
    esac'
}

setup_cloudformation_access_denied_mock() {
    mock_command "aws" 'case "$1" in
        "--version") echo "aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0" ;;
        "sts") case "$2" in
            "get-caller-identity") echo "{\"UserId\":\"AIDACKCEVSQ6C2EXAMPLE\",\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}" ;;
        esac ;;
        "configure") case "$2" in
            "get") echo "us-east-1" ;;
        esac ;;
        "ec2") case "$2" in
            "describe-regions") return 0 ;;
        esac ;;
        "cloudformation") case "$2" in
            "list-stacks") echo "An error occurred (AccessDenied) when calling the ListStacks operation: User is not authorized" >&2; return 255 ;;
        esac ;;
        *) return 1 ;;
    esac'
}

# Source the validate-aws-config.sh after setting up mocks
source_validate_aws_config() {
    source "${SCRIPT_DIR}/validate-aws-config.sh"
}

# Test AWS CLI installation validation
test_validate_aws_cli_installation_success() {
    setup_aws_mocks
    source_validate_aws_config
    
    local exit_code=0
    validate_aws_cli_installation || exit_code=$?
    
    assert_equals 0 "$exit_code" "Should succeed when AWS CLI is installed"
    restore_command "aws"
}

test_validate_aws_cli_installation_not_found() {
    setup_aws_cli_not_found_mock
    source_validate_aws_config
    
    local exit_code=0
    (validate_aws_cli_installation) 2>/dev/null || exit_code=$?
    
    assert_equals 2 "$exit_code" "Should fail with exit code 2 when AWS CLI is not found"
    restore_command "aws"
}

test_validate_aws_cli_installation_v1_warning() {
    mock_command "aws" 'case "$1" in
        "--version") echo "aws-cli/1.18.0 Python/3.8.0 Linux/5.4.0 botocore/1.18.0" ;;
        *) return 1 ;;
    esac'
    source_validate_aws_config
    
    local output
    output=$(validate_aws_cli_installation 2>&1)
    
    assert_contains "$output" "AWS CLI v1 detected" "Should warn about AWS CLI v1"
    assert_contains "$output" "Consider upgrading" "Should suggest upgrading"
    restore_command "aws"
}

# Test AWS credentials validation
test_validate_aws_credentials_success() {
    setup_aws_mocks
    source_validate_aws_config
    
    local exit_code=0
    validate_aws_credentials || exit_code=$?
    
    assert_equals 0 "$exit_code" "Should succeed with valid credentials"
    restore_command "aws"
}

test_validate_aws_credentials_invalid() {
    setup_aws_credentials_invalid_mock
    source_validate_aws_config
    
    local exit_code=0
    (validate_aws_credentials) 2>/dev/null || exit_code=$?
    
    assert_equals 2 "$exit_code" "Should fail with exit code 2 for invalid credentials"
    restore_command "aws"
}

test_validate_aws_credentials_output_format() {
    setup_aws_mocks
    source_validate_aws_config
    
    local output
    output=$(validate_aws_credentials 2>&1)
    
    assert_contains "$output" "User ID:" "Should display user ID"
    assert_contains "$output" "Account ID:" "Should display account ID"
    assert_contains "$output" "ARN:" "Should display ARN"
    restore_command "aws"
}

# Test AWS region validation
test_validate_aws_region_from_env() {
    setup_aws_mocks
    source_validate_aws_config
    
    export AWS_REGION="us-west-2"
    
    local exit_code=0
    validate_aws_region_config || exit_code=$?
    
    assert_equals 0 "$exit_code" "Should succeed with AWS_REGION environment variable"
    assert_equals "us-west-2" "$AWS_DEFAULT_REGION" "Should set AWS_DEFAULT_REGION"
    
    unset AWS_REGION AWS_DEFAULT_REGION
    restore_command "aws"
}

test_validate_aws_region_from_config() {
    setup_aws_mocks
    source_validate_aws_config
    
    unset AWS_REGION 2>/dev/null || true
    
    local exit_code=0
    validate_aws_region_config || exit_code=$?
    
    assert_equals 0 "$exit_code" "Should succeed with region from AWS config"
    restore_command "aws"
}

test_validate_aws_region_not_configured() {
    mock_command "aws" 'case "$1" in
        "configure") case "$2" in
            "get") echo "" ;;
        esac ;;
        *) return 1 ;;
    esac'
    source_validate_aws_config
    
    unset AWS_REGION 2>/dev/null || true
    
    local exit_code=0
    (validate_aws_region_config) 2>/dev/null || exit_code=$?
    
    assert_equals 2 "$exit_code" "Should fail when no region is configured"
    restore_command "aws"
}

test_validate_aws_region_invalid_format() {
    mock_command "aws" 'case "$1" in
        "configure") case "$2" in
            "get") echo "invalid-region" ;;
        esac ;;
        *) return 1 ;;
    esac'
    source_validate_aws_config
    
    unset AWS_REGION 2>/dev/null || true
    
    local exit_code=0
    (validate_aws_region_config) 2>/dev/null || exit_code=$?
    
    assert_equals 2 "$exit_code" "Should fail with invalid region format"
    restore_command "aws"
}

test_validate_aws_region_inaccessible() {
    setup_aws_region_invalid_mock
    source_validate_aws_config
    
    export AWS_REGION="us-fake-1"
    
    local exit_code=0
    (validate_aws_region_config) 2>/dev/null || exit_code=$?
    
    assert_equals 2 "$exit_code" "Should fail with inaccessible region"
    
    unset AWS_REGION
    restore_command "aws"
}

# Test CloudFormation access validation
test_validate_cloudformation_access_success() {
    setup_aws_mocks
    source_validate_aws_config
    
    local exit_code=0
    validate_cloudformation_access || exit_code=$?
    
    assert_equals 0 "$exit_code" "Should succeed with valid CloudFormation access"
    restore_command "aws"
}

test_validate_cloudformation_access_denied() {
    setup_cloudformation_access_denied_mock
    source_validate_aws_config
    
    local exit_code=0
    (validate_cloudformation_access) 2>/dev/null || exit_code=$?
    
    assert_equals 2 "$exit_code" "Should fail with access denied error"
    restore_command "aws"
}

# Test CloudFormation permissions validation
test_validate_cloudformation_permissions_success() {
    setup_aws_mocks
    source_validate_aws_config
    
    local exit_code=0
    validate_cloudformation_permissions || exit_code=$?
    
    assert_equals 0 "$exit_code" "Should succeed with sufficient permissions"
    restore_command "aws"
}

test_validate_cloudformation_permissions_no_iam() {
    mock_command "aws" 'case "$1" in
        "sts") case "$2" in
            "get-caller-identity") echo "{\"UserId\":\"AIDACKCEVSQ6C2EXAMPLE\",\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}" ;;
        esac ;;
        "iam") case "$2" in
            "get-user") echo "An error occurred (AccessDenied)" >&2; return 255 ;;
        esac ;;
        *) return 1 ;;
    esac'
    source_validate_aws_config
    
    local exit_code=0
    validate_cloudformation_permissions || exit_code=$?
    
    # Should still succeed even without IAM access (just skip detailed permission check)
    assert_equals 0 "$exit_code" "Should succeed even without IAM access"
    restore_command "aws"
}

# Test AWS service connectivity
test_test_aws_service_connectivity_success() {
    setup_aws_mocks
    source_validate_aws_config
    
    local exit_code=0
    test_aws_service_connectivity || exit_code=$?
    
    assert_equals 0 "$exit_code" "Should succeed with good connectivity"
    restore_command "aws"
}

test_test_aws_service_connectivity_sts_failure() {
    mock_command "aws" 'case "$1" in
        "--version") echo "aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0" ;;
        "sts") case "$2" in
            "get-caller-identity") return 255 ;;
        esac ;;
        *) return 1 ;;
    esac'
    source_validate_aws_config
    
    local exit_code=0
    (test_aws_service_connectivity) 2>/dev/null || exit_code=$?
    
    assert_equals 2 "$exit_code" "Should fail when STS is not accessible"
    restore_command "aws"
}

test_test_aws_service_connectivity_cf_failure() {
    mock_command "aws" 'case "$1" in
        "--version") echo "aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0" ;;
        "sts") case "$2" in
            "get-caller-identity") echo "{\"UserId\":\"test\",\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}" ;;
        esac ;;
        "cloudformation") case "$2" in
            "list-stacks") return 255 ;;
        esac ;;
        *) return 1 ;;
    esac'
    source_validate_aws_config
    
    local exit_code=0
    (test_aws_service_connectivity) 2>/dev/null || exit_code=$?
    
    assert_equals 2 "$exit_code" "Should fail when CloudFormation is not accessible"
    restore_command "aws"
}

# Test CloudFormation operations validation
test_validate_cloudformation_operations_success() {
    setup_aws_mocks
    source_validate_aws_config
    
    local exit_code=0
    validate_cloudformation_operations || exit_code=$?
    
    assert_equals 0 "$exit_code" "Should succeed with valid CloudFormation operations"
    restore_command "aws"
}

test_validate_cloudformation_operations_list_failure() {
    mock_command "aws" 'case "$1" in
        "cloudformation") case "$2" in
            "list-stacks") return 255 ;;
            "describe-stacks") echo "Stack does not exist" >&2; return 255 ;;
        esac ;;
        *) return 1 ;;
    esac'
    source_validate_aws_config
    
    local exit_code=0
    (validate_cloudformation_operations) 2>/dev/null || exit_code=$?
    
    assert_equals 2 "$exit_code" "Should fail when list-stacks operation fails"
    restore_command "aws"
}

# Test individual CloudFormation operation testing
test_test_cloudformation_operation_with_retry_success() {
    setup_aws_mocks
    source_validate_aws_config
    
    local exit_code=0
    test_cloudformation_operation_with_retry "describe-stacks" "Test operation" || exit_code=$?
    
    assert_equals 0 "$exit_code" "Should succeed for describe-stacks operation"
    restore_command "aws"
}

test_test_cloudformation_operation_with_retry_throttling() {
    local call_count=0
    mock_command "aws" 'case "$1" in
        "cloudformation") case "$2" in
            "list-stacks") 
                call_count=$((call_count + 1))
                if [[ $call_count -lt 3 ]]; then
                    echo "Throttling: Rate exceeded" >&2
                    return 255
                else
                    echo "{\"StackSummaries\":[]}"
                    return 0
                fi
                ;;
        esac ;;
        *) return 1 ;;
    esac'
    source_validate_aws_config
    
    local exit_code=0
    test_cloudformation_operation_with_retry "list-stacks" "Test operation" || exit_code=$?
    
    assert_equals 0 "$exit_code" "Should succeed after throttling retry"
    restore_command "aws"
}

# Test retry AWS operation function
test_retry_aws_operation_success() {
    setup_aws_mocks
    source_validate_aws_config
    
    local result
    result=$(retry_aws_operation "aws sts get-caller-identity --output json" "Test operation")
    
    assert_contains "$result" "UserId" "Should return successful AWS operation result"
    restore_command "aws"
}

test_retry_aws_operation_failure() {
    mock_command "aws" 'return 255'
    source_validate_aws_config
    
    local exit_code=0
    (retry_aws_operation "aws sts get-caller-identity" "Test operation") 2>/dev/null || exit_code=$?
    
    assert_equals 255 "$exit_code" "Should fail after max retries"
    restore_command "aws"
}

# Test main validation function
test_main_validation_success() {
    setup_aws_mocks
    source_validate_aws_config
    
    local exit_code=0
    main || exit_code=$?
    
    assert_equals 0 "$exit_code" "Main validation should succeed with valid AWS setup"
    restore_command "aws"
}

test_main_validation_cli_missing() {
    setup_aws_cli_not_found_mock
    source_validate_aws_config
    
    local exit_code=0
    (main) 2>/dev/null || exit_code=$?
    
    assert_equals 2 "$exit_code" "Main validation should fail when AWS CLI is missing"
    restore_command "aws"
}

# Test edge cases and error scenarios
test_empty_caller_identity_response() {
    mock_command "aws" 'case "$1" in
        "--version") echo "aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0" ;;
        "sts") case "$2" in
            "get-caller-identity") echo "" ;;
        esac ;;
        *) return 1 ;;
    esac'
    source_validate_aws_config
    
    local exit_code=0
    (validate_aws_credentials) 2>/dev/null || exit_code=$?
    
    assert_equals 2 "$exit_code" "Should fail with empty caller identity response"
    restore_command "aws"
}

test_malformed_json_response() {
    mock_command "aws" 'case "$1" in
        "--version") echo "aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0" ;;
        "sts") case "$2" in
            "get-caller-identity") echo "invalid json" ;;
        esac ;;
        *) return 1 ;;
    esac'
    source_validate_aws_config
    
    local exit_code=0
    validate_aws_credentials 2>/dev/null || exit_code=$?
    
    # Should still succeed as long as the command returns 0, even with malformed JSON
    assert_equals 0 "$exit_code" "Should handle malformed JSON gracefully"
    restore_command "aws"
}

# Main test runner
main() {
    setup_test_env
    init_test_suite "AWS Configuration Validation Tests"
    
    # Test AWS CLI installation validation
    run_test "validate_aws_cli_installation succeeds when CLI is installed" test_validate_aws_cli_installation_success
    run_test "validate_aws_cli_installation fails when CLI is not found" test_validate_aws_cli_installation_not_found
    run_test "validate_aws_cli_installation warns about v1" test_validate_aws_cli_installation_v1_warning
    
    # Test AWS credentials validation
    run_test "validate_aws_credentials succeeds with valid credentials" test_validate_aws_credentials_success
    run_test "validate_aws_credentials fails with invalid credentials" test_validate_aws_credentials_invalid
    run_test "validate_aws_credentials displays identity information" test_validate_aws_credentials_output_format
    
    # Test AWS region validation
    run_test "validate_aws_region works with AWS_REGION env var" test_validate_aws_region_from_env
    run_test "validate_aws_region works with AWS config" test_validate_aws_region_from_config
    run_test "validate_aws_region fails when not configured" test_validate_aws_region_not_configured
    run_test "validate_aws_region fails with invalid format" test_validate_aws_region_invalid_format
    run_test "validate_aws_region fails with inaccessible region" test_validate_aws_region_inaccessible
    
    # Test CloudFormation access validation
    run_test "validate_cloudformation_access succeeds with valid access" test_validate_cloudformation_access_success
    run_test "validate_cloudformation_access fails with access denied" test_validate_cloudformation_access_denied
    
    # Test CloudFormation permissions validation
    run_test "validate_cloudformation_permissions succeeds with permissions" test_validate_cloudformation_permissions_success
    run_test "validate_cloudformation_permissions handles no IAM access" test_validate_cloudformation_permissions_no_iam
    
    # Test AWS service connectivity
    run_test "test_aws_service_connectivity succeeds with good connectivity" test_test_aws_service_connectivity_success
    run_test "test_aws_service_connectivity fails with STS failure" test_test_aws_service_connectivity_sts_failure
    run_test "test_aws_service_connectivity fails with CloudFormation failure" test_test_aws_service_connectivity_cf_failure
    
    # Test CloudFormation operations validation
    run_test "validate_cloudformation_operations succeeds with valid operations" test_validate_cloudformation_operations_success
    run_test "validate_cloudformation_operations fails with list failure" test_validate_cloudformation_operations_list_failure
    
    # Test individual operation testing
    run_test "test_cloudformation_operation_with_retry succeeds" test_test_cloudformation_operation_with_retry_success
    run_test "test_cloudformation_operation_with_retry handles throttling" test_test_cloudformation_operation_with_retry_throttling
    
    # Test retry function
    run_test "retry_aws_operation succeeds with valid operation" test_retry_aws_operation_success
    run_test "retry_aws_operation fails after max retries" test_retry_aws_operation_failure
    
    # Test main validation function
    run_test "main validation succeeds with valid AWS setup" test_main_validation_success
    run_test "main validation fails when AWS CLI is missing" test_main_validation_cli_missing
    
    # Test edge cases
    run_test "handles empty caller identity response" test_empty_caller_identity_response
    run_test "handles malformed JSON response" test_malformed_json_response
    
    print_test_results
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
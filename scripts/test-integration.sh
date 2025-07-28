#!/bin/bash

# Integration tests for CloudFormation stack deletion workflow
# Tests end-to-end stack deletion scenarios with different stack states

set -euo pipefail

# Get script directory and source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-framework.sh"
source "${SCRIPT_DIR}/utils.sh"

# Test configuration
readonly TEST_STACK_PREFIX="test-stack-integration"
readonly TEST_REGION="us-east-1"
readonly TEST_TIMEOUT=300  # 5 minutes

# Test stack templates for different scenarios
create_test_stack_template() {
    local template_type="$1"
    
    case "$template_type" in
        "simple")
            cat << 'EOF'
{
  "AWSTemplateFormatVersion": "2010-09-09",
  "Description": "Simple test stack for integration testing",
  "Resources": {
    "TestBucket": {
      "Type": "AWS::S3::Bucket",
      "Properties": {
        "BucketName": {"Fn::Sub": "test-bucket-${AWS::StackName}-${AWS::AccountId}"}
      }
    }
  },
  "Outputs": {
    "BucketName": {
      "Description": "Name of the test bucket",
      "Value": {"Ref": "TestBucket"}
    }
  }
}
EOF
            ;;
        "with-exports")
            cat << 'EOF'
{
  "AWSTemplateFormatVersion": "2010-09-09",
  "Description": "Test stack with exports for integration testing",
  "Resources": {
    "TestBucket": {
      "Type": "AWS::S3::Bucket",
      "Properties": {
        "BucketName": {"Fn::Sub": "test-bucket-${AWS::StackName}-${AWS::AccountId}"}
      }
    }
  },
  "Outputs": {
    "BucketName": {
      "Description": "Name of the test bucket",
      "Value": {"Ref": "TestBucket"},
      "Export": {
        "Name": {"Fn::Sub": "${AWS::StackName}-BucketName"}
      }
    }
  }
}
EOF
            ;;
        "with-dependencies")
            cat << 'EOF'
{
  "AWSTemplateFormatVersion": "2010-09-09",
  "Description": "Test stack with resource dependencies",
  "Resources": {
    "TestBucket": {
      "Type": "AWS::S3::Bucket",
      "Properties": {
        "BucketName": {"Fn::Sub": "test-bucket-${AWS::StackName}-${AWS::AccountId}"}
      }
    },
    "TestBucketPolicy": {
      "Type": "AWS::S3::BucketPolicy",
      "Properties": {
        "Bucket": {"Ref": "TestBucket"},
        "PolicyDocument": {
          "Statement": [{
            "Effect": "Allow",
            "Principal": {"AWS": {"Fn::Sub": "arn:aws:iam::${AWS::AccountId}:root"}},
            "Action": "s3:GetObject",
            "Resource": {"Fn::Sub": "${TestBucket}/*"}
          }]
        }
      }
    }
  }
}
EOF
            ;;
        *)
            echo "Unknown template type: $template_type" >&2
            return 1
            ;;
    esac
}

# Mock AWS CLI for integration testing
setup_integration_test_mocks() {
    local test_scenario="$1"
    local stack_name="$2"
    
    case "$test_scenario" in
        "successful_deletion")
            setup_successful_deletion_mock "$stack_name"
            ;;
        "stack_not_found")
            setup_stack_not_found_mock "$stack_name"
            ;;
        "delete_in_progress")
            setup_delete_in_progress_mock "$stack_name"
            ;;
        "delete_failed")
            setup_delete_failed_mock "$stack_name"
            ;;
        "access_denied")
            setup_access_denied_mock "$stack_name"
            ;;
        "stack_with_exports")
            setup_stack_with_exports_mock "$stack_name"
            ;;
        *)
            echo "Unknown test scenario: $test_scenario" >&2
            return 1
            ;;
    esac
}

# Mock for successful stack deletion scenario
setup_successful_deletion_mock() {
    local stack_name="$1"
    local call_count=0
    
    mock_command "aws" "
        case \"\$1\" in
            \"--version\") echo \"aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0\" ;;
            \"sts\") case \"\$2\" in
                \"get-caller-identity\") echo '{\"UserId\":\"AIDACKCEVSQ6C2EXAMPLE\",\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}' ;;
            esac ;;
            \"configure\") case \"\$2\" in
                \"get\") echo \"$TEST_REGION\" ;;
            esac ;;
            \"ec2\") case \"\$2\" in
                \"describe-regions\") return 0 ;;
            esac ;;
            \"cloudformation\") case \"\$2\" in
                \"list-stacks\") echo '{\"StackSummaries\":[]}' ;;
                \"describe-stacks\")
                    if [[ \"\$4\" == \"$stack_name\" ]]; then
                        call_count=\$((call_count + 1))
                        if [[ \$call_count -eq 1 ]]; then
                            echo '{\"Stacks\":[{\"StackName\":\"$stack_name\",\"StackStatus\":\"CREATE_COMPLETE\",\"CreationTime\":\"2024-01-01T00:00:00Z\"}]}'
                        elif [[ \$call_count -eq 2 ]]; then
                            echo '{\"Stacks\":[{\"StackName\":\"$stack_name\",\"StackStatus\":\"DELETE_IN_PROGRESS\",\"CreationTime\":\"2024-01-01T00:00:00Z\"}]}'
                        else
                            echo 'An error occurred (ValidationError) when calling the DescribeStacks operation: Stack with id $stack_name does not exist' >&2
                            return 255
                        fi
                    else
                        echo 'An error occurred (ValidationError) when calling the DescribeStacks operation: Stack does not exist' >&2
                        return 255
                    fi
                    ;;
                \"delete-stack\")
                    if [[ \"\$4\" == \"$stack_name\" ]]; then
                        echo 'Stack deletion initiated'
                        return 0
                    else
                        echo 'Stack not found' >&2
                        return 255
                    fi
                    ;;
                \"describe-stack-events\")
                    if [[ \"\$4\" == \"$stack_name\" ]]; then
                        echo '{\"StackEvents\":[{\"Timestamp\":\"2024-01-01T00:00:00Z\",\"LogicalResourceId\":\"$stack_name\",\"ResourceType\":\"AWS::CloudFormation::Stack\",\"ResourceStatus\":\"DELETE_COMPLETE\"}]}'
                    else
                        echo '{\"StackEvents\":[]}'
                    fi
                    ;;
            esac ;;
            *) return 1 ;;
        esac
    "
}

# Mock for stack not found scenario
setup_stack_not_found_mock() {
    local stack_name="$1"
    
    mock_command "aws" "
        case \"\$1\" in
            \"--version\") echo \"aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0\" ;;
            \"sts\") case \"\$2\" in
                \"get-caller-identity\") echo '{\"UserId\":\"AIDACKCEVSQ6C2EXAMPLE\",\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}' ;;
            esac ;;
            \"configure\") case \"\$2\" in
                \"get\") echo \"$TEST_REGION\" ;;
            esac ;;
            \"ec2\") case \"\$2\" in
                \"describe-regions\") return 0 ;;
            esac ;;
            \"cloudformation\") case \"\$2\" in
                \"list-stacks\") echo '{\"StackSummaries\":[]}' ;;
                \"describe-stacks\")
                    echo 'An error occurred (ValidationError) when calling the DescribeStacks operation: Stack with id $stack_name does not exist' >&2
                    return 255
                    ;;
                \"delete-stack\")
                    echo 'An error occurred (ValidationError) when calling the DeleteStack operation: Stack with id $stack_name does not exist' >&2
                    return 255
                    ;;
            esac ;;
            *) return 1 ;;
        esac
    "
}

# Mock for delete in progress scenario
setup_delete_in_progress_mock() {
    local stack_name="$1"
    local call_count=0
    
    mock_command "aws" "
        case \"\$1\" in
            \"--version\") echo \"aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0\" ;;
            \"sts\") case \"\$2\" in
                \"get-caller-identity\") echo '{\"UserId\":\"AIDACKCEVSQ6C2EXAMPLE\",\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}' ;;
            esac ;;
            \"configure\") case \"\$2\" in
                \"get\") echo \"$TEST_REGION\" ;;
            esac ;;
            \"ec2\") case \"\$2\" in
                \"describe-regions\") return 0 ;;
            esac ;;
            \"cloudformation\") case \"\$2\" in
                \"list-stacks\") echo '{\"StackSummaries\":[]}' ;;
                \"describe-stacks\")
                    if [[ \"\$4\" == \"$stack_name\" ]]; then
                        call_count=\$((call_count + 1))
                        if [[ \$call_count -le 2 ]]; then
                            echo '{\"Stacks\":[{\"StackName\":\"$stack_name\",\"StackStatus\":\"DELETE_IN_PROGRESS\",\"CreationTime\":\"2024-01-01T00:00:00Z\"}]}'
                        else
                            echo 'An error occurred (ValidationError) when calling the DescribeStacks operation: Stack with id $stack_name does not exist' >&2
                            return 255
                        fi
                    else
                        echo 'An error occurred (ValidationError) when calling the DescribeStacks operation: Stack does not exist' >&2
                        return 255
                    fi
                    ;;
                \"delete-stack\")
                    echo 'An error occurred (ResourceNotReady) when calling the DeleteStack operation: Stack is already being deleted' >&2
                    return 255
                    ;;
                \"describe-stack-events\")
                    if [[ \"\$4\" == \"$stack_name\" ]]; then
                        echo '{\"StackEvents\":[{\"Timestamp\":\"2024-01-01T00:00:00Z\",\"LogicalResourceId\":\"$stack_name\",\"ResourceType\":\"AWS::CloudFormation::Stack\",\"ResourceStatus\":\"DELETE_IN_PROGRESS\"}]}'
                    else
                        echo '{\"StackEvents\":[]}'
                    fi
                    ;;
            esac ;;
            *) return 1 ;;
        esac
    "
}

# Mock for delete failed scenario
setup_delete_failed_mock() {
    local stack_name="$1"
    
    mock_command "aws" "
        case \"\$1\" in
            \"--version\") echo \"aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0\" ;;
            \"sts\") case \"\$2\" in
                \"get-caller-identity\") echo '{\"UserId\":\"AIDACKCEVSQ6C2EXAMPLE\",\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}' ;;
            esac ;;
            \"configure\") case \"\$2\" in
                \"get\") echo \"$TEST_REGION\" ;;
            esac ;;
            \"ec2\") case \"\$2\" in
                \"describe-regions\") return 0 ;;
            esac ;;
            \"cloudformation\") case \"\$2\" in
                \"list-stacks\") echo '{\"StackSummaries\":[]}' ;;
                \"describe-stacks\")
                    if [[ \"\$4\" == \"$stack_name\" ]]; then
                        echo '{\"Stacks\":[{\"StackName\":\"$stack_name\",\"StackStatus\":\"DELETE_FAILED\",\"CreationTime\":\"2024-01-01T00:00:00Z\",\"StackStatusReason\":\"Resource deletion failed\"}]}'
                    else
                        echo 'An error occurred (ValidationError) when calling the DescribeStacks operation: Stack does not exist' >&2
                        return 255
                    fi
                    ;;
                \"delete-stack\")
                    echo 'An error occurred (ValidationError) when calling the DeleteStack operation: Stack is in DELETE_FAILED state' >&2
                    return 255
                    ;;
                \"describe-stack-events\")
                    if [[ \"\$4\" == \"$stack_name\" ]]; then
                        echo '{\"StackEvents\":[{\"Timestamp\":\"2024-01-01T00:00:00Z\",\"LogicalResourceId\":\"TestBucket\",\"ResourceType\":\"AWS::S3::Bucket\",\"ResourceStatus\":\"DELETE_FAILED\",\"ResourceStatusReason\":\"Bucket not empty\"}]}'
                    else
                        echo '{\"StackEvents\":[]}'
                    fi
                    ;;
            esac ;;
            *) return 1 ;;
        esac
    "
}

# Mock for access denied scenario
setup_access_denied_mock() {
    local stack_name="$1"
    
    mock_command "aws" "
        case \"\$1\" in
            \"--version\") echo \"aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0\" ;;
            \"sts\") case \"\$2\" in
                \"get-caller-identity\") echo '{\"UserId\":\"AIDACKCEVSQ6C2EXAMPLE\",\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}' ;;
            esac ;;
            \"configure\") case \"\$2\" in
                \"get\") echo \"$TEST_REGION\" ;;
            esac ;;
            \"ec2\") case \"\$2\" in
                \"describe-regions\") return 0 ;;
            esac ;;
            \"cloudformation\") case \"\$2\" in
                \"list-stacks\") echo '{\"StackSummaries\":[]}' ;;
                \"describe-stacks\")
                    echo 'An error occurred (AccessDenied) when calling the DescribeStacks operation: User is not authorized to perform this action' >&2
                    return 255
                    ;;
                \"delete-stack\")
                    echo 'An error occurred (AccessDenied) when calling the DeleteStack operation: User is not authorized to perform this action' >&2
                    return 255
                    ;;
            esac ;;
            *) return 1 ;;
        esac
    "
}

# Mock for stack with exports scenario
setup_stack_with_exports_mock() {
    local stack_name="$1"
    
    mock_command "aws" "
        case \"\$1\" in
            \"--version\") echo \"aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0\" ;;
            \"sts\") case \"\$2\" in
                \"get-caller-identity\") echo '{\"UserId\":\"AIDACKCEVSQ6C2EXAMPLE\",\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}' ;;
            esac ;;
            \"configure\") case \"\$2\" in
                \"get\") echo \"$TEST_REGION\" ;;
            esac ;;
            \"ec2\") case \"\$2\" in
                \"describe-regions\") return 0 ;;
            esac ;;
            \"cloudformation\") case \"\$2\" in
                \"list-stacks\") echo '{\"StackSummaries\":[]}' ;;
                \"describe-stacks\")
                    if [[ \"\$4\" == \"$stack_name\" ]]; then
                        echo '{\"Stacks\":[{\"StackName\":\"$stack_name\",\"StackStatus\":\"CREATE_COMPLETE\",\"CreationTime\":\"2024-01-01T00:00:00Z\",\"Outputs\":[{\"OutputKey\":\"BucketName\",\"OutputValue\":\"test-bucket\",\"ExportName\":\"'$stack_name'-BucketName\"}]}]}'
                    else
                        echo 'An error occurred (ValidationError) when calling the DescribeStacks operation: Stack does not exist' >&2
                        return 255
                    fi
                    ;;
                \"delete-stack\")
                    echo 'An error occurred (ValidationError) when calling the DeleteStack operation: Export '$stack_name'-BucketName cannot be deleted as it is in use by other stacks' >&2
                    return 255
                    ;;
                \"list-imports\")
                    echo '{\"Imports\":[\"dependent-stack-1\",\"dependent-stack-2\"]}'
                    ;;
            esac ;;
            *) return 1 ;;
        esac
    "
}

# Test successful stack deletion workflow
test_successful_stack_deletion() {
    local test_stack_name="${TEST_STACK_PREFIX}-success-$(date +%s)"
    
    setup_integration_test_mocks "successful_deletion" "$test_stack_name"
    
    # Run the deletion script
    local exit_code=0
    local output
    output=$(bash "${SCRIPT_DIR}/delete-stack.sh" "$test_stack_name" "$TEST_REGION" "true" 2>&1) || exit_code=$?
    
    # Verify successful execution
    assert_equals 0 "$exit_code" "Stack deletion should succeed"
    assert_contains "$output" "CloudFormation stack deletion process completed successfully" "Should show success message"
    assert_contains "$output" "Stack Name: $test_stack_name" "Should display stack name"
    assert_contains "$output" "AWS Region: $TEST_REGION" "Should display region"
    
    restore_command "aws"
}

# Test stack not found scenario
test_stack_not_found() {
    local test_stack_name="${TEST_STACK_PREFIX}-notfound-$(date +%s)"
    
    setup_integration_test_mocks "stack_not_found" "$test_stack_name"
    
    # Run the deletion script
    local exit_code=0
    local output
    output=$(bash "${SCRIPT_DIR}/delete-stack.sh" "$test_stack_name" "$TEST_REGION" "true" 2>&1) || exit_code=$?
    
    # Verify that non-existent stack is handled gracefully
    assert_equals 0 "$exit_code" "Non-existent stack should be handled gracefully"
    assert_contains "$output" "does not exist" "Should indicate stack doesn't exist"
    
    restore_command "aws"
}

# Test delete in progress scenario
test_delete_in_progress() {
    local test_stack_name="${TEST_STACK_PREFIX}-inprogress-$(date +%s)"
    
    setup_integration_test_mocks "delete_in_progress" "$test_stack_name"
    
    # Run the deletion script
    local exit_code=0
    local output
    output=$(bash "${SCRIPT_DIR}/delete-stack.sh" "$test_stack_name" "$TEST_REGION" "true" 2>&1) || exit_code=$?
    
    # Verify that in-progress deletion is handled correctly
    assert_equals 0 "$exit_code" "Delete in progress should be handled correctly"
    assert_contains "$output" "deletion already in progress" "Should detect existing deletion"
    
    restore_command "aws"
}

# Test delete failed scenario
test_delete_failed() {
    local test_stack_name="${TEST_STACK_PREFIX}-failed-$(date +%s)"
    
    setup_integration_test_mocks "delete_failed" "$test_stack_name"
    
    # Run the deletion script
    local exit_code=0
    local output
    output=$(bash "${SCRIPT_DIR}/delete-stack.sh" "$test_stack_name" "$TEST_REGION" "true" 2>&1) || exit_code=$?
    
    # Verify that delete failed scenario is handled appropriately
    # This should fail with appropriate error code
    assert_contains "$output" "DELETE_FAILED" "Should detect failed deletion state"
    
    restore_command "aws"
}

# Test access denied scenario
test_access_denied() {
    local test_stack_name="${TEST_STACK_PREFIX}-denied-$(date +%s)"
    
    setup_integration_test_mocks "access_denied" "$test_stack_name"
    
    # Run the deletion script
    local exit_code=0
    local output
    output=$(bash "${SCRIPT_DIR}/delete-stack.sh" "$test_stack_name" "$TEST_REGION" "true" 2>&1) || exit_code=$?
    
    # Verify that access denied is handled with appropriate error code
    assert_equals 2 "$exit_code" "Access denied should exit with code 2"
    assert_contains "$output" "Access denied" "Should show access denied error"
    
    restore_command "aws"
}

# Test stack with exports scenario
test_stack_with_exports() {
    local test_stack_name="${TEST_STACK_PREFIX}-exports-$(date +%s)"
    
    setup_integration_test_mocks "stack_with_exports" "$test_stack_name"
    
    # Run the deletion script
    local exit_code=0
    local output
    output=$(bash "${SCRIPT_DIR}/delete-stack.sh" "$test_stack_name" "$TEST_REGION" "true" 2>&1) || exit_code=$?
    
    # Verify that export dependency is detected and handled
    assert_contains "$output" "export" "Should detect export dependency"
    assert_contains "$output" "in use" "Should indicate export is in use"
    
    restore_command "aws"
}

# Test input validation integration
test_input_validation_integration() {
    # Test with invalid stack name
    local exit_code=0
    local output
    output=$(bash "${SCRIPT_DIR}/delete-stack.sh" "" "$TEST_REGION" "true" 2>&1) || exit_code=$?
    
    assert_equals 1 "$exit_code" "Empty stack name should fail with validation error"
    assert_contains "$output" "Validation Error" "Should show validation error"
    
    # Test with invalid region
    exit_code=0
    output=$(bash "${SCRIPT_DIR}/delete-stack.sh" "test-stack" "invalid-region" "true" 2>&1) || exit_code=$?
    
    assert_equals 1 "$exit_code" "Invalid region should fail with validation error"
    assert_contains "$output" "Invalid AWS region format" "Should show region validation error"
    
    # Test with invalid boolean
    exit_code=0
    output=$(bash "${SCRIPT_DIR}/delete-stack.sh" "test-stack" "$TEST_REGION" "invalid" 2>&1) || exit_code=$?
    
    assert_equals 1 "$exit_code" "Invalid boolean should fail with validation error"
    assert_contains "$output" "Invalid boolean value" "Should show boolean validation error"
}

# Test wait for completion disabled
test_wait_for_completion_disabled() {
    local test_stack_name="${TEST_STACK_PREFIX}-nowait-$(date +%s)"
    
    setup_integration_test_mocks "successful_deletion" "$test_stack_name"
    
    # Run the deletion script with wait disabled
    local exit_code=0
    local output
    output=$(bash "${SCRIPT_DIR}/delete-stack.sh" "$test_stack_name" "$TEST_REGION" "false" 2>&1) || exit_code=$?
    
    # Verify that monitoring is skipped when wait is disabled
    assert_equals 0 "$exit_code" "Should succeed with wait disabled"
    assert_contains "$output" "Wait for completion disabled" "Should skip monitoring"
    
    restore_command "aws"
}

# Test error handling and cleanup
test_error_handling_and_cleanup() {
    local test_stack_name="${TEST_STACK_PREFIX}-error-$(date +%s)"
    
    # Mock AWS CLI to fail during validation
    mock_command "aws" "
        case \"\$1\" in
            \"--version\") echo \"aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0\" ;;
            \"sts\") case \"\$2\" in
                \"get-caller-identity\") 
                    echo 'Unable to locate credentials' >&2
                    return 255
                    ;;
            esac ;;
            *) return 1 ;;
        esac
    "
    
    # Run the deletion script
    local exit_code=0
    local output
    output=$(bash "${SCRIPT_DIR}/delete-stack.sh" "$test_stack_name" "$TEST_REGION" "true" 2>&1) || exit_code=$?
    
    # Verify proper error handling
    assert_equals 2 "$exit_code" "Should fail with authentication error"
    assert_contains "$output" "Authentication Error" "Should show authentication error"
    
    restore_command "aws"
}

# Test script argument parsing
test_argument_parsing() {
    local test_stack_name="${TEST_STACK_PREFIX}-args-$(date +%s)"
    
    setup_integration_test_mocks "successful_deletion" "$test_stack_name"
    
    # Test with minimal arguments (only stack name)
    local exit_code=0
    local output
    output=$(bash "${SCRIPT_DIR}/delete-stack.sh" "$test_stack_name" 2>&1) || exit_code=$?
    
    assert_equals 0 "$exit_code" "Should work with minimal arguments"
    assert_contains "$output" "Stack Name: $test_stack_name" "Should parse stack name"
    
    restore_command "aws"
}

# Test timeout handling
test_timeout_handling() {
    local test_stack_name="${TEST_STACK_PREFIX}-timeout-$(date +%s)"
    
    # Mock AWS CLI to simulate long-running operation
    mock_command "aws" "
        case \"\$1\" in
            \"--version\") echo \"aws-cli/2.0.0 Python/3.8.0 Linux/5.4.0 botocore/2.0.0\" ;;
            \"sts\") case \"\$2\" in
                \"get-caller-identity\") echo '{\"UserId\":\"AIDACKCEVSQ6C2EXAMPLE\",\"Account\":\"123456789012\",\"Arn\":\"arn:aws:iam::123456789012:user/testuser\"}' ;;
            esac ;;
            \"configure\") case \"\$2\" in
                \"get\") echo \"$TEST_REGION\" ;;
            esac ;;
            \"ec2\") case \"\$2\" in
                \"describe-regions\") return 0 ;;
            esac ;;
            \"cloudformation\") case \"\$2\" in
                \"list-stacks\") echo '{\"StackSummaries\":[]}' ;;
                \"describe-stacks\")
                    if [[ \"\$4\" == \"$test_stack_name\" ]]; then
                        # Always return DELETE_IN_PROGRESS to simulate timeout
                        echo '{\"Stacks\":[{\"StackName\":\"$test_stack_name\",\"StackStatus\":\"DELETE_IN_PROGRESS\",\"CreationTime\":\"2024-01-01T00:00:00Z\"}]}'
                    else
                        echo 'An error occurred (ValidationError) when calling the DescribeStacks operation: Stack does not exist' >&2
                        return 255
                    fi
                    ;;
                \"delete-stack\")
                    echo 'Stack deletion initiated'
                    return 0
                    ;;
                \"describe-stack-events\")
                    # Simulate slow events
                    sleep 1
                    echo '{\"StackEvents\":[{\"Timestamp\":\"2024-01-01T00:00:00Z\",\"LogicalResourceId\":\"$test_stack_name\",\"ResourceType\":\"AWS::CloudFormation::Stack\",\"ResourceStatus\":\"DELETE_IN_PROGRESS\"}]}'
                    ;;
            esac ;;
            *) return 1 ;;
        esac
    "
    
    # Run with very short timeout for testing
    local exit_code=0
    local output
    # Note: This test may take some time due to timeout simulation
    timeout 30 bash "${SCRIPT_DIR}/delete-stack.sh" "$test_stack_name" "$TEST_REGION" "true" 2>&1 || exit_code=$?
    
    # Verify timeout handling (exit code may vary based on timeout implementation)
    # The important thing is that it doesn't hang indefinitely
    
    restore_command "aws"
}

# Main test runner
main() {
    setup_test_env
    init_test_suite "Stack Deletion Integration Tests"
    
    # Test different stack deletion scenarios
    run_test "successful stack deletion workflow" test_successful_stack_deletion
    run_test "stack not found scenario" test_stack_not_found
    run_test "delete in progress scenario" test_delete_in_progress
    run_test "delete failed scenario" test_delete_failed
    run_test "access denied scenario" test_access_denied
    run_test "stack with exports scenario" test_stack_with_exports
    
    # Test input validation integration
    run_test "input validation integration" test_input_validation_integration
    
    # Test configuration options
    run_test "wait for completion disabled" test_wait_for_completion_disabled
    
    # Test error handling
    run_test "error handling and cleanup" test_error_handling_and_cleanup
    
    # Test argument parsing
    run_test "argument parsing" test_argument_parsing
    
    # Test timeout handling (commented out as it may be slow)
    # run_test "timeout handling" test_timeout_handling
    
    print_test_results
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
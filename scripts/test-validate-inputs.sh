#!/bin/bash

# Unit tests for input validation functions in validate-inputs.sh
# Tests stack name validation, AWS region validation, and boolean parameter validation

set -euo pipefail

# Get script directory and source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-framework.sh"
source "${SCRIPT_DIR}/utils.sh"
source "${SCRIPT_DIR}/validate-inputs.sh"

# Test stack name validation - valid cases
test_validate_stack_name_valid() {
    local result
    
    # Test basic valid stack name
    result=$(validate_stack_name "my-stack")
    assert_equals "my-stack" "$result" "Should accept basic valid stack name"
    
    # Test stack name with numbers
    result=$(validate_stack_name "stack123")
    assert_equals "stack123" "$result" "Should accept stack name with numbers"
    
    # Test stack name with hyphens
    result=$(validate_stack_name "my-test-stack")
    assert_equals "my-test-stack" "$result" "Should accept stack name with hyphens"
    
    # Test stack name starting with uppercase
    result=$(validate_stack_name "MyStack")
    assert_equals "MyStack" "$result" "Should accept stack name starting with uppercase"
    
    # Test mixed case stack name
    result=$(validate_stack_name "MyTestStack123")
    assert_equals "MyTestStack123" "$result" "Should accept mixed case stack name"
    
    # Test stack name with trimmed whitespace
    result=$(validate_stack_name "  my-stack  ")
    assert_equals "my-stack" "$result" "Should trim whitespace from stack name"
}

# Test stack name validation - invalid cases
test_validate_stack_name_invalid() {
    local exit_code
    
    # Test empty stack name
    exit_code=0
    (validate_stack_name "") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject empty stack name"
    
    # Test whitespace-only stack name
    exit_code=0
    (validate_stack_name "   ") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject whitespace-only stack name"
    
    # Test stack name starting with number
    exit_code=0
    (validate_stack_name "123stack") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject stack name starting with number"
    
    # Test stack name starting with hyphen
    exit_code=0
    (validate_stack_name "-mystack") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject stack name starting with hyphen"
    
    # Test stack name ending with hyphen
    exit_code=0
    (validate_stack_name "mystack-") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject stack name ending with hyphen"
    
    # Test stack name with consecutive hyphens
    exit_code=0
    (validate_stack_name "my--stack") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject stack name with consecutive hyphens"
    
    # Test stack name with invalid characters
    exit_code=0
    (validate_stack_name "my_stack") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject stack name with underscores"
    
    exit_code=0
    (validate_stack_name "my.stack") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject stack name with dots"
    
    exit_code=0
    (validate_stack_name "my stack") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject stack name with spaces"
    
    exit_code=0
    (validate_stack_name "my@stack") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject stack name with special characters"
}

# Test stack name length validation
test_validate_stack_name_length() {
    local exit_code
    local long_name
    
    # Test maximum length (255 characters)
    long_name=$(printf 'a%.0s' {1..255})
    local result
    result=$(validate_stack_name "$long_name")
    assert_equals "$long_name" "$result" "Should accept 255 character stack name"
    
    # Test over maximum length (256 characters)
    long_name=$(printf 'a%.0s' {1..256})
    exit_code=0
    (validate_stack_name "$long_name") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject stack name over 255 characters"
}

# Test AWS region validation - valid cases
test_validate_aws_region_valid() {
    local result
    
    # Test common US regions
    result=$(validate_aws_region "us-east-1")
    assert_equals "us-east-1" "$result" "Should accept us-east-1"
    
    result=$(validate_aws_region "us-west-2")
    assert_equals "us-west-2" "$result" "Should accept us-west-2"
    
    # Test EU regions
    result=$(validate_aws_region "eu-west-1")
    assert_equals "eu-west-1" "$result" "Should accept eu-west-1"
    
    result=$(validate_aws_region "eu-central-1")
    assert_equals "eu-central-1" "$result" "Should accept eu-central-1"
    
    # Test Asia Pacific regions
    result=$(validate_aws_region "ap-southeast-1")
    assert_equals "ap-southeast-1" "$result" "Should accept ap-southeast-1"
    
    result=$(validate_aws_region "ap-northeast-2")
    assert_equals "ap-northeast-2" "$result" "Should accept ap-northeast-2"
    
    # Test other regions
    result=$(validate_aws_region "ca-central-1")
    assert_equals "ca-central-1" "$result" "Should accept ca-central-1"
    
    result=$(validate_aws_region "sa-east-1")
    assert_equals "sa-east-1" "$result" "Should accept sa-east-1"
    
    # Test region with trimmed whitespace
    result=$(validate_aws_region "  us-east-1  ")
    assert_equals "us-east-1" "$result" "Should trim whitespace from region"
}

# Test AWS region validation - empty region (should be allowed)
test_validate_aws_region_empty() {
    local exit_code=0
    validate_aws_region "" || exit_code=$?
    assert_equals 0 "$exit_code" "Should allow empty region (uses default)"
}

# Test AWS region validation - invalid cases
test_validate_aws_region_invalid() {
    local exit_code
    
    # Test invalid format
    exit_code=0
    (validate_aws_region "invalid-region") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject invalid region format"
    
    exit_code=0
    (validate_aws_region "us-east") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject region without number"
    
    exit_code=0
    (validate_aws_region "us-east-1-extra") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject region with extra parts"
    
    # Test non-existent regions
    exit_code=0
    (validate_aws_region "xx-fake-1") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject non-existent region"
    
    exit_code=0
    (validate_aws_region "us-fake-1") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject fake US region"
    
    # Test invalid characters
    exit_code=0
    (validate_aws_region "us_east_1") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject region with underscores"
    
    exit_code=0
    (validate_aws_region "US-EAST-1") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject uppercase region"
}

# Test boolean validation - valid cases
test_validate_boolean_valid() {
    local result
    
    # Test true values
    result=$(validate_boolean "test-param" "true")
    assert_equals "true" "$result" "Should accept 'true'"
    
    result=$(validate_boolean "test-param" "TRUE")
    assert_equals "true" "$result" "Should accept 'TRUE'"
    
    result=$(validate_boolean "test-param" "yes")
    assert_equals "true" "$result" "Should accept 'yes'"
    
    result=$(validate_boolean "test-param" "YES")
    assert_equals "true" "$result" "Should accept 'YES'"
    
    result=$(validate_boolean "test-param" "1")
    assert_equals "true" "$result" "Should accept '1'"
    
    result=$(validate_boolean "test-param" "on")
    assert_equals "true" "$result" "Should accept 'on'"
    
    # Test false values
    result=$(validate_boolean "test-param" "false")
    assert_equals "false" "$result" "Should accept 'false'"
    
    result=$(validate_boolean "test-param" "FALSE")
    assert_equals "false" "$result" "Should accept 'FALSE'"
    
    result=$(validate_boolean "test-param" "no")
    assert_equals "false" "$result" "Should accept 'no'"
    
    result=$(validate_boolean "test-param" "NO")
    assert_equals "false" "$result" "Should accept 'NO'"
    
    result=$(validate_boolean "test-param" "0")
    assert_equals "false" "$result" "Should accept '0'"
    
    result=$(validate_boolean "test-param" "off")
    assert_equals "false" "$result" "Should accept 'off'"
    
    # Test empty value (should default to false)
    result=$(validate_boolean "test-param" "")
    assert_equals "false" "$result" "Should default to 'false' for empty value"
    
    # Test with whitespace
    result=$(validate_boolean "test-param" "  true  ")
    assert_equals "true" "$result" "Should trim whitespace and accept 'true'"
}

# Test boolean validation - invalid cases
test_validate_boolean_invalid() {
    local exit_code
    
    # Test invalid boolean values
    exit_code=0
    (validate_boolean "test-param" "invalid") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject invalid boolean value"
    
    exit_code=0
    (validate_boolean "test-param" "maybe") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject 'maybe'"
    
    exit_code=0
    (validate_boolean "test-param" "2") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject '2'"
    
    exit_code=0
    (validate_boolean "test-param" "enable") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should reject 'enable'"
}

# Test validate_all_inputs function
test_validate_all_inputs_valid() {
    local output
    output=$(validate_all_inputs "my-stack" "us-east-1" "true")
    
    assert_contains "$output" "STACK_NAME=my-stack" "Should output validated stack name"
    assert_contains "$output" "AWS_REGION=us-east-1" "Should output validated region"
    assert_contains "$output" "WAIT_FOR_COMPLETION=true" "Should output validated wait flag"
}

test_validate_all_inputs_minimal() {
    local output
    output=$(validate_all_inputs "test-stack")
    
    assert_contains "$output" "STACK_NAME=test-stack" "Should output validated stack name"
    assert_contains "$output" "WAIT_FOR_COMPLETION=false" "Should default wait flag to false"
    # Should not contain AWS_REGION line when not provided
}

test_validate_all_inputs_invalid_stack() {
    local exit_code=0
    (validate_all_inputs "") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should fail validation with empty stack name"
}

test_validate_all_inputs_invalid_region() {
    local exit_code=0
    (validate_all_inputs "my-stack" "invalid-region") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should fail validation with invalid region"
}

test_validate_all_inputs_invalid_boolean() {
    local exit_code=0
    (validate_all_inputs "my-stack" "us-east-1" "invalid") 2>/dev/null || exit_code=$?
    assert_equals 1 "$exit_code" "Should fail validation with invalid boolean"
}

# Test show_validation_help function
test_show_validation_help() {
    local output
    output=$(show_validation_help)
    
    assert_contains "$output" "Stack Name Requirements" "Should contain stack name help"
    assert_contains "$output" "AWS Region Format" "Should contain region help"
    assert_contains "$output" "Wait for Completion" "Should contain boolean help"
    assert_contains "$output" "Examples:" "Should contain examples"
}

# Test edge cases and special scenarios
test_stack_name_edge_cases() {
    local result
    
    # Test single character (valid)
    result=$(validate_stack_name "a")
    assert_equals "a" "$result" "Should accept single character stack name"
    
    # Test very long valid name (254 characters)
    local long_name="a$(printf 'b%.0s' {1..253})"
    result=$(validate_stack_name "$long_name")
    assert_equals "$long_name" "$result" "Should accept 254 character stack name"
}

test_region_edge_cases() {
    local result
    
    # Test shortest valid region format
    result=$(validate_aws_region "us-east-1")
    assert_equals "us-east-1" "$result" "Should accept shortest valid region"
    
    # Test longer region names
    result=$(validate_aws_region "ap-southeast-2")
    assert_equals "ap-southeast-2" "$result" "Should accept longer region names"
}

test_boolean_edge_cases() {
    local result
    
    # Test mixed case
    result=$(validate_boolean "test" "True")
    assert_equals "true" "$result" "Should handle mixed case 'True'"
    
    result=$(validate_boolean "test" "False")
    assert_equals "false" "$result" "Should handle mixed case 'False'"
    
    # Test with extra whitespace
    result=$(validate_boolean "test" "   yes   ")
    assert_equals "true" "$result" "Should handle extra whitespace"
}

# Main test runner
main() {
    setup_test_env
    init_test_suite "Input Validation Tests"
    
    # Test stack name validation
    run_test "validate_stack_name accepts valid names" test_validate_stack_name_valid
    run_test "validate_stack_name rejects invalid names" test_validate_stack_name_invalid
    run_test "validate_stack_name enforces length limits" test_validate_stack_name_length
    
    # Test AWS region validation
    run_test "validate_aws_region accepts valid regions" test_validate_aws_region_valid
    run_test "validate_aws_region allows empty region" test_validate_aws_region_empty
    run_test "validate_aws_region rejects invalid regions" test_validate_aws_region_invalid
    
    # Test boolean validation
    run_test "validate_boolean accepts valid boolean values" test_validate_boolean_valid
    run_test "validate_boolean rejects invalid boolean values" test_validate_boolean_invalid
    
    # Test validate_all_inputs function
    run_test "validate_all_inputs works with valid inputs" test_validate_all_inputs_valid
    run_test "validate_all_inputs works with minimal inputs" test_validate_all_inputs_minimal
    run_test "validate_all_inputs fails with invalid stack name" test_validate_all_inputs_invalid_stack
    run_test "validate_all_inputs fails with invalid region" test_validate_all_inputs_invalid_region
    run_test "validate_all_inputs fails with invalid boolean" test_validate_all_inputs_invalid_boolean
    
    # Test help function
    run_test "show_validation_help displays help information" test_show_validation_help
    
    # Test edge cases
    run_test "stack name edge cases work correctly" test_stack_name_edge_cases
    run_test "region edge cases work correctly" test_region_edge_cases
    run_test "boolean edge cases work correctly" test_boolean_edge_cases
    
    print_test_results
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
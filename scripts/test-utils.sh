#!/bin/bash

# Unit tests for utility functions in utils.sh
# Tests logging, error handling, formatting, and AWS operation utilities

set -euo pipefail

# Get script directory and source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/test-framework.sh"
source "${SCRIPT_DIR}/utils.sh"

# Test logging functions
test_log_info() {
    local output
    output=$(log_info "Test message" 2>&1)
    
    assert_contains "$output" "Test message" "log_info should contain the message"
    assert_contains "$output" "[INFO]" "log_info should contain INFO prefix"
    assert_contains "$output" "::notice::" "log_info should contain GitHub Actions notice"
}

test_log_warning() {
    local output
    output=$(log_warning "Warning message" 2>&1)
    
    assert_contains "$output" "Warning message" "log_warning should contain the message"
    assert_contains "$output" "[WARN]" "log_warning should contain WARN prefix"
    assert_contains "$output" "::warning::" "log_warning should contain GitHub Actions warning"
}

test_log_error() {
    local output
    output=$(log_error "Error message" 2>&1)
    
    assert_contains "$output" "Error message" "log_error should contain the message"
    assert_contains "$output" "[ERROR]" "log_error should contain ERROR prefix"
    assert_contains "$output" "::error::" "log_error should contain GitHub Actions error"
}

test_log_success() {
    local output
    output=$(log_success "Success message" 2>&1)
    
    assert_contains "$output" "Success message" "log_success should contain the message"
    assert_contains "$output" "[SUCCESS]" "log_success should contain SUCCESS prefix"
    assert_contains "$output" "::notice::" "log_success should contain GitHub Actions notice"
}

test_log_debug_disabled() {
    unset DEBUG 2>/dev/null || true
    local output
    output=$(log_debug "Debug message" 2>&1)
    
    # Debug should be empty when DEBUG is not set to true
    assert_empty "$output" "log_debug should be empty when DEBUG is not enabled"
}

test_log_debug_enabled() {
    export DEBUG=true
    local output
    output=$(log_debug "Debug message" 2>&1)
    
    assert_contains "$output" "Debug message" "log_debug should contain the message when DEBUG=true"
    assert_contains "$output" "[DEBUG]" "log_debug should contain DEBUG prefix"
    assert_contains "$output" "::debug::" "log_debug should contain GitHub Actions debug"
    
    unset DEBUG
}

# Test timestamp functions
test_get_timestamp() {
    local timestamp
    timestamp=$(get_timestamp)
    
    assert_not_empty "$timestamp" "get_timestamp should return a non-empty value"
    assert_matches "$timestamp" "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} UTC" "Timestamp should match expected format"
}

test_get_iso_timestamp() {
    local timestamp
    timestamp=$(get_iso_timestamp)
    
    assert_not_empty "$timestamp" "get_iso_timestamp should return a non-empty value"
    assert_matches "$timestamp" "[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z" "ISO timestamp should match expected format"
}

test_format_duration() {
    local result
    
    # Test seconds only
    result=$(format_duration 0 30)
    assert_equals "30s" "$result" "Duration of 30 seconds should format correctly"
    
    # Test minutes and seconds
    result=$(format_duration 0 90)
    assert_equals "1m 30s" "$result" "Duration of 90 seconds should format as 1m 30s"
    
    # Test hours, minutes, and seconds
    result=$(format_duration 0 3661)
    assert_equals "1h 1m 1s" "$result" "Duration of 3661 seconds should format as 1h 1m 1s"
    
    # Test zero duration
    result=$(format_duration 100 100)
    assert_equals "0s" "$result" "Zero duration should format as 0s"
}

# Test string utility functions
test_trim() {
    local result
    
    # Test leading whitespace
    result=$(trim "  hello")
    assert_equals "hello" "$result" "Should trim leading whitespace"
    
    # Test trailing whitespace
    result=$(trim "hello  ")
    assert_equals "hello" "$result" "Should trim trailing whitespace"
    
    # Test both leading and trailing whitespace
    result=$(trim "  hello  ")
    assert_equals "hello" "$result" "Should trim both leading and trailing whitespace"
    
    # Test no whitespace
    result=$(trim "hello")
    assert_equals "hello" "$result" "Should not modify string without whitespace"
    
    # Test only whitespace
    result=$(trim "   ")
    assert_empty "$result" "Should return empty string for whitespace-only input"
}

test_to_upper() {
    local result
    
    result=$(to_upper "hello")
    assert_equals "HELLO" "$result" "Should convert to uppercase"
    
    result=$(to_upper "Hello World")
    assert_equals "HELLO WORLD" "$result" "Should convert mixed case to uppercase"
    
    result=$(to_upper "ALREADY_UPPER")
    assert_equals "ALREADY_UPPER" "$result" "Should not modify already uppercase string"
}

test_to_lower() {
    local result
    
    result=$(to_lower "HELLO")
    assert_equals "hello" "$result" "Should convert to lowercase"
    
    result=$(to_lower "Hello World")
    assert_equals "hello world" "$result" "Should convert mixed case to lowercase"
    
    result=$(to_lower "already_lower")
    assert_equals "already_lower" "$result" "Should not modify already lowercase string"
}

test_is_set() {
    local test_var="value"
    local empty_var=""
    
    # Test with set variable
    if is_set "$test_var"; then
        pass_test
    else
        fail_test "is_set should return true for set variable"
        return 1
    fi
    
    # Test with empty variable
    if ! is_set "$empty_var"; then
        pass_test
    else
        fail_test "is_set should return false for empty variable"
        return 1
    fi
    
    # Test with unset variable
    if ! is_set "${unset_var:-}"; then
        pass_test
    else
        fail_test "is_set should return false for unset variable"
        return 1
    fi
}

test_command_exists() {
    # Test with existing command
    if command_exists "bash"; then
        pass_test
    else
        fail_test "command_exists should return true for bash"
        return 1
    fi
    
    # Test with non-existing command
    if ! command_exists "nonexistent_command_12345"; then
        pass_test
    else
        fail_test "command_exists should return false for non-existent command"
        return 1
    fi
}

# Test error classification functions
test_classify_aws_error() {
    local result
    
    # Test throttling errors
    result=$(classify_aws_error "Throttling: Rate exceeded")
    assert_equals "THROTTLING" "$result" "Should classify throttling error correctly"
    
    result=$(classify_aws_error "RequestLimitExceeded: Too many requests")
    assert_equals "THROTTLING" "$result" "Should classify rate limit error as throttling"
    
    # Test service unavailable errors
    result=$(classify_aws_error "Service unavailable")
    assert_equals "SERVICE_UNAVAILABLE" "$result" "Should classify service unavailable error"
    
    result=$(classify_aws_error "Internal server error")
    assert_equals "SERVICE_UNAVAILABLE" "$result" "Should classify internal server error as service unavailable"
    
    # Test timeout errors
    result=$(classify_aws_error "Connection timeout")
    assert_equals "TIMEOUT" "$result" "Should classify timeout error"
    
    result=$(classify_aws_error "Operation timed out")
    assert_equals "TIMEOUT" "$result" "Should classify timed out error"
    
    # Test network errors
    result=$(classify_aws_error "Connection refused")
    assert_equals "NETWORK" "$result" "Should classify connection error as network"
    
    result=$(classify_aws_error "DNS resolution failed")
    assert_equals "NETWORK" "$result" "Should classify DNS error as network"
    
    # Test transient errors
    result=$(classify_aws_error "Temporary failure")
    assert_equals "TRANSIENT" "$result" "Should classify temporary error as transient"
    
    # Test non-retryable errors
    result=$(classify_aws_error "ValidationError: Invalid parameter")
    assert_equals "NON_RETRYABLE" "$result" "Should classify validation error as non-retryable"
}

test_format_aws_error_message() {
    local result
    
    # Test CloudFormation validation error
    result=$(format_aws_error_message "An error occurred (ValidationError) when calling the DescribeStacks operation: Stack with id test-stack does not exist")
    assert_contains "$result" "does not exist" "Should extract meaningful error from CloudFormation validation error"
    
    # Test access denied error
    result=$(format_aws_error_message "An error occurred (AccessDenied) when calling the DeleteStack operation: User is not authorized")
    assert_equals "Access denied - insufficient permissions for this operation" "$result" "Should format access denied error"
    
    # Test generic error
    result=$(format_aws_error_message "Some generic error message")
    assert_equals "Some generic error message" "$result" "Should return original message for generic errors"
}

# Test error handling functions
test_handle_validation_error() {
    # This function should exit with code 1, so we test it in a subshell
    local exit_code=0
    (handle_validation_error "Test validation error") 2>/dev/null || exit_code=$?
    
    assert_equals 1 "$exit_code" "handle_validation_error should exit with code 1"
}

test_handle_auth_error() {
    # This function should exit with code 2, so we test it in a subshell
    local exit_code=0
    (handle_auth_error "Test auth error") 2>/dev/null || exit_code=$?
    
    assert_equals 2 "$exit_code" "handle_auth_error should exit with code 2"
}

test_handle_stack_error() {
    # This function should exit with code 3, so we test it in a subshell
    local exit_code=0
    (handle_stack_error "Test stack error") 2>/dev/null || exit_code=$?
    
    assert_equals 3 "$exit_code" "handle_stack_error should exit with code 3"
}

test_handle_deletion_error() {
    # This function should exit with code 4, so we test it in a subshell
    local exit_code=0
    (handle_deletion_error "Test deletion error") 2>/dev/null || exit_code=$?
    
    assert_equals 4 "$exit_code" "handle_deletion_error should exit with code 4"
}

# Test CloudFormation error handling
test_handle_cloudformation_error() {
    local exit_code
    
    # Test stack does not exist (should return 0)
    exit_code=0
    handle_cloudformation_error "Stack does not exist" "test-stack" "test operation" || exit_code=$?
    assert_equals 0 "$exit_code" "Should return 0 for 'does not exist' error"
    
    # Test delete in progress (should return 0)
    exit_code=0
    handle_cloudformation_error "DELETE_IN_PROGRESS" "test-stack" "test operation" || exit_code=$?
    assert_equals 0 "$exit_code" "Should return 0 for DELETE_IN_PROGRESS"
    
    # Test access denied (should return 2)
    exit_code=0
    handle_cloudformation_error "Access denied" "test-stack" "test operation" || exit_code=$?
    assert_equals 2 "$exit_code" "Should return 2 for access denied error"
    
    # Test throttling (should return 3)
    exit_code=0
    handle_cloudformation_error "Throttling" "test-stack" "test operation" || exit_code=$?
    assert_equals 3 "$exit_code" "Should return 3 for throttling error"
}

# Test print functions
test_print_header() {
    local output
    output=$(print_header "Test Header")
    
    assert_contains "$output" "Test Header" "Should contain the header text"
    assert_contains "$output" "========" "Should contain header border"
}

test_print_section() {
    local output
    output=$(print_section "Test Section")
    
    assert_contains "$output" "Test Section" "Should contain the section text"
    assert_contains "$output" "----" "Should contain section border"
}

# Main test runner
main() {
    setup_test_env
    init_test_suite "Utils Functions Tests"
    
    # Test logging functions
    run_test "log_info formats message correctly" test_log_info
    run_test "log_warning formats message correctly" test_log_warning
    run_test "log_error formats message correctly" test_log_error
    run_test "log_success formats message correctly" test_log_success
    run_test "log_debug disabled by default" test_log_debug_disabled
    run_test "log_debug enabled with DEBUG=true" test_log_debug_enabled
    
    # Test timestamp functions
    run_test "get_timestamp returns valid timestamp" test_get_timestamp
    run_test "get_iso_timestamp returns valid ISO timestamp" test_get_iso_timestamp
    run_test "format_duration formats time correctly" test_format_duration
    
    # Test string utilities
    run_test "trim removes whitespace correctly" test_trim
    run_test "to_upper converts to uppercase" test_to_upper
    run_test "to_lower converts to lowercase" test_to_lower
    run_test "is_set checks variable state correctly" test_is_set
    run_test "command_exists checks command availability" test_command_exists
    
    # Test error classification
    run_test "classify_aws_error categorizes errors correctly" test_classify_aws_error
    run_test "format_aws_error_message formats errors" test_format_aws_error_message
    
    # Test error handling functions
    run_test "handle_validation_error exits with code 1" test_handle_validation_error
    run_test "handle_auth_error exits with code 2" test_handle_auth_error
    run_test "handle_stack_error exits with code 3" test_handle_stack_error
    run_test "handle_deletion_error exits with code 4" test_handle_deletion_error
    
    # Test CloudFormation error handling
    run_test "handle_cloudformation_error handles different error types" test_handle_cloudformation_error
    
    # Test print functions
    run_test "print_header formats header correctly" test_print_header
    run_test "print_section formats section correctly" test_print_section
    
    print_test_results
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
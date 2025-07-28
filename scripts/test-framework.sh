#!/bin/bash

# Simple test framework for bash scripts
# Provides assertion functions and test result reporting

set -euo pipefail

# Test framework variables
TEST_COUNT=0
PASSED_COUNT=0
FAILED_COUNT=0
CURRENT_TEST=""
TEST_OUTPUT=""

# Colors for output (only define if not already defined)
if [[ -z "${RED:-}" ]]; then
    readonly RED='\033[0;31m'
    readonly GREEN='\033[0;32m'
    readonly YELLOW='\033[1;33m'
    readonly BLUE='\033[0;34m'
    readonly NC='\033[0m' # No Color
fi

# Initialize test suite
init_test_suite() {
    local suite_name="$1"
    echo -e "${BLUE}=== Running Test Suite: $suite_name ===${NC}"
    TEST_COUNT=0
    PASSED_COUNT=0
    FAILED_COUNT=0
}

# Start a test case
start_test() {
    local test_name="$1"
    CURRENT_TEST="$test_name"
    TEST_COUNT=$((TEST_COUNT + 1))
    echo -n "  Test $TEST_COUNT: $test_name ... "
}

# Mark test as passed
pass_test() {
    PASSED_COUNT=$((PASSED_COUNT + 1))
    echo -e "${GREEN}PASS${NC}"
}

# Mark test as failed
fail_test() {
    local message="${1:-}"
    FAILED_COUNT=$((FAILED_COUNT + 1))
    echo -e "${RED}FAIL${NC}"
    if [[ -n "$message" ]]; then
        echo -e "    ${RED}Error: $message${NC}"
    fi
}

# Assert that two values are equal
assert_equals() {
    local expected="$1"
    local actual="$2"
    local message="${3:-Values are not equal}"
    
    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        fail_test "$message. Expected: '$expected', Got: '$actual'"
        return 1
    fi
}

# Assert that a value is not empty
assert_not_empty() {
    local value="$1"
    local message="${2:-Value is empty}"
    
    if [[ -n "$value" ]]; then
        return 0
    else
        fail_test "$message"
        return 1
    fi
}

# Assert that a value is empty
assert_empty() {
    local value="$1"
    local message="${2:-Value is not empty}"
    
    if [[ -z "$value" ]]; then
        return 0
    else
        fail_test "$message. Got: '$value'"
        return 1
    fi
}

# Assert that a command succeeds (exit code 0)
assert_success() {
    local command="$1"
    local message="${2:-Command failed}"
    
    if eval "$command" >/dev/null 2>&1; then
        return 0
    else
        fail_test "$message. Command: $command"
        return 1
    fi
}

# Assert that a command fails (non-zero exit code)
assert_failure() {
    local command="$1"
    local message="${2:-Command succeeded unexpectedly}"
    
    if ! eval "$command" >/dev/null 2>&1; then
        return 0
    else
        fail_test "$message. Command: $command"
        return 1
    fi
}

# Assert that a string contains a substring
assert_contains() {
    local haystack="$1"
    local needle="$2"
    local message="${3:-String does not contain expected substring}"
    
    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        fail_test "$message. String: '$haystack', Expected to contain: '$needle'"
        return 1
    fi
}

# Assert that a string matches a regex pattern
assert_matches() {
    local string="$1"
    local pattern="$2"
    local message="${3:-String does not match pattern}"
    
    if [[ "$string" =~ $pattern ]]; then
        return 0
    else
        fail_test "$message. String: '$string', Pattern: '$pattern'"
        return 1
    fi
}

# Assert that exit code matches expected value
assert_exit_code() {
    local command="$1"
    local expected_code="$2"
    local message="${3:-Exit code does not match}"
    
    local actual_code=0
    eval "$command" >/dev/null 2>&1 || actual_code=$?
    
    if [[ $actual_code -eq $expected_code ]]; then
        return 0
    else
        fail_test "$message. Expected exit code: $expected_code, Got: $actual_code"
        return 1
    fi
}

# Run a test and handle pass/fail automatically
run_test() {
    local test_name="$1"
    local test_function="$2"
    
    start_test "$test_name"
    
    # Capture output and exit code
    local output
    local exit_code=0
    output=$("$test_function" 2>&1) || exit_code=$?
    
    if [[ $exit_code -eq 0 ]]; then
        pass_test
    else
        fail_test "$output"
    fi
}

# Mock function to override commands during testing
mock_command() {
    local command_name="$1"
    local mock_behavior="$2"
    
    # Create a temporary function that overrides the command
    eval "$command_name() { $mock_behavior; }"
    export -f "$command_name"
}

# Restore original command after mocking
restore_command() {
    local command_name="$1"
    unset -f "$command_name" 2>/dev/null || true
}

# Set up test environment
setup_test_env() {
    # Create temporary directory for test files
    export TEST_TEMP_DIR
    TEST_TEMP_DIR=$(mktemp -d)
    
    # Set up test-specific environment variables
    export TEST_MODE=true
    export DEBUG=false
    
    # Disable GitHub Actions output during tests
    unset GITHUB_ACTIONS 2>/dev/null || true
}

# Clean up test environment
cleanup_test_env() {
    # Remove temporary directory
    if [[ -n "${TEST_TEMP_DIR:-}" ]] && [[ -d "$TEST_TEMP_DIR" ]]; then
        rm -rf "$TEST_TEMP_DIR"
    fi
    
    # Restore environment
    unset TEST_MODE 2>/dev/null || true
    unset TEST_TEMP_DIR 2>/dev/null || true
}

# Print test results summary
print_test_results() {
    echo ""
    echo -e "${BLUE}=== Test Results ===${NC}"
    echo "  Total tests: $TEST_COUNT"
    echo -e "  ${GREEN}Passed: $PASSED_COUNT${NC}"
    
    if [[ $FAILED_COUNT -gt 0 ]]; then
        echo -e "  ${RED}Failed: $FAILED_COUNT${NC}"
        echo ""
        echo -e "${RED}Some tests failed!${NC}"
        return 1
    else
        echo -e "  ${GREEN}All tests passed!${NC}"
        return 0
    fi
}

# Trap to ensure cleanup on exit
trap cleanup_test_env EXIT

# Export test framework functions
export -f init_test_suite start_test pass_test fail_test
export -f assert_equals assert_not_empty assert_empty assert_success assert_failure
export -f assert_contains assert_matches assert_exit_code run_test
export -f mock_command restore_command setup_test_env cleanup_test_env print_test_results
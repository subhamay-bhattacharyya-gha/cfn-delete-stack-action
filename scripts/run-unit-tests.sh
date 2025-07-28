#!/bin/bash

# Test runner for all unit tests
# Executes all unit test suites and provides consolidated results

set -euo pipefail

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source test framework for result tracking
source "${SCRIPT_DIR}/test-framework.sh"

# Test suite tracking
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
SUITE_RESULTS=()

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Function to run a test suite
run_test_suite() {
    local test_script="$1"
    local suite_name="$2"
    
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}Running Test Suite: $suite_name${NC}"
    echo -e "${BLUE}======================================${NC}"
    
    TOTAL_SUITES=$((TOTAL_SUITES + 1))
    
    local exit_code=0
    local output
    
    # Run the test suite and capture output
    if output=$("$test_script" 2>&1); then
        echo "$output"
        PASSED_SUITES=$((PASSED_SUITES + 1))
        SUITE_RESULTS+=("✓ $suite_name: PASSED")
        echo -e "${GREEN}✓ Test Suite '$suite_name' PASSED${NC}"
    else
        exit_code=$?
        echo "$output"
        FAILED_SUITES=$((FAILED_SUITES + 1))
        SUITE_RESULTS+=("✗ $suite_name: FAILED (exit code: $exit_code)")
        echo -e "${RED}✗ Test Suite '$suite_name' FAILED (exit code: $exit_code)${NC}"
    fi
    
    echo ""
}

# Function to print overall test results
print_overall_results() {
    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}OVERALL TEST RESULTS${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo ""
    
    echo "Test Suite Results:"
    for result in "${SUITE_RESULTS[@]}"; do
        if [[ "$result" == *"PASSED"* ]]; then
            echo -e "  ${GREEN}$result${NC}"
        else
            echo -e "  ${RED}$result${NC}"
        fi
    done
    
    echo ""
    echo "Summary:"
    echo "  Total test suites: $TOTAL_SUITES"
    echo -e "  ${GREEN}Passed: $PASSED_SUITES${NC}"
    
    if [[ $FAILED_SUITES -gt 0 ]]; then
        echo -e "  ${RED}Failed: $FAILED_SUITES${NC}"
        echo ""
        echo -e "${RED}Some test suites failed!${NC}"
        return 1
    else
        echo -e "  ${GREEN}All test suites passed!${NC}"
        echo ""
        echo -e "${GREEN}🎉 All tests completed successfully!${NC}"
        return 0
    fi
}

# Function to check if test files exist
check_test_files() {
    local missing_files=()
    
    local test_files=(
        "${SCRIPT_DIR}/test-utils.sh"
        "${SCRIPT_DIR}/test-validate-inputs.sh"
        "${SCRIPT_DIR}/test-validate-aws-config.sh"
        "${SCRIPT_DIR}/test-integration.sh"
    )
    
    for test_file in "${test_files[@]}"; do
        if [[ ! -f "$test_file" ]]; then
            missing_files+=("$test_file")
        elif [[ ! -x "$test_file" ]]; then
            echo "Making $test_file executable..."
            chmod +x "$test_file"
        fi
    done
    
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing test files:${NC}"
        for file in "${missing_files[@]}"; do
            echo "  - $file"
        done
        return 1
    fi
    
    return 0
}

# Function to set up test environment
setup_test_environment() {
    echo "Setting up test environment..."
    
    # Make test framework executable
    if [[ -f "${SCRIPT_DIR}/test-framework.sh" ]]; then
        chmod +x "${SCRIPT_DIR}/test-framework.sh"
    fi
    
    # Create temporary directory for test artifacts
    export TEST_ARTIFACTS_DIR
    TEST_ARTIFACTS_DIR=$(mktemp -d)
    
    # Set test mode environment variables
    export TEST_MODE=true
    export CI=true  # Suppress interactive prompts
    
    echo "Test environment ready"
    echo "Test artifacts directory: $TEST_ARTIFACTS_DIR"
    echo ""
}

# Function to clean up test environment
cleanup_test_environment() {
    echo "Cleaning up test environment..."
    
    # Remove test artifacts directory
    if [[ -n "${TEST_ARTIFACTS_DIR:-}" ]] && [[ -d "$TEST_ARTIFACTS_DIR" ]]; then
        rm -rf "$TEST_ARTIFACTS_DIR"
        echo "Removed test artifacts directory"
    fi
    
    # Unset test environment variables
    unset TEST_MODE TEST_ARTIFACTS_DIR CI 2>/dev/null || true
    
    echo "Test environment cleaned up"
}

# Function to validate test dependencies
validate_test_dependencies() {
    echo "Validating test dependencies..."
    
    local missing_deps=()
    
    # Check for required commands
    local required_commands=("bash" "jq" "date" "mktemp")
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing required dependencies:${NC}"
        for dep in "${missing_deps[@]}"; do
            echo "  - $dep"
        done
        echo ""
        echo "Please install the missing dependencies and try again."
        return 1
    fi
    
    echo "All dependencies are available"
    return 0
}

# Function to show usage information
show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Run all unit tests for the CloudFormation stack deletion action.

OPTIONS:
    -h, --help          Show this help message
    -v, --verbose       Enable verbose output
    -q, --quiet         Suppress non-essential output
    --no-cleanup        Skip cleanup of test environment
    --suite SUITE       Run only specific test suite (utils|inputs|aws-config|integration)

EXAMPLES:
    $0                  Run all test suites
    $0 --verbose        Run all tests with verbose output
    $0 --suite utils    Run only utility function tests
    $0 --suite inputs   Run only input validation tests
    $0 --suite aws-config Run only AWS configuration tests
    $0 --suite integration Run only integration tests

EOF
}

# Main function
main() {
    local verbose=false
    local quiet=false
    local no_cleanup=false
    local specific_suite=""
    
    # Parse command line arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                show_usage
                exit 0
                ;;
            -v|--verbose)
                verbose=true
                export DEBUG=true
                shift
                ;;
            -q|--quiet)
                quiet=true
                shift
                ;;
            --no-cleanup)
                no_cleanup=true
                shift
                ;;
            --suite)
                specific_suite="$2"
                shift 2
                ;;
            *)
                echo -e "${RED}Error: Unknown option $1${NC}"
                show_usage
                exit 1
                ;;
        esac
    done
    
    # Set up trap for cleanup
    if [[ "$no_cleanup" != true ]]; then
        trap cleanup_test_environment EXIT
    fi
    
    # Print header
    if [[ "$quiet" != true ]]; then
        echo -e "${BLUE}========================================${NC}"
        echo -e "${BLUE}CloudFormation Stack Delete Action${NC}"
        echo -e "${BLUE}Unit Test Runner${NC}"
        echo -e "${BLUE}========================================${NC}"
        echo ""
    fi
    
    # Validate dependencies
    if ! validate_test_dependencies; then
        exit 1
    fi
    
    # Check test files
    if ! check_test_files; then
        exit 1
    fi
    
    # Set up test environment
    setup_test_environment
    
    # Run test suites based on selection
    case "$specific_suite" in
        "")
            # Run all test suites
            run_test_suite "${SCRIPT_DIR}/test-utils.sh" "Utility Functions"
            run_test_suite "${SCRIPT_DIR}/test-validate-inputs.sh" "Input Validation"
            run_test_suite "${SCRIPT_DIR}/test-validate-aws-config.sh" "AWS Configuration Validation"
            run_test_suite "${SCRIPT_DIR}/test-integration.sh" "Integration Tests"
            ;;
        "utils")
            run_test_suite "${SCRIPT_DIR}/test-utils.sh" "Utility Functions"
            ;;
        "inputs")
            run_test_suite "${SCRIPT_DIR}/test-validate-inputs.sh" "Input Validation"
            ;;
        "aws-config")
            run_test_suite "${SCRIPT_DIR}/test-validate-aws-config.sh" "AWS Configuration Validation"
            ;;
        "integration")
            run_test_suite "${SCRIPT_DIR}/test-integration.sh" "Integration Tests"
            ;;
        *)
            echo -e "${RED}Error: Unknown test suite '$specific_suite'${NC}"
            echo "Available suites: utils, inputs, aws-config, integration"
            exit 1
            ;;
    esac
    
    # Print overall results
    if [[ "$quiet" != true ]]; then
        print_overall_results
    fi
}

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
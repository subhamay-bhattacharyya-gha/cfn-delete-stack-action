#!/bin/bash

# Input validation functions for CloudFormation stack deletion action
# Validates stack names, AWS regions, and other input parameters

set -euo pipefail

# Source utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/utils.sh"

# Stack name validation
validate_stack_name() {
    local stack_name="$1"
    
    # Check if stack name is provided and non-empty
    if [[ -z "${stack_name:-}" ]]; then
        handle_validation_error "Stack name is required and cannot be empty"
    fi
    
    # Trim whitespace
    stack_name=$(trim "$stack_name")
    
    # Check if stack name is still empty after trimming
    if [[ -z "$stack_name" ]]; then
        handle_validation_error "Stack name cannot be only whitespace"
    fi
    
    # Check stack name length (CloudFormation limit is 255 characters)
    if [[ ${#stack_name} -gt 255 ]]; then
        handle_validation_error "Stack name cannot exceed 255 characters (current: ${#stack_name})"
    fi
    
    # Check for valid characters (alphanumeric, hyphens, and underscores)
    # CloudFormation stack names can contain: a-z, A-Z, 0-9, hyphens, and must start with alpha
    if [[ ! "$stack_name" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]]; then
        handle_validation_error "Stack name '$stack_name' contains invalid characters. Stack names must start with a letter and can only contain letters, numbers, and hyphens"
    fi
    
    # Check that stack name doesn't end with hyphen
    if [[ "$stack_name" =~ -$ ]]; then
        handle_validation_error "Stack name '$stack_name' cannot end with a hyphen"
    fi
    
    # Check for consecutive hyphens
    if [[ "$stack_name" =~ -- ]]; then
        handle_validation_error "Stack name '$stack_name' cannot contain consecutive hyphens"
    fi
    
    log_debug "Stack name validation passed: $stack_name"
    echo "$stack_name"
}

# AWS region validation
validate_aws_region() {
    local region="$1"
    
    # If region is empty, return default
    if [[ -z "${region:-}" ]]; then
        log_debug "No region specified, will use AWS default configuration"
        return 0
    fi
    
    # Trim whitespace
    region=$(trim "$region")
    
    # Check AWS region format (e.g., us-east-1, eu-west-1, ap-southeast-2)
    if [[ ! "$region" =~ ^[a-z]{2,3}-[a-z]+-[0-9]+$ ]]; then
        handle_validation_error "Invalid AWS region format '$region'. Expected format: us-east-1, eu-west-1, ap-southeast-2, etc."
    fi
    
    # List of valid AWS regions (as of 2024)
    local valid_regions=(
        "us-east-1" "us-east-2" "us-west-1" "us-west-2"
        "eu-north-1" "eu-west-1" "eu-west-2" "eu-west-3" "eu-central-1" "eu-south-1"
        "ap-northeast-1" "ap-northeast-2" "ap-northeast-3" "ap-southeast-1" "ap-southeast-2" "ap-south-1"
        "ca-central-1"
        "sa-east-1"
        "af-south-1"
        "me-south-1"
        "ap-east-1"
        "us-gov-east-1" "us-gov-west-1"
        "cn-north-1" "cn-northwest-1"
    )
    
    # Check if region is in the list of valid regions
    local region_valid=false
    for valid_region in "${valid_regions[@]}"; do
        if [[ "$region" == "$valid_region" ]]; then
            region_valid=true
            break
        fi
    done
    
    if [[ "$region_valid" == false ]]; then
        handle_validation_error "Unknown AWS region '$region'. Please verify the region name is correct"
    fi
    
    log_debug "AWS region validation passed: $region"
    echo "$region"
}

# Boolean parameter validation
validate_boolean() {
    local param_name="$1"
    local param_value="$2"
    
    # If empty, return default false
    if [[ -z "${param_value:-}" ]]; then
        echo "false"
        return 0
    fi
    
    # Trim and convert to lowercase
    param_value=$(trim "$param_value")
    param_value=$(to_lower "$param_value")
    
    case "$param_value" in
        "true"|"yes"|"1"|"on")
            echo "true"
            ;;
        "false"|"no"|"0"|"off")
            echo "false"
            ;;
        *)
            handle_validation_error "Invalid boolean value for $param_name: '$param_value'. Expected: true/false, yes/no, 1/0, on/off"
            ;;
    esac
}

# Main validation function that validates all inputs
validate_all_inputs() {
    local stack_name="${1:-}"
    local aws_region="${2:-}"
    local wait_for_completion="${3:-true}"
    
    log_info "Validating input parameters..."
    
    # Validate stack name (required)
    local validated_stack_name
    validated_stack_name=$(validate_stack_name "$stack_name")
    
    # Validate AWS region (optional)
    local validated_region=""
    if [[ -n "$aws_region" ]]; then
        validated_region=$(validate_aws_region "$aws_region")
    fi
    
    # Validate wait for completion flag
    local validated_wait_flag
    validated_wait_flag=$(validate_boolean "wait-for-completion" "$wait_for_completion")
    
    log_success "All input parameters validated successfully"
    
    # Return validated values
    echo "STACK_NAME=$validated_stack_name"
    if [[ -n "$validated_region" ]]; then
        echo "AWS_REGION=$validated_region"
    fi
    echo "WAIT_FOR_COMPLETION=$validated_wait_flag"
}

# Function to display validation help
show_validation_help() {
    cat << EOF

Input Parameter Validation Help:

Stack Name Requirements:
  - Must not be empty
  - Must start with a letter (a-z, A-Z)
  - Can contain letters, numbers, and hyphens
  - Cannot end with a hyphen
  - Cannot contain consecutive hyphens
  - Maximum length: 255 characters
  - Examples: my-stack, MyStack123, test-stack-1

AWS Region Format:
  - Must follow AWS region naming convention
  - Format: [region]-[location]-[number]
  - Examples: us-east-1, eu-west-2, ap-southeast-1
  - Leave empty to use default AWS configuration

Wait for Completion:
  - Boolean parameter (true/false)
  - Accepts: true, false, yes, no, 1, 0, on, off
  - Default: true

EOF
}

# Export validation functions
export -f validate_stack_name validate_aws_region validate_boolean validate_all_inputs show_validation_help
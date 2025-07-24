# CloudFormation Stack Delete Action

![Built with Kiro](https://img.shields.io/badge/Built%20with-Kiro-blue?style=flat&logo=data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMjQiIGhlaWdodD0iMjQiIHZpZXdCb3g9IjAgMCAyNCAyNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZD0iTTEyIDJMMTMuMDkgOC4yNkwyMCA5TDEzLjA5IDE1Ljc0TDEyIDIyTDEwLjkxIDE1Ljc0TDQgOUwxMC45MSA4LjI2TDEyIDJaIiBmaWxsPSJ3aGl0ZSIvPgo8L3N2Zz4K)&nbsp;![GitHub Action](https://img.shields.io/badge/GitHub-Action-blue?logo=github)&nbsp;![Release](https://github.com/subhamay-bhattacharyya-gha/cfn-delete-stack-action/actions/workflows/release.yaml/badge.svg)&nbsp;![Commit Activity](https://img.shields.io/github/commit-activity/t/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![Bash](https://img.shields.io/badge/Language-Bash-green?logo=gnubash)&nbsp;![CloudFormation](https://img.shields.io/badge/AWS-CloudFormation-orange?logo=amazonaws)&nbsp;![Last Commit](https://img.shields.io/github/last-commit/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![Release Date](https://img.shields.io/github/release-date/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![Repo Size](https://img.shields.io/github/repo-size/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![File Count](https://img.shields.io/github/directory-file-count/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![Issues](https://img.shields.io/github/issues/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![Top Language](https://img.shields.io/github/languages/top/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![Custom Endpoint](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/bsubhamay/9f5f5ffe16a8d90513e2db8b247e9905/raw/cfn-delete-stack-action.json?)


A GitHub Action for deleting AWS CloudFormation stacks with real-time logging and comprehensive error handling.

## Overview

This GitHub Action provides a reusable composite workflow that deletes AWS CloudFormation stacks while displaying real-time progress logs in the console. It handles various stack states gracefully and provides detailed feedback throughout the deletion process.

## Features

- ✅ **Real-time Logging**: Monitor CloudFormation events as they happen
- ✅ **Comprehensive Error Handling**: Graceful handling of various stack states and AWS errors
- ✅ **Flexible Configuration**: Support for different AWS regions and completion modes
- ✅ **Smart State Management**: Handles existing deletions, non-existent stacks, and edge cases
- ✅ **Detailed Outputs**: Provides stack status, deletion time, and operation summaries
- ✅ **Robust Authentication**: Uses standard AWS credential resolution methods

---

## Inputs

| Name | Description | Required | Default | Example |
|------|-------------|----------|---------|---------|
| `stack-name` | Name of the CloudFormation stack to delete | Yes | — | `my-application-stack` |
| `aws-region` | AWS region where the stack is located | No | `us-east-1` | `us-west-2` |
| `wait-for-completion` | Whether to wait for deletion to complete | No | `true` | `false` |

## Outputs

| Name | Description | Example |
|------|-------------|---------|
| `stack-status` | Final status of the stack deletion operation | `DELETE_COMPLETE` |
| `deletion-time` | Time taken for the deletion process | `5m 32s` |
| `operation-result` | Result of the deletion operation | `success` |
| `summary` | Human-readable summary of the deletion process | `Stack 'my-app' deleted successfully in 5m 32s` |

---

## Usage Examples

### Basic Usage

```yaml
name: Delete CloudFormation Stack

on:
  workflow_dispatch:
    inputs:
      stack-name:
        description: 'Stack name to delete'
        required: true

jobs:
  delete-stack:
    runs-on: ubuntu-latest
    steps:
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: us-east-1

      - name: Delete CloudFormation Stack
        uses: your-org/cloudformation-stack-delete-action@v1
        with:
          stack-name: ${{ github.event.inputs.stack-name }}
```

### Advanced Usage with Multiple Regions

```yaml
name: Multi-Region Stack Cleanup

on:
  schedule:
    - cron: '0 2 * * 0'  # Weekly cleanup

jobs:
  cleanup-stacks:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        region: [us-east-1, us-west-2, eu-west-1]
        stack: [dev-app-stack, staging-app-stack]
    steps:
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ matrix.region }}

      - name: Delete Stack
        uses: your-org/cloudformation-stack-delete-action@v1
        with:
          stack-name: ${{ matrix.stack }}
          aws-region: ${{ matrix.region }}
          wait-for-completion: 'true'
```

### Conditional Deletion with Error Handling

```yaml
name: Conditional Stack Deletion

on:
  pull_request:
    types: [closed]

jobs:
  cleanup-pr-stack:
    runs-on: ubuntu-latest
    if: github.event.pull_request.merged == true
    steps:
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Delete PR Stack
        id: delete-stack
        uses: your-org/cloudformation-stack-delete-action@v1
        with:
          stack-name: pr-${{ github.event.pull_request.number }}-stack
          aws-region: us-east-1
        continue-on-error: true

      - name: Handle Deletion Result
        run: |
          echo "Stack Status: ${{ steps.delete-stack.outputs.stack-status }}"
          echo "Deletion Time: ${{ steps.delete-stack.outputs.deletion-time }}"
          echo "Operation Result: ${{ steps.delete-stack.outputs.operation-result }}"
          echo "Summary: ${{ steps.delete-stack.outputs.summary }}"
          
          if [ "${{ steps.delete-stack.outputs.operation-result }}" != "success" ]; then
            echo "Stack deletion failed or was skipped"
          fi
```

### Integration with Deployment Pipeline

```yaml
name: Deploy and Cleanup Pipeline

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    outputs:
      stack-name: ${{ steps.deploy.outputs.stack-name }}
    steps:
      - name: Deploy Stack
        id: deploy
        run: |
          # Your deployment logic here
          echo "stack-name=my-app-$(date +%s)" >> $GITHUB_OUTPUT

  cleanup-old-stacks:
    needs: deploy
    runs-on: ubuntu-latest
    if: success()
    steps:
      - name: Configure AWS Credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Delete Old Stacks
        uses: your-org/cloudformation-stack-delete-action@v1
        with:
          stack-name: old-stack-name
          aws-region: us-east-1
        continue-on-error: true
```

---

## Prerequisites

### AWS Credentials

This action requires AWS credentials to be configured. You can use any of the following methods:

1. **AWS Actions (Recommended)**:
   ```yaml
   - uses: aws-actions/configure-aws-credentials@v4
     with:
       aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
       aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
       aws-region: us-east-1
   ```

2. **IAM Roles (Most Secure)**:
   ```yaml
   - uses: aws-actions/configure-aws-credentials@v4
     with:
       role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
       aws-region: us-east-1
   ```

3. **Environment Variables**:
   ```yaml
   env:
     AWS_ACCESS_KEY_ID: ${{ secrets.AWS_ACCESS_KEY_ID }}
     AWS_SECRET_ACCESS_KEY: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
     AWS_DEFAULT_REGION: us-east-1
   ```

### Required Permissions

The AWS credentials must have the following CloudFormation permissions:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudformation:DeleteStack",
        "cloudformation:DescribeStacks",
        "cloudformation:DescribeStackEvents",
        "cloudformation:DescribeStackResources"
      ],
      "Resource": "*"
    }
  ]
}
```

---

## Troubleshooting

### Common Issues and Solutions

#### 1. Stack Not Found

**Error**: `Stack with id [stack-name] does not exist`

**Solution**: This is expected behavior when the stack has already been deleted or never existed. The action will exit successfully with a warning message.

```yaml
- name: Delete Stack (Allow Missing)
  uses: your-org/cloudformation-stack-delete-action@v1
  with:
    stack-name: potentially-missing-stack
  continue-on-error: true
```

#### 2. Insufficient Permissions

**Error**: `User: arn:aws:iam::123456789012:user/github-actions is not authorized to perform: cloudformation:DeleteStack`

**Solution**: Ensure your AWS credentials have the required CloudFormation permissions listed above.

#### 3. Stack in DELETE_IN_PROGRESS State

**Behavior**: The action will monitor the existing deletion process instead of initiating a new one.

**Log Output**:
```
Stack is already being deleted. Monitoring existing deletion process...
```

#### 4. Stack Has Dependent Resources

**Error**: Stack deletion fails due to dependent resources

**Solution**: The action will display the specific CloudFormation error. You may need to:
- Delete dependent stacks first
- Remove dependencies manually
- Use CloudFormation's force delete options (if available)

#### 5. AWS API Throttling

**Behavior**: The action implements exponential backoff for API throttling

**Log Output**:
```
AWS API throttling detected. Retrying in 2 seconds...
```

#### 6. Network Connectivity Issues

**Error**: Connection timeouts or network errors

**Solution**: The action includes retry logic. For persistent issues:
- Check GitHub Actions runner connectivity
- Verify AWS service status
- Consider using different AWS regions

### Debug Mode

Enable debug logging by setting the `ACTIONS_STEP_DEBUG` secret to `true` in your repository:

```yaml
- name: Delete Stack (Debug Mode)
  uses: your-org/cloudformation-stack-delete-action@v1
  with:
    stack-name: my-stack
  env:
    ACTIONS_STEP_DEBUG: true
```

### Getting Help

If you encounter issues not covered here:

1. Check the [GitHub Issues](https://github.com/your-org/cloudformation-stack-delete-action/issues)
2. Review the action logs for detailed error messages
3. Verify your AWS credentials and permissions
4. Test the same operation using AWS CLI directly

---

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request. For major changes, please open an issue first to discuss what you would like to change.

### Development

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Run the tests (`./scripts/run-unit-tests.sh`)
4. Commit your changes (`git commit -m 'Add some amazing feature'`)
5. Push to the branch (`git push origin feature/amazing-feature`)
6. Open a Pull Request

### Testing

This action includes comprehensive unit and integration tests:

```bash
# Run unit tests
./scripts/run-unit-tests.sh

# Run integration tests (requires AWS credentials)
./scripts/test-integration.sh
```

---

## License

MIT License - see the [LICENSE](LICENSE) file for details.

---

## Support

- 📖 [Documentation](https://github.com/your-org/cloudformation-stack-delete-action/wiki)
- 🐛 [Report Issues](https://github.com/your-org/cloudformation-stack-delete-action/issues)
- 💬 [Discussions](https://github.com/your-org/cloudformation-stack-delete-action/discussions)
- 📧 [Contact](mailto:support@your-org.com)

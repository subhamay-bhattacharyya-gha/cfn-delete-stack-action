![](https://img.shields.io/github/commit-activity/t/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![](https://img.shields.io/github/last-commit/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![](https://img.shields.io/github/release-date/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![](https://img.shields.io/github/repo-size/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![](https://img.shields.io/github/directory-file-count/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![](https://img.shields.io/github/issues/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![](https://img.shields.io/github/languages/top/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![](https://img.shields.io/github/commit-activity/m/subhamay-bhattacharyya-gha/cfn-delete-stack-action)&nbsp;![](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/bsubhamay/4b26766f519f27f416cf5f45eb36901f/raw/cfn-delete-stack-action.json?)

# 🧹 Delete CloudFormation Stack GitHub Action

This GitHub Composite Action deletes an AWS CloudFormation stack and monitors the deletion process until completion or failure.

## ✅ What It Does

- Initiates a CloudFormation stack deletion.
- Polls for deletion status every 5 seconds.
- Fails early if the stack hits a `DELETE_FAILED` status.
- Times out after a default of 10 minutes (can be adjusted).
- Outputs the stack name when deletion succeeds.

## 📦 Usage

```yaml
jobs:
  cleanup:
    runs-on: ubuntu-latest
    steps:
      - name: Delete CloudFormation Stack and Monitor Progress
        uses: subhamay-bhattacharyya-gha/cfn-delete-stack-action@main
        with:
          stack-name: cloudformation-stack-name
          aws-region: us-east-1
```

## License

MIT
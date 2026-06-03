# GitHub Secrets Required

Configure these secrets in your GitHub repository under **Settings → Secrets and variables → Actions**.

## CI Pipeline (ci.yml)

| Secret Name | Description | Example |
|-------------|-------------|---------|
| `DOCKERHUB_USERNAME` | Docker Hub username | `johnbaabalola` |
| `DOCKERHUB_TOKEN` | Docker Hub access token (not password) | `dckr_pat_...` |

## CD Pipeline (cd.yml) — OIDC, no static AWS keys

CD authenticates to AWS via GitHub OIDC (short-lived credentials). There are no
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` secrets. The deploy role and OIDC
provider are created by Terraform (`terraform/modules/github-oidc`); after
`terraform apply`, read the role ARN from `terraform output github_actions_role_arn`.

| Secret Name | Description | Source |
|-------------|-------------|--------|
| `AWS_DEPLOY_ROLE_ARN` | IAM role the workflow assumes via OIDC | `terraform output github_actions_role_arn` |
| `AWS_REGION` | AWS region | `eu-west-2` |
| `EKS_CLUSTER_NAME` | EKS cluster name | `vidcast-cluster` |
| `DOCKERHUB_USERNAME` | Used to set the deployment image name | your Docker Hub username |

The workflow also needs `permissions: id-token: write` (already set in cd.yml) to
request the OIDC token.

## Jenkins Pipeline (Jenkinsfile)

Configure these in Jenkins under **Manage Jenkins → Credentials**.

| Credential ID | Type | Description |
|---------------|------|-------------|
| `dockerhub-credentials` | Username/Password | Docker Hub login |
| `aws-credentials` | AWS Credentials | IAM key for EKS access |
| `swarm-staging-ip` | Secret text | IP address of Swarm staging EC2 |

## How to Create a Docker Hub Access Token

1. Log in to hub.docker.com
2. Account Settings → Security → New Access Token
3. Name it `github-actions-vidcast`
4. Copy the token immediately — it won't be shown again
5. Add as `DOCKERHUB_TOKEN` in GitHub Secrets

## How to Create the AWS IAM User for CI/CD

```bash
aws iam create-user --user-name vidcast-cicd
aws iam attach-user-policy --user-name vidcast-cicd \
  --policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
# For minimal permissions, use a custom policy allowing only:
# eks:UpdateClusterVersion, eks:DescribeCluster, and kubectl via kubeconfig
aws iam create-access-key --user-name vidcast-cicd
```

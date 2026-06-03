output "deploy_role_arn" {
  description = "ARN of the IAM role GitHub Actions assumes via OIDC (set as the AWS_DEPLOY_ROLE_ARN GitHub secret)"
  value       = aws_iam_role.deploy.arn
}

output "oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC identity provider"
  value       = aws_iam_openid_connect_provider.github.arn
}

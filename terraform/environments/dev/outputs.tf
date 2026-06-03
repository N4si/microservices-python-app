output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = module.eks.cluster_endpoint
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = module.vpc.public_subnet_ids
}

output "node_security_group_id" {
  description = "NodePort security group ID"
  value       = module.security_groups.security_group_id
}

output "kubeconfig_command" {
  description = "Run this command to configure kubectl"
  value       = module.eks.kubeconfig_command
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA setup"
  value       = module.eks.oidc_provider_arn
}

output "github_actions_role_arn" {
  description = "Set this as the AWS_DEPLOY_ROLE_ARN secret in GitHub for OIDC-based CD"
  value       = module.github_oidc.deploy_role_arn
}

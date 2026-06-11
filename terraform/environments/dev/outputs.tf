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

output "external_secrets_irsa_role_arn" {
  description = "Annotate the vidcast-eso ServiceAccount with eks.amazonaws.com/role-arn = this value (A9)"
  value       = module.external_secrets.irsa_role_arn
}

output "ecr_repository_urls" {
  description = "Hardened ECR repository URLs (A8)"
  value       = module.ecr.repository_urls
}

output "lbc_irsa_role_arn" {
  description = "Set as the eks.amazonaws.com/role-arn annotation on the aws-load-balancer-controller SA (k8s/ingress/alb-controller-values.yaml) (P1/I7)"
  value       = module.lbc.lbc_irsa_role_arn
}

output "backup_bucket_name" {
  description = "S3 backup bucket the mongodump/pg_dump CronJobs write to (I4/P5)"
  value       = module.storage.backup_bucket_name
}

output "backup_irsa_role_arn" {
  description = "Annotate the vidcast-backup ServiceAccount with eks.amazonaws.com/role-arn = this value (I4/P5)"
  value       = module.storage.backup_irsa_role_arn
}

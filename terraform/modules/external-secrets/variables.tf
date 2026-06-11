variable "cluster_name" {
  description = "EKS cluster name (used to name the IRSA role)"
  type        = string
}

variable "aws_region" {
  description = "AWS region — scopes the SSM parameter ARN and the kms ViaService condition"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster OIDC provider (module.eks.oidc_provider_arn) — the IRSA trust anchor"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the cluster OIDC provider (module.eks.oidc_provider_url), e.g. oidc.eks.eu-west-2.amazonaws.com/id/XXXX"
  type        = string
}

variable "service_account_namespace" {
  description = "Namespace of the Kubernetes ServiceAccount that External Secrets assumes the role through"
  type        = string
  default     = "default"
}

variable "service_account_name" {
  description = "Name of the Kubernetes ServiceAccount referenced by the ClusterSecretStore"
  type        = string
  default     = "vidcast-eso"
}

variable "parameter_path_prefix" {
  description = "SSM Parameter Store path prefix the ESO role may read (least-privilege). Trailing /* is appended."
  type        = string
  default     = "/vidcast"
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}

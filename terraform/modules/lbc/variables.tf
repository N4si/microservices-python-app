variable "cluster_name" {
  description = "EKS cluster name (used to name the LBC IRSA role/policy)"
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the cluster OIDC provider (module.eks.oidc_provider_arn) — the IRSA trust anchor"
  type        = string
}

variable "oidc_provider_url" {
  description = "URL of the cluster OIDC provider (module.eks.oidc_provider_url)"
  type        = string
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}

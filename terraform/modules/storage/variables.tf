variable "cluster_name" {
  description = "EKS cluster name (used to name the backup IRSA role)"
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

variable "bucket_prefix" {
  description = "Prefix for the backup bucket; the AWS account ID is appended for global uniqueness"
  type        = string
  default     = "vidcast-backups"
}

variable "retention_days" {
  description = "Days to retain each backup object (and noncurrent versions) before lifecycle expiry"
  type        = number
  default     = 30
}

variable "service_account_namespace" {
  description = "Namespace of the backup CronJob ServiceAccount"
  type        = string
  default     = "default"
}

variable "service_account_name" {
  description = "Name of the backup CronJob ServiceAccount (annotated with the IRSA role ARN)"
  type        = string
  default     = "vidcast-backup"
}

variable "tags" {
  description = "Common tags"
  type        = map(string)
  default     = {}
}

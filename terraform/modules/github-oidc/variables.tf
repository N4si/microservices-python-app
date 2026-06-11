variable "cluster_name" {
  description = "EKS cluster name — used for role naming and the describe-cluster scope"
  type        = string
}

variable "aws_region" {
  description = "AWS region of the EKS cluster"
  type        = string
}

variable "github_org" {
  description = "GitHub organisation or user that owns the repo"
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without the org prefix)"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

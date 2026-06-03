variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "eu-west-2"
}

variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
  default     = "vidcast-cluster"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "Availability zones for public subnets"
  type        = list(string)
  default     = ["eu-west-2a", "eu-west-2b"]
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "node_instance_type" {
  description = "EC2 instance type for worker nodes. Must be M/C/R-series — T-type is blocked by SCP."
  type        = string
  default     = "m7i-flex.large"
}

variable "node_min_count" {
  description = "Minimum node count"
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum node count"
  type        = number
  default     = 2
}

variable "node_desired_count" {
  description = "Desired node count"
  type        = number
  default     = 1
}

variable "state_bucket" {
  description = "S3 bucket name for Terraform remote state"
  type        = string
}

variable "state_lock_table" {
  description = "DynamoDB table name for Terraform state locking"
  type        = string
  default     = "vidcast-terraform-locks"
}

variable "github_org" {
  description = "GitHub org/user that owns the repo (for the OIDC deploy role trust policy)"
  type        = string
  default     = "johnnybabs"
}

variable "github_repo" {
  description = "GitHub repository name (for the OIDC deploy role trust policy)"
  type        = string
  default     = "microservices-python-app"
}

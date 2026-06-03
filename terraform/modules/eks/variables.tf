variable "cluster_name" {
  description = "EKS cluster name"
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.31"
}

variable "authentication_mode" {
  description = "EKS cluster authentication mode. API_AND_CONFIG_MAP supports both access entries and the aws-auth ConfigMap."
  type        = string
  default     = "API_AND_CONFIG_MAP"
}

variable "cluster_role_arn" {
  description = "ARN of the IAM role for the EKS cluster"
  type        = string
}

variable "node_role_arn" {
  description = "ARN of the IAM role for the EKS node group"
  type        = string
}

variable "subnet_ids" {
  description = "List of subnet IDs for the EKS cluster and node group"
  type        = list(string)
}

variable "node_instance_type" {
  description = "EC2 instance type for EKS worker nodes. Must NOT be a T-type — SCPs on this account reject CreditSpecification:unlimited which EKS auto-generates for T-type instances."
  type        = string
  default     = "m7i-flex.large"

  validation {
    condition     = !startswith(var.node_instance_type, "t")
    error_message = "T-type instances (t2, t3, t4g, etc.) are blocked by SCP on this AWS account. Use m7i-flex.large or another M/C/R-series instance."
  }
}

variable "node_min_count" {
  description = "Minimum number of nodes in the node group"
  type        = number
  default     = 1
}

variable "node_max_count" {
  description = "Maximum number of nodes in the node group"
  type        = number
  default     = 2
}

variable "node_desired_count" {
  description = "Desired number of nodes in the node group"
  type        = number
  default     = 1
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

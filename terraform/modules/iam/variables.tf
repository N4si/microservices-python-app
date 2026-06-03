variable "cluster_name" {
  description = "EKS cluster name — used for role naming"
  type        = string
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

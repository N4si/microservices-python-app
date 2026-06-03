variable "cluster_name" {
  description = "EKS cluster name — used for resource naming"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the security group will be created"
  type        = string
}

variable "nodeport_ports" {
  description = "List of NodePort port numbers to open for inbound traffic"
  type        = list(number)
  default     = [30002, 30003, 30004, 30005, 30006, 30007, 30008]
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}

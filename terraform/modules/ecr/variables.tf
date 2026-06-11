variable "repository_names" {
  description = "ECR repositories to create with hardened settings (immutable tags, scan-on-push, lifecycle expiry)."
  type        = list(string)
  default     = ["vidcast-frontend"]
}

variable "untagged_expire_days" {
  description = "Expire untagged images older than this many days."
  type        = number
  default     = 7
}

variable "keep_last_images" {
  description = "Keep only this many most-recent images per repository."
  type        = number
  default     = 10
}

variable "tags" {
  description = "Tags applied to every repository."
  type        = map(string)
  default     = {}
}

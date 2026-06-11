output "backup_bucket_name" {
  description = "Name of the S3 backup bucket. The CronJobs hardcode this; if you change bucket_prefix, update k8s/base/backup/*.yaml BACKUP_BUCKET."
  value       = aws_s3_bucket.backups.id
}

output "backup_bucket_arn" {
  description = "ARN of the S3 backup bucket"
  value       = aws_s3_bucket.backups.arn
}

output "backup_irsa_role_arn" {
  description = "Annotate the vidcast-backup ServiceAccount with eks.amazonaws.com/role-arn = this value (I4/P5)"
  value       = aws_iam_role.backup.arn
}

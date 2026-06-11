# Backup storage.
#
# A single private, versioned, encrypted S3 bucket that the nightly mongodump /
# pg_dump CronJobs write to, plus the IRSA role those CronJobs assume to do so.
# This is the durability backstop for the stateful tier: the application layer is
# already recoverable from Git via Argo CD, but the databases were not backed up
# anywhere until now.
#
# Cost is negligible (compressed dumps + a 30-day lifecycle expiry). See
# docs/DISASTER_RECOVERY.md for the restore procedure this bucket feeds.

data "aws_caller_identity" "current" {}

locals {
  # Deterministic, account-suffixed name — same convention as the Terraform state
  # bucket (vidcast-tfstate-<account>). Lets the CronJobs hardcode the name without
  # a Terraform→kustomize value handoff.
  bucket_name = "${var.bucket_prefix}-${data.aws_caller_identity.current.account_id}"
  oidc_host   = replace(var.oidc_provider_url, "https://", "")
}

resource "aws_s3_bucket" "backups" {
  bucket = local.bucket_name
  tags   = var.tags
}

# Keep a short history of each nightly dump so a bad dump doesn't immediately
# overwrite the last good one.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Backups can contain user data (GridFS files, auth rows) — never public.
resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# SSE with the free AWS-managed S3 key (AES256) — no CMK by the project's cost
# decision (consistent with the ECR/ESO choices).
resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Retention: expire dumps after retention_days; clean up old versions and
# abandoned multipart uploads so the bucket can't grow unbounded.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-backups"
    status = "Enabled"

    filter {} # all objects

    expiration {
      days = var.retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = var.retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# --- IRSA role for the backup CronJobs --------------------------------------
# Assumed by default:vidcast-backup. Scoped to PutObject/ListBucket on THIS
# bucket only — the CronJobs can write dumps and nothing else.
data "aws_iam_policy_document" "backup_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:${var.service_account_namespace}:${var.service_account_name}"]
    }
  }
}

resource "aws_iam_role" "backup" {
  name               = "${var.cluster_name}-backup-irsa"
  assume_role_policy = data.aws_iam_policy_document.backup_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "backup_write" {
  statement {
    sid       = "ListBackupBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.backups.arn]
  }

  statement {
    sid       = "WriteBackupObjects"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.backups.arn}/*"]
  }
}

resource "aws_iam_role_policy" "backup" {
  name   = "${var.cluster_name}-backup-write"
  role   = aws_iam_role.backup.id
  policy = data.aws_iam_policy_document.backup_write.json
}

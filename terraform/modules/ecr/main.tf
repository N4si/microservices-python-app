# A8 supply-chain — hardened ECR repositories.
#
# Three controls, all free within ECR limits:
#   1. IMMUTABLE tags  — a pushed tag can never be overwritten, so a digest you
#      verified once (cosign, B5) can't be swapped under the same tag.
#   2. scan-on-push    — ECR runs a basic CVE scan on every push (defence in depth
#      behind the CI Trivy gate).
#   3. lifecycle policy — expire untagged images after N days + keep only the last
#      N images, so the repo doesn't grow unbounded (and bill) over time.
#
# Encryption is AES256 (the AWS-managed key, free). A customer-managed KMS key
# (CMK) is DELIBERATELY skipped: it carries a ~$1/mo standing charge for marginal
# benefit on a portfolio project (see SUPPLY_CHAIN.md, cost decisions).

resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = each.value
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images older than ${var.untagged_expire_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_expire_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last ${var.keep_last_images} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.keep_last_images
        }
        action = { type = "expire" }
      }
    ]
  })
}

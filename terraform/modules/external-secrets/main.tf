# IRSA role for the External Secrets Operator (A9).
#
# ESO reads VidCast's secrets from AWS Systems Manager **Parameter Store**
# (chosen over Secrets Manager to avoid the $0.40/secret/month standing charge —
# standard-tier SSM parameters are free, and SecureString uses the AWS-MANAGED
# `alias/aws/ssm` key, which is also free; only customer-managed CMKs cost $1/mo).
#
# This role is assumed via IRSA: the ClusterSecretStore points at a Kubernetes
# ServiceAccount (default:vidcast-eso) annotated with this role's ARN. The trust
# policy below allows only that specific SA on this specific cluster's OIDC
# provider to assume the role — no long-lived keys anywhere.

data "aws_caller_identity" "current" {}

locals {
  # The OIDC condition keys are prefixed with the provider URL minus the scheme.
  oidc_host = replace(var.oidc_provider_url, "https://", "")

  # Least-privilege parameter ARN: only /vidcast/* parameters are readable.
  parameter_arn = "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${var.parameter_path_prefix}/*"
}

# Trust policy — only default:vidcast-eso on this cluster's OIDC provider.
data "aws_iam_policy_document" "assume" {
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

resource "aws_iam_role" "eso" {
  name               = "${var.cluster_name}-external-secrets-irsa"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

# Permission policy — read /vidcast/* parameters and decrypt SecureStrings via
# the SSM service only (kms:ViaService scopes the decrypt to Parameter Store, so
# this role cannot decrypt arbitrary KMS-encrypted data elsewhere).
data "aws_iam_policy_document" "read_parameters" {
  statement {
    sid    = "ReadVidcastParameters"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    resources = [local.parameter_arn]
  }

  statement {
    sid       = "DecryptViaSSMOnly"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "eso" {
  name   = "${var.cluster_name}-external-secrets-read"
  role   = aws_iam_role.eso.id
  policy = data.aws_iam_policy_document.read_parameters.json
}

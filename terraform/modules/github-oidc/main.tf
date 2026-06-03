# GitHub Actions OIDC identity provider + deploy role.
# Lets the CD workflow assume a short-lived role via OIDC instead of storing
# long-lived AWS access keys as GitHub secrets.

data "aws_caller_identity" "current" {}

# GitHub's OIDC issuer. The thumbprint is derived dynamically from the issuer's
# TLS certificate so it stays correct if GitHub rotates its CA.
data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
  tags            = var.tags
}

# Trust policy: only the GitHub OIDC provider may assume this role, and only for
# workflows running in this specific repo (any branch/ref). Tighten the sub
# condition to a specific ref (e.g. :ref:refs/heads/main) to lock it to main.
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "deploy" {
  name               = "${var.cluster_name}-github-deploy"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

# The only AWS API the CD workflow calls is eks:DescribeCluster (for
# `aws eks update-kubeconfig`). Kubernetes-level authorization is granted
# separately via an EKS access entry in the root module. Scope the describe to
# this one cluster ARN (constructed — avoids a dependency cycle on the cluster).
data "aws_iam_policy_document" "deploy" {
  statement {
    actions   = ["eks:DescribeCluster"]
    effect    = "Allow"
    resources = ["arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "eks-describe-cluster"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}

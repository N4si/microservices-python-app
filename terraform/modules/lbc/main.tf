# IRSA role for the AWS Load Balancer Controller (P1 / I7).
#
# The LBC runs in-cluster (kube-system) and provisions/manages ALBs from Ingress
# resources, so it needs IAM permission to call elasticloadbalancing, ec2, acm,
# wafv2, shield, etc. Those permissions are granted via IRSA to its
# kube-system:aws-load-balancer-controller ServiceAccount — no static keys.
#
# This is a SEPARATE module (not terraform/modules/iam) on purpose: the iam module
# creates the EKS cluster role that the eks module depends on, and the eks module
# is what creates the OIDC provider this trust policy needs. Putting an
# OIDC-consuming role in the iam module would form a cycle (iam→eks→iam). It
# mirrors the external-secrets and storage IRSA modules instead.

locals {
  oidc_host = replace(var.oidc_provider_url, "https://", "")
}

data "aws_iam_policy_document" "lbc_assume" {
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

    # Only the controller's SA may assume the role.
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "lbc" {
  name               = "${var.cluster_name}-lbc-irsa"
  assume_role_policy = data.aws_iam_policy_document.lbc_assume.json
  tags               = var.tags
}

# The official AWS LBC IAM policy, pinned to the controller version we install
# (v2.8.1). Keep this JSON in sync if the chart/controller version changes:
#   curl -o lbc-iam-policy.json \
#     https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.1/docs/install/iam_policy.json
resource "aws_iam_policy" "lbc" {
  name   = "${var.cluster_name}-lbc-policy"
  policy = file("${path.module}/lbc-iam-policy.json")
  tags   = var.tags
}

resource "aws_iam_role_policy_attachment" "lbc" {
  role       = aws_iam_role.lbc.name
  policy_arn = aws_iam_policy.lbc.arn
}

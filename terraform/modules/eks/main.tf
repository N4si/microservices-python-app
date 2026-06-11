resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  version  = var.kubernetes_version
  role_arn = var.cluster_role_arn

  # API_AND_CONFIG_MAP enables EKS access entries (used to grant the GitHub
  # Actions deploy role kubectl permissions) while keeping aws-auth working.
  # The principal that creates the cluster is auto-granted cluster admin.
  access_config {
    authentication_mode                         = var.authentication_mode
    bootstrap_cluster_creator_admin_permissions = true
  }

  vpc_config {
    subnet_ids              = var.subnet_ids
    endpoint_public_access  = true
    endpoint_private_access = false
  }

  tags = var.tags

  depends_on = [var.cluster_role_arn]
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-nodes"
  node_role_arn   = var.node_role_arn
  subnet_ids      = var.subnet_ids
  instance_types  = [var.node_instance_type]
  ami_type        = "AL2_x86_64"

  scaling_config {
    min_size     = var.node_min_count
    max_size     = var.node_max_count
    desired_size = var.node_desired_count
  }

  tags = var.tags

  depends_on = [aws_eks_cluster.this]
}

# VPC CNI add-on with the in-cluster NetworkPolicy enforcement agent enabled.
# WITHOUT this, NetworkPolicy objects are accepted by the API server but NEVER
# enforced — they become decorative YAML and the default-deny silently does
# nothing. enableNetworkPolicy flips on the eBPF agent in the aws-node DaemonSet.
# Set here so it is configured while the cluster is (re-)applied from scratch —
# toggling it on a live cluster recycles aws-node (plan §2.4).
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"

  configuration_values = jsonencode({
    enableNetworkPolicy = "true"
  })

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # The agent runs in the aws-node DaemonSet on the nodes.
  depends_on = [aws_eks_node_group.this]
}

# OIDC provider — required for IRSA (IAM Roles for Service Accounts)
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = var.tags
}

# --- EBS CSI driver (durability prerequisite) ---------------------------
# This cluster shipped with NO CSI driver, so dynamically-provisioned EBS PVCs
# stay Pending forever (the in-tree kubernetes.io/aws-ebs provisioner is removed
# in k8s 1.31). Installing the managed aws-ebs-csi-driver addon is what lets the
# Postgres PVC (and any future EBS-backed claim) actually bind. Kept in this
# module alongside vpc_cni because, like vpc_cni, it is core cluster
# infrastructure rather than an application concern.
#
# The driver's controller needs AWS permissions (create/attach/delete volumes),
# granted via IRSA to its kube-system:ebs-csi-controller-sa ServiceAccount — no
# node-role-wide EBS permissions, no static keys.
locals {
  ebs_oidc_host = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")
}

data "aws_iam_policy_document" "ebs_csi_assume" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.ebs_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Only the driver's controller SA may assume the role.
    condition {
      test     = "StringEquals"
      variable = "${local.ebs_oidc_host}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-irsa"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_assume.json
  tags               = var.tags
}

# AWS-managed policy purpose-built for the driver (least-privilege EBS lifecycle).
resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = aws_eks_cluster.this.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi.arn

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # Needs nodes to schedule the controller, and the role before it annotates the SA.
  depends_on = [aws_eks_node_group.this, aws_iam_role_policy_attachment.ebs_csi]
}

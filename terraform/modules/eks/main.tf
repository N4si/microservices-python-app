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

locals {
  common_tags = {
    Project     = "vidcast"
    ManagedBy   = "terraform"
    Environment = "dev"
    Region      = var.aws_region
  }
}

module "vpc" {
  source = "../../modules/vpc"

  cluster_name       = var.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  tags               = local.common_tags
}

module "iam" {
  source = "../../modules/iam"

  cluster_name = var.cluster_name
  tags         = local.common_tags
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  cluster_role_arn   = module.iam.cluster_role_arn
  node_role_arn      = module.iam.node_role_arn
  subnet_ids         = module.vpc.public_subnet_ids
  node_instance_type = var.node_instance_type
  node_min_count     = var.node_min_count
  node_max_count     = var.node_max_count
  node_desired_count = var.node_desired_count
  tags               = local.common_tags
}

module "security_groups" {
  source = "../../modules/security-groups"

  cluster_name   = var.cluster_name
  vpc_id         = module.vpc.vpc_id
  nodeport_ports = [30002, 30003, 30004, 30005, 30006, 30007, 30008]
  tags           = local.common_tags
}

# A8 supply-chain: hardened ECR repositories (immutable tags, scan-on-push,
# lifecycle expiry; AES256 — no CMK by cost decision). The existing
# vidcast-frontend repo predates this module and must be imported ONCE before the
# first apply, or apply will fail with "repository already exists":
#   terraform import 'module.ecr.aws_ecr_repository.this["vidcast-frontend"]' vidcast-frontend
# See SUPPLY_CHAIN.md. Add backend repos here if/when they move off Docker Hub.
module "ecr" {
  source = "../../modules/ecr"

  repository_names = ["vidcast-frontend"]
  tags             = local.common_tags
}

module "github_oidc" {
  source = "../../modules/github-oidc"

  cluster_name = var.cluster_name
  aws_region   = var.aws_region
  github_org   = var.github_org
  github_repo  = var.github_repo
  tags         = local.common_tags
}

# IRSA role for the External Secrets Operator (A9). Lets the in-cluster ESO
# ServiceAccount (default:vidcast-eso) read /vidcast/* parameters from SSM
# Parameter Store with no long-lived credentials. Cost: $0 (standard SSM
# parameters + AWS-managed SSM KMS key are free).
module "external_secrets" {
  source = "../../modules/external-secrets"

  cluster_name      = var.cluster_name
  aws_region        = var.aws_region
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = local.common_tags
}

# AWS Load Balancer Controller IRSA (P1 / I7). The controller (installed via Helm
# into kube-system) provisions ALBs from Ingress resources and assumes this role
# through its ServiceAccount. Separate module to avoid an iam↔eks dependency cycle
# (the role's trust needs the OIDC provider that the eks module creates).
module "lbc" {
  source = "../../modules/lbc"

  cluster_name      = var.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = local.common_tags
}

# Backup storage (I4 / P5). A private, versioned, encrypted S3 bucket the nightly
# mongodump / pg_dump CronJobs write to, plus the IRSA role (default:vidcast-backup)
# those jobs assume — scoped to PutObject on this bucket only. Cost: a few pennies
# for compressed dumps under a 30-day lifecycle. Bucket name is deterministic:
# vidcast-backups-<account_id>.
module "storage" {
  source = "../../modules/storage"

  cluster_name      = var.cluster_name
  oidc_provider_arn = module.eks.oidc_provider_arn
  oidc_provider_url = module.eks.oidc_provider_url
  tags              = local.common_tags
}

# Grant the GitHub Actions deploy role Kubernetes-level permissions on the
# cluster. The IAM role policy (eks:DescribeCluster) only gets it a kubeconfig;
# this access entry is what lets `kubectl set image` actually work. EKSEditPolicy
# allows patching deployments and reading pods — enough for the CD workflow.
resource "aws_eks_access_entry" "github_deploy" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.github_oidc.deploy_role_arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_deploy" {
  cluster_name  = module.eks.cluster_name
  principal_arn = module.github_oidc.deploy_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.github_deploy]
}

output "lbc_irsa_role_arn" {
  description = "Annotate the kube-system:aws-load-balancer-controller ServiceAccount with eks.amazonaws.com/role-arn = this value (set serviceAccount.annotations in k8s/ingress/alb-controller-values.yaml)"
  value       = aws_iam_role.lbc.arn
}

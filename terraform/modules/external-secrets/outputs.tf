output "irsa_role_arn" {
  description = "ARN of the IRSA role. Annotate the vidcast-eso ServiceAccount with eks.amazonaws.com/role-arn = this value."
  value       = aws_iam_role.eso.arn
}

output "irsa_role_name" {
  description = "Name of the IRSA role"
  value       = aws_iam_role.eso.name
}

output "service_account_annotation" {
  description = "Convenience: the exact ServiceAccount annotation k/v for the ESO SA"
  value       = "eks.amazonaws.com/role-arn: ${aws_iam_role.eso.arn}"
}

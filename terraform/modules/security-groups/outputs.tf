output "security_group_id" {
  description = "ID of the NodePort security group"
  value       = aws_security_group.node_ports.id
}

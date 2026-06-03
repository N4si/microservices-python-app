resource "aws_security_group" "node_ports" {
  name        = "${var.cluster_name}-nodeport-sg"
  description = "Allow inbound traffic to Kubernetes NodePort services"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.nodeport_ports
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
      description = "NodePort ${ingress.value}"
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = merge(var.tags, { Name = "${var.cluster_name}-nodeport-sg" })
}

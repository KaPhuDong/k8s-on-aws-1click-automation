output "alb_url" {
  description = "Open this URL after Terraform apply completes."
  value       = "http://${aws_lb.app.dns_name}"
}

output "alb_dns_name" {
  description = "ALB DNS name."
  value       = aws_lb.app.dns_name
}

output "ec2_public_ip" {
  description = "Public IP for SSH debug."
  value       = aws_instance.k8s.public_ip
}

output "ssh_private_key_path" {
  description = "Generated private key path."
  value       = local_file.private_key.filename
}

output "ssh_command" {
  description = "SSH command for manual debug."
  value       = "ssh -i ${local_file.private_key.filename} ubuntu@${aws_instance.k8s.public_ip}"
}

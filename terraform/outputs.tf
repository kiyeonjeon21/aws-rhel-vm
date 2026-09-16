output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.this.id
}

output "ami_id" {
  description = "Resolved RHEL AMI. Pinned after the first apply by ignore_changes."
  value       = data.aws_ami.rhel.id
}

output "ami_name" {
  description = "Human readable name of the resolved AMI, so the exact RHEL point release is visible."
  value       = data.aws_ami.rhel.name
}

output "public_ip" {
  description = "Address to SSH to. Stable across stop/start only when associate_eip is true."
  value       = var.associate_eip ? aws_eip.this[0].public_ip : aws_instance.this.public_ip
}

output "ssh_command" {
  description = "Ready to paste SSH command."
  value       = "ssh ec2-user@${var.associate_eip ? aws_eip.this[0].public_ip : aws_instance.this.public_ip}"
}

output "session_manager_command" {
  description = "Fallback shell that does not depend on port 22 or on your source address."
  value       = "aws ssm start-session --target ${aws_instance.this.id} --region ${var.region}"
}

output "ssh_config_block" {
  description = "Block to append to ~/.ssh/config so the instance is reachable by name."
  value       = <<-EOT
    Host ${var.name}
      HostName ${var.associate_eip ? aws_eip.this[0].public_ip : aws_instance.this.public_ip}
      User ec2-user
      IdentityFile ~/.ssh/id_ed25519
      IdentitiesOnly yes
      ServerAliveInterval 30
      ServerAliveCountMax 6
  EOT
}

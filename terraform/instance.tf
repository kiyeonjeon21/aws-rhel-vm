# Red Hat does not publish public SSM parameters for RHEL the way Amazon Linux
# and Windows do, so the AMI is resolved by searching Red Hat's own account.
# 309956199498 is Red Hat's AWS account ID; pinning the owner is what stops a
# name-pattern match from picking up somebody else's lookalike image.
data "aws_ami" "rhel" {
  most_recent = true
  owners      = ["309956199498"]

  filter {
    name = "name"
    # Hourly2 is the licence-included billing variant, which is what you want
    # unless you have brought your own subscription through Red Hat Cloud
    # Access. GP3 is the newer root volume type.
    values = ["RHEL-${var.rhel_version}.*_HVM-*-x86_64-*-Hourly2-GP3"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.rhel.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.instance.name

  # The idle watchdog stops the box with an OS-level shutdown, so the shutdown
  # must stop the instance rather than terminate it.
  instance_initiated_shutdown_behavior = "stop"

  # First boot only. Editing the template afterwards does not re-run it; SSH in
  # and run bootstrap/setup.sh by hand, or rebuild the instance with
  # `terraform apply -replace=aws_instance.this`.
  user_data_replace_on_change = false

  user_data = templatefile("${path.module}/../bootstrap/cloud-init.yaml.tftpl", {
    ssh_public_key        = trimspace(var.ssh_public_key)
    region                = var.region
    ssm_prefix            = local.ssm_prefix
    idle_shutdown_minutes = var.idle_shutdown_minutes
    idle_load_threshold   = var.idle_shutdown_load_threshold
    setup_repo_url        = var.setup_repo_url
    setup_ref             = var.setup_ref
  })

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size
    encrypted             = true
    delete_on_termination = true

    tags = { Name = var.name }
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tags = { Name = var.name }

  lifecycle {
    # Red Hat ships a new RHEL AMI most months. Without this, an unrelated
    # apply would destroy the box and everything on its disk just because a
    # newer image appeared. Move to a newer AMI deliberately instead, with
    # `terraform apply -replace=aws_instance.this`.
    ignore_changes = [ami]
  }
}

resource "aws_eip" "this" {
  count = var.associate_eip ? 1 : 0

  domain   = "vpc"
  instance = aws_instance.this.id

  tags = { Name = var.name }

  depends_on = [aws_internet_gateway.this]
}

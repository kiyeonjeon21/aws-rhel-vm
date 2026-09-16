variable "name" {
  description = "Name prefix applied to every resource, and the value of the EC2 Name tag. The `vm` CLI locates the instance by this tag."
  type        = string
  default     = "rhelvm"
}

variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "Instance type. c6i.xlarge is 4 vCPU / 8 GiB, which is enough to build bundles and run a container or two."
  type        = string
  default     = "c6i.xlarge"
}

variable "rhel_version" {
  description = <<-EOT
    RHEL version to resolve an AMI for. A major version alone ("9") takes the
    most recently published RHEL 9 image; a point release ("9.8") pins that
    release.

    Prefer the point release. `most_recent` picks by publication date, not by
    version number, and Red Hat rebuilds older point releases, so asking for
    "9" can hand you 9.6 while 9.8 exists. Check the ami_name output after an
    apply to see which one you actually got.
  EOT
  type        = string
  default     = "9"

  validation {
    condition     = can(regex("^(9|10)(\\.[0-9]+)?$", var.rhel_version))
    error_message = "Use a major version like 9, or a point release like 9.8. Only RHEL 9 and 10 are wired up here."
  }
}

variable "root_volume_size" {
  description = "Root EBS volume size in GiB. RHEL itself is small, but container images and bundle staging are not."
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_size >= 20
    error_message = "Leave at least 20 GiB so a bundle build does not run the disk out."
  }
}

variable "ssh_public_key" {
  description = "OpenSSH public key authorised for the ec2-user account. Paste the contents of a .pub file."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ", var.ssh_public_key))
    error_message = "Expected an OpenSSH public key line, for example the contents of ~/.ssh/id_ed25519.pub."
  }
}

variable "allowed_cidrs" {
  description = "Source CIDRs allowed to reach SSH. Keep this to your own address. `vm allow-ip` rewrites it to your current address without a terraform run."
  type        = list(string)

  validation {
    condition     = !contains(var.allowed_cidrs, "0.0.0.0/0")
    error_message = "Refusing to expose SSH to the whole internet. Use your own address, or reach the host through Session Manager instead."
  }
}

variable "associate_eip" {
  description = "Attach an Elastic IP so the address survives stop/start. Costs about USD 3.60 per month, and saves rewriting ~/.ssh/config after every restart."
  type        = bool
  default     = true
}

variable "idle_shutdown_minutes" {
  description = "Stop the instance after this many consecutive idle minutes. Idle means no SSH or Session Manager session and low CPU. Set to 0 to disable."
  type        = number
  default     = 30
}

variable "idle_shutdown_load_threshold" {
  description = "One minute load average above which the host counts as busy even with no session attached, so a long build started over SSH is not killed after you disconnect. Compared against load per core."
  type        = number
  default     = 0.4
}

variable "idle_backstop_hours" {
  description = "Stop the instance after this many hours of low CPU, regardless of what the in-guest watchdog is doing. This is a backstop for the watchdog failing silently, not the normal mechanism, so keep it well above idle_shutdown_minutes. Set to 0 to disable."
  type        = number
  default     = 2
}

variable "idle_backstop_cpu_threshold" {
  description = "CPU percentage below which the backstop alarm counts a period as idle."
  type        = number
  default     = 5
}

variable "setup_repo_url" {
  description = "HTTPS URL of this repository. The instance clones it at first boot and runs bootstrap/setup.sh from it."
  type        = string
}

variable "setup_ref" {
  description = "Branch or tag of setup_repo_url to clone."
  type        = string
  default     = "main"
}

variable "vpc_cidr" {
  description = "CIDR for the dedicated VPC."
  type        = string
  default     = "10.30.0.0/16"
}

variable "budget_alert_email" {
  description = "Address to email when account spend crosses the thresholds below. Empty disables the budget entirely."
  type        = string
  default     = ""
}

variable "budget_monthly_limit" {
  description = "Monthly account spend in USD that the alerts are measured against."
  type        = number
  default     = 50
}

variable "tags" {
  description = "Extra tags merged into the provider default tags."
  type        = map(string)
  default     = {}
}

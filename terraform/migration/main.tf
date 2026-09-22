# Separate state: never rename/replace the existing production instance in its state.
terraform {
  required_version = ">= 1.5.0"
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/orca-lightsail-tokyo.pub"
}

variable "phase" {
  type    = string
  default = "final"
}

variable "allocate_static_ip" {
  type    = bool
  default = false
}

module "host" {
  source = "../"

  instance_name        = "orca-host-tokyo-v2"
  key_pair_name        = "orca-host-tokyo-v2-key"
  static_ip_name       = "orca-host-tokyo-v2-ip"
  allocate_static_ip   = var.allocate_static_ip
  region               = "ap-northeast-1"
  availability_zone    = "ap-northeast-1a"
  bundle_id            = "medium_3_0"
  blueprint_id         = "ubuntu_24_04"
  ssh_public_key_path  = var.ssh_public_key_path
  phase                = var.phase
  enable_public_web    = true
  enable_auto_snapshot = true
  auto_snapshot_time   = "19:00"
}

output "static_ip" {
  value = module.host.static_ip
}
output "instance_name" {
  value = module.host.instance_name
}
output "ssh_command" {
  value = module.host.ssh_command
}
output "auto_snapshot_time_utc" {
  value = module.host.auto_snapshot_time_utc
}
output "region" {
  value = module.host.region
}
output "availability_zone" {
  value = module.host.availability_zone
}
output "public_web_enabled" {
  value = module.host.public_web_enabled
}

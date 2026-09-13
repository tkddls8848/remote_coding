locals {
  static_ip_name = var.static_ip_name != "" ? var.static_ip_name : "${var.instance_name}-ip"
}

# public_key 는 OpenSSH 공개키 원문을 그대로 받는다 (base64 로 다시 감싸지 않는다).
resource "aws_lightsail_key_pair" "orca" {
  name       = var.key_pair_name
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_lightsail_instance" "orca" {
  name              = var.instance_name
  availability_zone = "${var.region}a"
  blueprint_id      = var.blueprint_id
  bundle_id         = var.bundle_id
  key_pair_name     = aws_lightsail_key_pair.orca.name

  dynamic "add_on" {
    for_each = var.enable_auto_snapshot ? [1] : []

    content {
      type          = "AutoSnapshot"
      snapshot_time = var.auto_snapshot_time
      status        = "Enabled"
    }
  }

  tags = {
    project = var.instance_name
  }
}

resource "aws_lightsail_static_ip" "orca" {
  name = local.static_ip_name
}

resource "aws_lightsail_static_ip_attachment" "orca" {
  static_ip_name = aws_lightsail_static_ip.orca.name
  instance_name  = aws_lightsail_instance.orca.name
}

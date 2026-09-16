locals {
  # 이름 규칙: 인스턴스 이름이 고정 IP·키페어 이름의 접두사다.
  static_ip_name    = var.static_ip_name != "" ? var.static_ip_name : "${var.instance_name}-ip"
  availability_zone = var.availability_zone != "" ? var.availability_zone : "${var.region}a"
}

# public_key 는 OpenSSH 공개키 원문을 그대로 받는다 (base64 로 다시 감싸지 않는다).
resource "aws_lightsail_key_pair" "orca" {
  name       = var.key_pair_name
  public_key = file(pathexpand(var.ssh_public_key_path))
}

# 이 인스턴스 한 대에 Orca 와 입주 앱(/srv/<앱>)이 함께 산다. 인스턴스·고정 IP·
# 키페어·공인 방화벽·자동 스냅샷은 이 모듈이 유일한 소유자이며, 입주 앱 저장소는
# 같은 자원을 선언하지 않는다 — 두 벌이 되면 나중에 apply 한 쪽이 상대의 규칙을
# 덮는다. 앱이 요구하는 호스트 값(공개 웹, 스냅샷 시각)은 변수로만 받는다.
resource "aws_lightsail_instance" "orca" {
  name              = var.instance_name
  availability_zone = local.availability_zone
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
}

resource "aws_lightsail_static_ip" "orca" {
  name = local.static_ip_name
}

resource "aws_lightsail_static_ip_attachment" "orca" {
  static_ip_name = aws_lightsail_static_ip.orca.name
  instance_name  = aws_lightsail_instance.orca.name
}

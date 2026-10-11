# 그림 생성 전용 GPU 서버 한 대.
#
#   관리 PC (게임 도구 · Claude Code) ── Tailscale ──> ComfyUI :8188 (tailscale0 에서만 듣는다)
#   관리 PC SSH ── 공인 IP /32 ──> 설치·복구용 ubuntu 계정
#
# ComfyUI 포트는 공인 방화벽(보안 그룹)에 열지 않는다. ComfyUI 에는 인증이 없어서, 열면
# 아무나 GPU 를 쓰고 서버 파일을 올릴 수 있다.
#
# 필요할 때만 켠다. scripts/gpu.sh start|stop 이 켜고 끄며, 서버 안의 유휴 타이머
# (install/05-idle-stop.sh) 가 오래 놀면 스스로 끈다. 꺼져 있는 동안은 디스크 값만 낸다.

# --- SSH 허용 대상 (최상위 terraform/firewall.tf 와 같은 규칙) -----------------
data "http" "my_ip" {
  count = (var.my_ip == "" && length(var.admin_cidrs) == 0) ? 1 : 0
  url   = "https://checkip.amazonaws.com"

  retry {
    attempts     = 3
    min_delay_ms = 1000
  }

  lifecycle {
    postcondition {
      condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", chomp(self.response_body)))
      error_message = <<-EOT
        checkip.amazonaws.com 이 IPv4 주소를 돌려주지 않았다.
        terraform.tfvars 에 my_ip 를 직접 적고 다시 실행한다:
          my_ip = "203.0.113.10"
      EOT
    }
  }
}

# --- 이 리전에서 instance_type 을 파는 AZ ---------------------------------------
# GPU 인스턴스는 리전 안에서도 일부 AZ 에만 있다. 없는 AZ 를 고르면 apply 중간에
# Unsupported 로 멈추므로 plan 단계에서 미리 고른다.
data "aws_ec2_instance_type_offerings" "gpu" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.instance_type]
  }
}

locals {
  detected_ip = length(data.http.my_ip) > 0 ? chomp(data.http.my_ip[0].response_body) : ""
  ssh_cidrs = length(var.admin_cidrs) > 0 ? var.admin_cidrs : (
    var.my_ip != "" ? ["${var.my_ip}/32"] : ["${local.detected_ip}/32"]
  )

  offered_azs       = sort(tolist(data.aws_ec2_instance_type_offerings.gpu.locations))
  availability_zone = var.availability_zone != "" ? var.availability_zone : try(local.offered_azs[0], "")
}

# --- AMI: NVIDIA 드라이버가 들어 있는 AWS Deep Learning Base AMI ------------------
data "aws_ami" "gpu" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = [var.ami_name_pattern]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# --- 네트워크: 기본 VPC 의 기본 서브넷 -------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnet" "gpu" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = local.availability_zone
  default_for_az    = true
}

resource "aws_security_group" "gpu" {
  name        = "${var.instance_name}-sg"
  description = "art GPU host: SSH from admin only. ComfyUI is reachable over Tailscale only."
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH (admin)"
    protocol    = "tcp"
    from_port   = 22
    to_port     = 22
    cidr_blocks = local.ssh_cidrs
  }

  # 모델 받기(Hugging Face · GitHub · PyPI)와 Tailscale 연결에 바깥으로 나가는 길이 필요하다.
  egress {
    description = "all outbound"
    protocol    = "-1"
    from_port   = 0
    to_port     = 0
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.instance_name}-sg" }
}

resource "aws_key_pair" "gpu" {
  key_name   = var.key_pair_name
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_instance" "gpu" {
  ami                         = data.aws_ami.gpu.id
  instance_type               = var.instance_type
  subnet_id                   = data.aws_subnet.gpu.id
  vpc_security_group_ids      = [aws_security_group.gpu.id]
  key_name                    = aws_key_pair.gpu.key_name
  associate_public_ip_address = true

  # 서버 안에서 poweroff 하면(유휴 타이머) 지워지지 않고 '중지'된다. 디스크와 설치는 남는다.
  instance_initiated_shutdown_behavior = "stop"

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []

    content {
      market_type = "spot"

      spot_options {
        spot_instance_type             = "persistent"
        instance_interruption_behavior = "stop"
        max_price                      = var.spot_max_price != "" ? var.spot_max_price : null
      }
    }
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
  }

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  tags = { Name = var.instance_name }

  lifecycle {
    # AWS 가 새 AMI 를 내도 이 서버를 갈아엎지 않는다. 새 AMI 로 바꾸려면
    # terraform apply -replace=aws_instance.gpu 를 명시적으로 쓴다(설치를 다시 해야 한다).
    ignore_changes = [ami]

    precondition {
      condition     = local.availability_zone != "" && contains(local.offered_azs, local.availability_zone)
      error_message = <<-EOT
        ${var.region} 에서 ${var.instance_type} 을 파는 AZ 가 없거나, 지정한 availability_zone 에 없다.
        (이 리전에서 파는 AZ: ${join(", ", local.offered_azs)})
        다른 리전(region)이나 다른 종류(g5.2xlarge, g4dn.2xlarge)를 고른다.
      EOT
    }
  }
}

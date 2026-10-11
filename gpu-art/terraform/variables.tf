variable "region" {
  description = "EC2 리전. GPU 종류마다 파는 리전이 다르다 — main.tf 가 이 리전에서 instance_type 을 파는 AZ 를 찾는다."
  type        = string
  default     = "ap-northeast-1"
}

variable "availability_zone" {
  description = "AZ. 비우면 instance_type 을 파는 AZ 중 첫 번째를 고른다."
  type        = string
  default     = ""

  validation {
    condition     = var.availability_zone == "" || can(regex("^[a-z]{2}-[a-z]+-[0-9][a-z]$", var.availability_zone))
    error_message = "availability_zone 은 비우거나 ap-northeast-1a 형식이어야 한다."
  }
}

variable "instance_name" {
  description = "인스턴스 이름. Tailscale 호스트명 기본값도 이 이름이다."
  type        = string
  default     = "art-gpu-tokyo"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.instance_name))
    error_message = "instance_name 은 소문자·숫자·하이픈만 쓴다 (Tailscale 호스트명으로도 쓰인다)."
  }
}

variable "instance_type" {
  description = <<-EOT
    GPU 인스턴스 종류. 기준은 Qwen-Image-Edit-2511 (GGUF) 을 ComfyUI 로 돌리는 것이다.
      g6.2xlarge   L4 24GB · 8 vCPU · 32GB RAM   (기본, 권장)
      g5.2xlarge   A10G 24GB · 8 vCPU · 32GB RAM (더 빠르고 더 비싸다)
      g4dn.2xlarge T4 16GB · 8 vCPU · 32GB RAM   (최소)
    RAM 16GB 짜리(*.xlarge)는 모델을 올리다 멈춘다 — 노트북에서 ComfyUI 가 RAM 을 약 23GB 썼다.
  EOT
  type        = string
  default     = "g6.2xlarge"

  validation {
    condition     = can(regex("^(g4dn|g5|g6|g6e)\\.[0-9]+xlarge$", var.instance_type))
    error_message = "instance_type 은 g4dn/g5/g6/g6e 의 2xlarge 이상이어야 한다 (RAM 32GB 이상)."
  }
}

variable "root_volume_gb" {
  description = "루트 디스크(gp3). OS·드라이버(AMI 자체가 크다) + ComfyUI + 모델(약 17GB) + 결과물."
  type        = number
  default     = 100

  validation {
    condition     = var.root_volume_gb >= 100
    error_message = "root_volume_gb 는 100 이상이어야 한다 (Deep Learning AMI 만으로 수십 GB 를 쓴다)."
  }
}

variable "ami_name_pattern" {
  description = <<-EOT
    AMI 이름 패턴. 기본은 AWS 가 NVIDIA 드라이버를 넣어 둔 Deep Learning Base AMI 다.
    이 패턴으로 찾지 못하면 (리전에 없거나 이름이 바뀐 경우) 22.04 판을 쓴다:
      ami_name_pattern = "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) *"
    확인: aws ec2 describe-images --owners amazon --filters "Name=name,Values=Deep Learning Base OSS Nvidia*" --query "Images[].Name"
  EOT
  type        = string
  default     = "Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 24.04) *"
}

variable "use_spot" {
  description = <<-EOT
    스팟 인스턴스로 띄운다. 값이 크게 싸지만 AWS 가 필요하면 회수한다(이 설정에서는 '중지' —
    디스크는 남는다). 회수되면 그리던 그림 한 장은 실패한다. 오래 이어 돌릴 때는 false 를 권한다.
  EOT
  type        = bool
  default     = false
}

variable "spot_max_price" {
  description = "스팟 최고가(달러/시간). 비우면 온디맨드 가격이 상한이다."
  type        = string
  default     = ""
}

variable "key_pair_name" {
  description = "EC2 키페어 이름"
  type        = string
  default     = "art-gpu-tokyo-key"
}

variable "ssh_public_key_path" {
  description = "등록할 OpenSSH 공개키 경로. ~ 는 홈 디렉터리로 풀린다."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "my_ip" {
  description = "SSH 를 허용할 내 공인 IP. 비우면 checkip.amazonaws.com 으로 자동 감지."
  type        = string
  default     = ""

  validation {
    condition     = var.my_ip == "" || can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", var.my_ip))
    error_message = "my_ip 는 비우거나 203.0.113.10 형식의 IPv4 주소여야 한다."
  }
}

variable "admin_cidrs" {
  description = "SSH(22) 를 허용할 CIDR 목록. 값이 있으면 my_ip 와 자동 감지보다 우선한다."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for c in var.admin_cidrs : can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}/[0-9]{1,2}$", c))
    ])
    error_message = "admin_cidrs 의 각 항목은 203.0.113.10/32 형식이어야 한다."
  }

  validation {
    condition     = !contains(var.admin_cidrs, "0.0.0.0/0")
    error_message = "admin_cidrs 에 0.0.0.0/0 은 둘 수 없다. SSH 를 인터넷 전체에 여는 것이다."
  }
}

variable "tags" {
  description = "모든 리소스에 붙일 기본 태그. Project 는 instance_name 으로 자동으로 채워진다."
  type        = map(string)
  default = {
    ManagedBy = "terraform"
    Role      = "art-gpu"
  }
}

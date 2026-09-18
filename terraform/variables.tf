variable "region" {
  description = "Lightsail 리전"
  type        = string
  default     = "ap-northeast-1"
}

variable "availability_zone" {
  description = "인스턴스 AZ. 비우면 <region>a 를 쓴다. region 하위여야 한다."
  type        = string
  default     = ""

  validation {
    condition     = var.availability_zone == "" || can(regex("^[a-z]{2}-[a-z]+-[0-9][a-z]$", var.availability_zone))
    error_message = "availability_zone 은 비우거나 ap-northeast-1a 형식이어야 한다."
  }
}

variable "instance_name" {
  description = "Lightsail 인스턴스 이름"
  type        = string
  default     = "orca-host-tokyo"
}

variable "bundle_id" {
  description = "요금제. Orca + 단일 코딩 에이전트 최소 권장값은 4GB medium_3_0"
  type        = string
  default     = "medium_3_0"
}

variable "blueprint_id" {
  description = "OS 이미지"
  type        = string
  default     = "ubuntu_24_04"
}

variable "key_pair_name" {
  description = "Lightsail에 등록할 키페어 이름. 같은 이름이 이미 있으면 다른 이름을 사용한다."
  type        = string
  default     = "orca-host-tokyo-key"
}

variable "ssh_public_key_path" {
  description = "Lightsail에 등록할 OpenSSH 공개키 경로. ~ 는 자동으로 홈 디렉터리로 풀린다."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "static_ip_name" {
  description = "고정 IP 이름. 비우면 <instance_name>-ip 를 쓴다."
  type        = string
  default     = ""
}

variable "phase" {
  description = <<-EOT
    방화벽 최종 상태.
      build = 22(내 IP만) — 호스트 구축
      final = 22(내 IP만) — 평상시 비상 관리

    Orca 6768은 인터넷에 열지 않는다. 브라우저는 Tailscale 사설망으로 접속한다.
  EOT
  type        = string
  default     = "final"

  validation {
    condition     = contains(["build", "final"], var.phase)
    error_message = "phase 는 \"build\" 또는 \"final\" 이어야 한다."
  }
}

variable "my_ip" {
  description = "SSH 를 허용할 내 공인 IP. 비우면 checkip.amazonaws.com 으로 자동 감지."
  type        = string
  default     = ""
}

variable "enable_public_web" {
  description = "이 호스트에 입주한 앱이 공개 웹을 서비스할 때만 HTTP/HTTPS(80/443)를 허용한다. 앱 내부 포트는 열지 않으며, 유효한 DNS와 리버스 프록시가 준비된 뒤에만 켠다."
  type        = bool
  default     = false
}

variable "enable_auto_snapshot" {
  description = "영속 앱 데이터 보호를 위한 Lightsail 일일 자동 스냅샷 활성화 여부."
  type        = bool
  default     = true
}

variable "auto_snapshot_time" {
  description = <<-EOT
    자동 스냅샷 시작 시각(UTC 정시). 기본 19:00 UTC는 04:00 KST/JST다.

    **입주 앱과의 계약.** 입주 앱은 자기 데이터 백업을 이 시각보다 앞에 끝내도록
    잡는다(현재 stock_chatbot 은 18:00 UTC). 호스트 타임존은 UTC 고정이므로
    (scripts/config.env 의 HOST_TIMEZONE) 앱의 cron 시각도 UTC 로 읽힌다.
    이 값을 바꾸면 입주 앱 저장소의 백업 시각도 함께 옮긴다.
  EOT
  type        = string
  default     = "19:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):00$", var.auto_snapshot_time))
    error_message = "auto_snapshot_time은 UTC 정시 HH:00 형식이어야 한다."
  }
}

variable "tags" {
  description = <<-EOT
    태그를 지원하는 모든 리소스에 붙일 기본 태그. provider 의 default_tags 로 들어가며
    Project 는 instance_name 으로 자동으로 채워진다. 고정 IP 처럼 태그 인자가 없는
    리소스에는 적용되지 않는다.
  EOT
  type        = map(string)
  default = {
    ManagedBy = "terraform"
  }
}

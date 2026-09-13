variable "region" {
  description = "Lightsail 리전"
  type        = string
  default     = "ap-northeast-1"
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
  description = "자동 스냅샷 시작 시각(UTC 정시). 기본 19:00 UTC는 04:00 KST/JST다."
  type        = string
  default     = "19:00"

  validation {
    condition     = can(regex("^([01][0-9]|2[0-3]):00$", var.auto_snapshot_time))
    error_message = "auto_snapshot_time은 UTC 정시 HH:00 형식이어야 한다."
  }
}

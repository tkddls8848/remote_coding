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

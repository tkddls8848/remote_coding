variable "region" {
  description = "Lightsail 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "instance_name" {
  description = "Lightsail 인스턴스 이름"
  type        = string
  default     = "orca-host"
}

variable "bundle_id" {
  description = "요금제. CLI + stock_chatbot 기본값은 2GB small_3_0"
  type        = string
  default     = "small_3_0"
}

variable "blueprint_id" {
  description = "OS 이미지"
  type        = string
  default     = "ubuntu_24_04"
}

variable "key_pair_name" {
  description = "Lightsail에 등록할 키페어 이름. 같은 이름이 이미 있으면 다른 이름을 사용한다."
  type        = string
  default     = "orca-host-key"
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
      build = 22(내 IP만) — 호스트 구축 및 SSH CLI 접속
      final = 22(내 IP만) — 평상시; CLI 전용 구성은 SSH를 계속 사용
  EOT
  type        = string
  default     = "final"

  validation {
    condition     = contains(["build", "final"], var.phase)
    error_message = "phase 는 \"build\" 또는 \"final\" 이어야 한다."
  }
}

variable "my_ip" {
  description = "구축 단계(phase=build)에서 SSH 를 허용할 내 공인 IP. 비우면 checkip.amazonaws.com 으로 자동 감지."
  type        = string
  default     = ""
}

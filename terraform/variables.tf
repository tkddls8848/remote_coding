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
  description = "요금제. 4GB = medium_3_0, 8GB 로 올릴 때는 large_3_0"
  type        = string
  default     = "medium_3_0"
}

variable "blueprint_id" {
  description = "OS 이미지"
  type        = string
  default     = "ubuntu_24_04"
}

variable "key_pair_name" {
  description = "Lightsail 키페어 이름. 이미 존재하면 terraform import 로 가져와 쓴다."
  type        = string
  default     = "orca-host-key"
}

variable "ssh_public_key_path" {
  description = "임포트할 공개키 경로. ~ 는 자동으로 홈 디렉터리로 풀린다."
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
      build = 22(내 IP만) + 80 + 443  — 구축 중, Let's Encrypt 인증서 발급에 80/443 필요
      final = 443만                   — 평상시
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

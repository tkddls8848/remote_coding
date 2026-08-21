output "static_ip" {
  description = "고정 IP 주소"
  value       = aws_lightsail_static_ip.orca.ip_address
}

output "instance_name" {
  description = "Lightsail 인스턴스 이름"
  value       = aws_lightsail_instance.orca.name
}

output "ssh_command" {
  description = "서버 접속 명령"
  value       = "ssh ubuntu@${aws_lightsail_static_ip.orca.ip_address}"
}

output "tmux_command" {
  description = "SSH로 접속해 개발 tmux 세션을 열거나 재접속하는 명령"
  value       = "ssh -t ubuntu@${aws_lightsail_static_ip.orca.ip_address} tmux new -As dev"
}

output "phase" {
  description = "현재 적용된 방화벽 단계"
  value       = var.phase
}

output "open_ports" {
  description = "현재 열려 있는 포트 목록"
  value       = [for p in local.ports : p.port]
}

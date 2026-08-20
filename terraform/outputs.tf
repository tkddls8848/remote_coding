output "static_ip" {
  description = "고정 IP 주소"
  value       = aws_lightsail_static_ip.orca.ip_address
}

output "ssh_command" {
  description = "서버 접속 명령"
  value       = "ssh ubuntu@${aws_lightsail_static_ip.orca.ip_address}"
}

output "web_url" {
  description = "도메인이 없을 때 쓰는 sslip.io 접속 주소 (443 이 열려 있을 때만 응답)"
  value       = "https://${aws_lightsail_static_ip.orca.ip_address}.sslip.io/web-index.html"
}

output "phase" {
  description = "현재 적용된 방화벽 단계"
  value       = var.phase
}

output "open_ports" {
  description = "현재 열려 있는 포트 목록"
  value       = [for p in local.ports : p.port]
}

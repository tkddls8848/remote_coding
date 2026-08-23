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

output "browser_access_command" {
  description = "SSH로 접속해 최신 Orca 브라우저 URL을 표시하는 명령"
  value       = "ssh ubuntu@${aws_lightsail_static_ip.orca.ip_address} 'sudo /home/ubuntu/remote-lightsail-scripts/util/show-orca-access.sh'"
}

output "phase" {
  description = "현재 적용된 방화벽 단계"
  value       = var.phase
}

output "open_ports" {
  description = "현재 열려 있는 포트 목록"
  value       = [for p in local.ports : p.port]
}

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

# --- 입주 앱 저장소가 읽는 계약 값 -------------------------------------------
# 입주 앱은 AWS 자원을 만들지 않으므로, 앱 쪽 설치·점검 스크립트와 문서가 맞춰야 할
# 호스트 값은 여기서 읽는다. (예: terraform -chdir=terraform output -raw auto_snapshot_time_utc)

output "region" {
  description = "Lightsail 리전"
  value       = var.region
}

output "availability_zone" {
  description = "인스턴스 AZ"
  value       = local.availability_zone
}

output "auto_snapshot_time_utc" {
  description = "자동 스냅샷 시각(UTC 정시). 입주 앱의 데이터 백업은 이보다 앞에 끝낸다."
  value       = var.enable_auto_snapshot ? var.auto_snapshot_time : ""
}

output "public_web_enabled" {
  description = "공인 방화벽에 80/443 이 열려 있는지. 입주 앱의 리버스 프록시는 이 값이 true 일 때만 의미가 있다."
  value       = var.enable_public_web
}

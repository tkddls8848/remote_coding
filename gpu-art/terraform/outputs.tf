output "instance_id" {
  description = "EC2 인스턴스 ID (scripts/gpu.sh 가 켜고 끌 때 쓴다)"
  value       = aws_instance.gpu.id
}

output "instance_name" {
  description = "인스턴스 이름 = Tailscale 호스트명 기본값"
  value       = var.instance_name
}

output "instance_type" {
  description = "GPU 인스턴스 종류"
  value       = var.instance_type
}

output "region" {
  description = "리전"
  value       = var.region
}

output "availability_zone" {
  description = "AZ"
  value       = local.availability_zone
}

output "public_ip" {
  description = "지금의 공인 IP. 고정 IP 를 쓰지 않으므로 중지했다 켜면 바뀐다 — 평소에는 Tailscale 이름으로 붙는다."
  value       = aws_instance.gpu.public_ip
}

output "ssh_command" {
  description = "설치·복구용 SSH 명령 (공인 IP 는 켤 때마다 바뀐다)"
  value       = "ssh ubuntu@${aws_instance.gpu.public_ip}"
}

output "ami_name" {
  description = "처음 만들 때 고른 AMI (이후 새 AMI 는 무시한다)"
  value       = data.aws_ami.gpu.name
}

output "market" {
  description = "spot 또는 on-demand"
  value       = var.use_spot ? "spot" : "on-demand"
}

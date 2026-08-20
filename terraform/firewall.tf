# put-instance-public-ports 는 규칙 전체를 교체하는 API 다.
# scripts/02-firewall-build.sh 와 07-firewall-final.sh 가 "최종 상태 전체"를
# 각각 따로 적어야 했던 이유이기도 하다. 여기서는 phase 변수 하나로 표현한다.

data "http" "my_ip" {
  count = var.my_ip == "" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  my_ip = var.my_ip != "" ? var.my_ip : chomp(data.http.my_ip[0].response_body)

  ports_build = {
    ssh   = { port = 22, cidrs = ["${local.my_ip}/32"] }
    http  = { port = 80, cidrs = ["0.0.0.0/0"] }
    https = { port = 443, cidrs = ["0.0.0.0/0"] }
  }
  ports_final = {
    https = { port = 443, cidrs = ["0.0.0.0/0"] }
  }
  ports = var.phase == "build" ? local.ports_build : local.ports_final
}

resource "aws_lightsail_instance_public_ports" "orca" {
  instance_name = aws_lightsail_instance.orca.name

  dynamic "port_info" {
    for_each = local.ports
    content {
      protocol  = "tcp"
      from_port = port_info.value.port
      to_port   = port_info.value.port
      cidrs     = port_info.value.cidrs
    }
  }
}

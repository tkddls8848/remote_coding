# put-instance-public-ports 는 규칙 전체를 교체하는 API 다.
# 공개 포트의 최종 상태 전체를 phase 변수 하나로 선언한다.

data "http" "my_ip" {
  count = var.my_ip == "" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  my_ip = var.my_ip != "" ? var.my_ip : chomp(data.http.my_ip[0].response_body)

  ports_build = {
    ssh = { port = 22, cidrs = ["${local.my_ip}/32"] }
  }
  ports_final = {
    ssh = { port = 22, cidrs = ["${local.my_ip}/32"] }
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

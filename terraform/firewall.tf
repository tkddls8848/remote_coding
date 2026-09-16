# put-instance-public-ports 는 규칙 전체를 교체하는 API 다.
# 공개 포트의 최종 상태 전체를 phase 변수 하나로 선언한다.
#
# 그래서 이 인스턴스의 공개 포트를 선언하는 곳은 이 파일 하나뿐이다. 입주 앱
# 저장소가 aws_lightsail_instance_public_ports 를 따로 두면 나중에 apply 한 쪽이
# 상대의 규칙을 통째로 지운다. 앱이 공개 웹을 서비스하려면 자기 저장소에서 포트를
# 여는 대신 여기 enable_public_web 을 켠다.

data "http" "my_ip" {
  count = var.my_ip == "" ? 1 : 0
  url   = "https://checkip.amazonaws.com"
}

locals {
  my_ip = var.my_ip != "" ? var.my_ip : chomp(data.http.my_ip[0].response_body)

  ports_build = {
    ssh = { port = 22, cidrs = ["${local.my_ip}/32"] }
  }
  ports_final = merge(
    {
      ssh = { port = 22, cidrs = ["${local.my_ip}/32"] }
    },
    var.enable_public_web ? {
      http  = { port = 80, cidrs = ["0.0.0.0/0"] }
      https = { port = 443, cidrs = ["0.0.0.0/0"] }
    } : {}
  )
  ports = var.phase == "build" ? local.ports_build : local.ports_final
}

# Orca의 6768과 입주 앱의 내부 포트는 의도적으로 여기에 없다.
# Orca는 Tailscale Serve를, 공개 웹은 리버스 프록시가 받는 80/443만 사용한다.

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

# put-instance-public-ports 는 규칙 전체를 교체하는 API 다.
# 공개 포트의 최종 상태 전체를 phase 변수 하나로 선언한다.
#
# 그래서 이 인스턴스의 공개 포트를 선언하는 곳은 이 파일 하나뿐이다. 입주 앱
# 저장소가 aws_lightsail_instance_public_ports 를 따로 두면 나중에 apply 한 쪽이
# 상대의 규칙을 통째로 지운다. 앱이 공개 웹을 서비스하려면 자기 저장소에서 포트를
# 여는 대신 여기 enable_public_web 을 켠다.

# 자동 감지는 checkip.amazonaws.com 하나에 의존한다. 그 서비스가 흔들리면 apply 자체가
# 실패하므로, 실패했을 때 무엇을 해야 하는지 에러 메시지에 적어 둔다
# (docs/stability-plan.md 4.1-4). admin_cidrs 나 my_ip 를 적어 두면 이 호출 자체가 없다.
data "http" "my_ip" {
  count = (var.my_ip == "" && length(var.admin_cidrs) == 0) ? 1 : 0
  url   = "https://checkip.amazonaws.com"

  retry {
    attempts     = 3
    min_delay_ms = 1000
  }

  lifecycle {
    postcondition {
      condition     = can(regex("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$", chomp(self.response_body)))
      error_message = <<-EOT
        checkip.amazonaws.com 이 IPv4 주소를 돌려주지 않았다.
        terraform.tfvars 에 my_ip 를 직접 적고 다시 실행한다:
          my_ip = "203.0.113.10"
        여러 위치에서 접속한다면 admin_cidrs 목록을 쓴다.
        현재 공인 IP 확인: curl https://checkip.amazonaws.com
      EOT
    }
  }
}

locals {
  # 우선순위: admin_cidrs (목록) > my_ip (/32) > 자동 감지 (/32)
  detected_ip = length(data.http.my_ip) > 0 ? chomp(data.http.my_ip[0].response_body) : ""
  ssh_cidrs = length(var.admin_cidrs) > 0 ? var.admin_cidrs : (
    var.my_ip != "" ? ["${var.my_ip}/32"] : ["${local.detected_ip}/32"]
  )

  ports_build = {
    ssh = { port = 22, cidrs = local.ssh_cidrs }
  }
  ports_final = merge(
    {
      ssh = { port = 22, cidrs = local.ssh_cidrs }
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

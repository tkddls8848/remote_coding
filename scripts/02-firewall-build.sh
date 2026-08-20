#!/usr/bin/env bash
# Phase 2 — 구축 단계 방화벽.
#
#   실행 위치: 로컬
#   결과 상태: 22(내 IP 에서만) + 80 + 443
#
# 80/443 을 여는 이유: Phase 6 에서 Let's Encrypt 인증서를 발급받으려면
# ACME 챌린지(HTTP-01 은 80, TLS-ALPN-01 은 443)가 인터넷에서 도달해야 한다.
# 발급이 끝나면 07 이 443 하나만 남기고 전부 닫는다.
#
# put-instance-public-ports 는 기존 규칙을 통째로 교체한다.
# 그래서 매번 "최종 상태 전체"를 적는다.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_aws
need curl

instance_exists || die "인스턴스 $INSTANCE_NAME 가 없다. 01 을 먼저 실행할 것."

ip="$(detect_my_ip)"
[ -n "$ip" ] || die "내 공인 IP 를 확인하지 못했다. config.env 에 MY_IP 를 직접 적을 것."
say "SSH 허용 대상: $ip/32"

aws lightsail put-instance-public-ports --region "$REGION" --instance-name "$INSTANCE_NAME" \
    --port-infos \
        "fromPort=22,toPort=22,protocol=TCP,cidrs=$ip/32" \
        "fromPort=80,toPort=80,protocol=TCP" \
        "fromPort=443,toPort=443,protocol=TCP" >/dev/null

ok "방화벽 갱신"
aws lightsail get-instance-port-states --region "$REGION" --instance-name "$INSTANCE_NAME" \
    --query 'portStates[].{port:fromPort,proto:protocol,cidrs:cidrs}' --output table

cat <<TXT

가정용 회선은 공인 IP 가 바뀔 수 있다. 바뀌어서 SSH 가 막히면
Lightsail 콘솔의 브라우저 SSH 로 들어가거나, 이 스크립트를 다시 실행하면 된다.

다음: 호스트 스크립트를 서버로 올린다
  ./scripts/sync-host.sh
TXT

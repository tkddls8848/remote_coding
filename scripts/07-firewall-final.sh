#!/usr/bin/env bash
# Phase 7 — 최종 방화벽: 443 하나만 남긴다.
#
#   실행 위치: 로컬
#   전제: Phase 6 에서 인증서 발급이 이미 끝났을 것 (journalctl -u caddy 로 확인)
#
# 실행 후에는 SSH 가 닫힌다. 서버 접속은 Lightsail 콘솔의 브라우저 SSH 를 쓴다.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_aws
instance_exists || die "인스턴스 $INSTANCE_NAME 가 없다."

host="$(resolve_host)"
say "https://$host 가 이미 정상 응답하는지 먼저 확인한다"
if curl -fsS -o /dev/null -w '%{http_code}\n' --max-time 15 "https://$host/web-index.html" 2>/dev/null | grep -q '^200$'; then
    ok "인증서·프록시 정상"
else
    warn "https://$host/web-index.html 가 200 이 아니다."
    warn "지금 443 만 남기면 복구 경로가 브라우저 SSH 콘솔뿐이다."
    confirm "그래도 진행할까?"
fi

confirm "SSH(22) 와 80 을 닫고 443 만 남긴다. 진행할까?"

aws lightsail put-instance-public-ports --region "$REGION" --instance-name "$INSTANCE_NAME" \
    --port-infos "fromPort=443,toPort=443,protocol=TCP" >/dev/null

ok "443 만 개방"
aws lightsail get-instance-port-states --region "$REGION" --instance-name "$INSTANCE_NAME" \
    --query 'portStates[].{port:fromPort,proto:protocol,cidrs:cidrs}' --output table

cat <<TXT

이후 서버 접속은 Lightsail 콘솔의 브라우저 SSH 를 쓴다.
다시 SSH 를 열어야 하면: ./scripts/02-firewall-build.sh
TXT

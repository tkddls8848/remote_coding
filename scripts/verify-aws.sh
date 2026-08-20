#!/usr/bin/env bash
# 로컬 쪽 점검 — 인스턴스 상태와 방화벽.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set +e

require_aws || exit 1

say "인스턴스"
aws lightsail get-instance --region "$REGION" --instance-name "$INSTANCE_NAME" \
    --query 'instance.{name:name,state:state.name,bundle:bundleId,ip:publicIpAddress}' \
    --output table

say "개방 포트"
aws lightsail get-instance-port-states --region "$REGION" --instance-name "$INSTANCE_NAME" \
    --query 'portStates[?state==`open`].{port:fromPort,proto:protocol,cidrs:cidrs}' --output table

open_ports=$(aws lightsail get-instance-port-states --region "$REGION" --instance-name "$INSTANCE_NAME" \
    --query 'portStates[?state==`open`].fromPort' --output text | tr '\t' '\n' | sort -n | tr '\n' ' ')
if [ "$(echo "$open_ports" | tr -d ' ')" = "443" ]; then
    ok "인바운드 443 하나만 열려 있다 (완료 조건 충족)"
else
    warn "열린 포트: $open_ports — 최종 상태는 443 하나여야 한다 (07 미실행?)"
fi

host="$(resolve_host 2>/dev/null)"
if [ -n "$host" ]; then
    code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "https://$host/web-index.html" 2>/dev/null)
    [ "$code" = "200" ] && ok "https://$host/web-index.html → 200" \
                        || warn "https://$host/web-index.html → ${code:-응답 없음}"
fi

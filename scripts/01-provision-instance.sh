#!/usr/bin/env bash
# Phase 1 — Lightsail 인스턴스 + 고정 IP 생성.
#
#   실행 위치: 로컬 (AWS 자격증명이 있는 곳)
#   ⚠ 이 스크립트가 성공하는 시점부터 과금이 시작된다 (4GB 번들 $24/mo 정액).
#
# 이미 만들어진 자원은 건너뛴다. 여러 번 실행해도 안전하다.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

require_aws
need curl

say "대상: $INSTANCE_NAME ($BUNDLE_ID / $BLUEPRINT_ID) @ $REGION"

# --- 키페어 -----------------------------------------------------------------
if aws lightsail get-key-pair --region "$REGION" --key-pair-name "$KEY_PAIR_NAME" >/dev/null 2>&1; then
    ok "키페어 $KEY_PAIR_NAME 이미 존재"
else
    key_path="${SSH_PUBLIC_KEY/#\~/$HOME}"
    [ -f "$key_path" ] || die "공개키를 찾을 수 없다: $key_path (SSH_PUBLIC_KEY 를 설정할 것)"
    say "공개키 임포트: $key_path"
    aws lightsail import-key-pair --region "$REGION" \
        --key-pair-name "$KEY_PAIR_NAME" \
        --public-key-base64 "$(base64 -w0 "$key_path")" >/dev/null
    ok "키페어 $KEY_PAIR_NAME 생성"
fi

# --- 인스턴스 ---------------------------------------------------------------
if instance_exists; then
    ok "인스턴스 $INSTANCE_NAME 이미 존재"
else
    warn "여기서부터 과금이 시작된다: $BUNDLE_ID 정액 요금."
    confirm "인스턴스 $INSTANCE_NAME 을 $REGION 에 생성한다. 진행할까?"
    aws lightsail create-instances --region "$REGION" \
        --instance-names "$INSTANCE_NAME" \
        --availability-zone "${REGION}a" \
        --blueprint-id "$BLUEPRINT_ID" \
        --bundle-id "$BUNDLE_ID" \
        --key-pair-name "$KEY_PAIR_NAME" \
        --tags key=project,value=orca-host >/dev/null
    ok "생성 요청 전송"
fi

say "running 상태 대기"
for _ in $(seq 1 60); do
    state=$(aws lightsail get-instance --region "$REGION" --instance-name "$INSTANCE_NAME" \
        --query 'instance.state.name' --output text 2>/dev/null || echo pending)
    [ "$state" = "running" ] && break
    sleep 5
done
[ "${state:-}" = "running" ] || die "인스턴스가 running 이 되지 않았다 (현재: ${state:-unknown})"
ok "running"

# --- 고정 IP ----------------------------------------------------------------
if aws lightsail get-static-ip --region "$REGION" --static-ip-name "$STATIC_IP_NAME" >/dev/null 2>&1; then
    ok "고정 IP $STATIC_IP_NAME 이미 할당됨"
else
    aws lightsail allocate-static-ip --region "$REGION" --static-ip-name "$STATIC_IP_NAME" >/dev/null
    ok "고정 IP $STATIC_IP_NAME 할당"
fi

attached=$(aws lightsail get-static-ip --region "$REGION" --static-ip-name "$STATIC_IP_NAME" \
    --query 'staticIp.attachedTo' --output text)
if [ "$attached" = "$INSTANCE_NAME" ]; then
    ok "이미 $INSTANCE_NAME 에 부착됨"
else
    aws lightsail attach-static-ip --region "$REGION" \
        --static-ip-name "$STATIC_IP_NAME" --instance-name "$INSTANCE_NAME" >/dev/null
    ok "부착 완료"
fi

STATIC_IP="$(static_ip_address)"
export STATIC_IP

say "고정 IP: $STATIC_IP"
say "접속 호스트명: $(resolve_host)"
cat <<TXT

다음:
  1) 도메인을 쓴다면 A 레코드를 $STATIC_IP 로 지정하고 config.env 의 DOMAIN 을 채운다.
     (도메인이 없으면 그대로 $STATIC_IP.sslip.io 를 쓴다 — 별도 설정 없음)
  2) ./scripts/02-firewall-build.sh   # SSH 를 내 IP 로만 좁힌다
TXT

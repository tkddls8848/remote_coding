#!/usr/bin/env bash
# 호스트 설정 4/6 — Caddy로 HTTPS/WSS 종단, 127.0.0.1:$ORCA_PORT로 리버스 프록시.
#
#   실행 위치: 서버
#
# Orca 런타임은 평문 WebSocket 이다. 브라우저는 HTTPS 페이지에서 평문 ws 로 붙는 것을
# 막기 때문에, 브라우저 접속을 지원하려면 wss 종단이 반드시 필요하다.
#
# 선택: BASIC_AUTH_USER 를 지정하면 페어링 토큰 앞에 인증을 한 겹 더 둔다.
#   BASIC_AUTH_USER=me BASIC_AUTH_HASH='$2a$14$...' ./04-caddy.sh
#   (해시는 `caddy hash-password` 로 만든다. 평문 비밀번호를 넣지 않는다.)

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export DEBIAN_FRONTEND=noninteractive
[ -n "$DOMAIN" ] || die "DOMAIN 이 비어 있다. ~/orca-host.env 를 확인할 것."

if command -v caddy >/dev/null 2>&1; then
    ok "caddy 이미 설치됨"
else
    say "Caddy 설치"
    sudo apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        | sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq caddy
    ok "설치 완료"
fi

auth_block=""
if [ -n "${BASIC_AUTH_USER:-}" ]; then
    [ -n "${BASIC_AUTH_HASH:-}" ] || die "BASIC_AUTH_USER 를 줬으면 BASIC_AUTH_HASH 도 필요하다 (caddy hash-password)."
    auth_block=$'\n    basic_auth {\n        '"$BASIC_AUTH_USER $BASIC_AUTH_HASH"$'\n    }\n'
    say "basic_auth 를 함께 설정한다"
fi

sudo tee /etc/caddy/Caddyfile >/dev/null <<CADDY
$DOMAIN {
    encode zstd gzip
$auth_block
    reverse_proxy 127.0.0.1:$ORCA_PORT
}
CADDY

sudo caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1 \
    || die "Caddyfile 검증 실패. /etc/caddy/Caddyfile 을 확인할 것."

sudo systemctl enable caddy >/dev/null 2>&1 || true
sudo systemctl reload caddy 2>/dev/null || sudo systemctl restart caddy

say "인증서 발급 대기 (최대 90초)"
code=""
for _ in $(seq 1 45); do
    code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 5 "https://$DOMAIN/web-index.html" 2>/dev/null || true)
    [ "$code" = "200" ] && break
    sleep 2
done

if [ "$code" = "200" ]; then
    ok "https://$DOMAIN/web-index.html → 200"
else
    warn "아직 200 이 아니다 (마지막 응답: ${code:-없음})."
    warn "발급 로그: journalctl -u caddy -n 50 --no-pager"
    warn "도메인 A 레코드가 이 서버를 가리키는지, 80/443 이 열려 있는지 확인할 것."
fi

say "다음: ./verify-host.sh"

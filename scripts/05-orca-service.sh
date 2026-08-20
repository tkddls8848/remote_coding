#!/usr/bin/env bash
# Phase 5 — Orca 런타임을 systemd 서비스로 등록한다.
#
#   실행 위치: 서버
#   전제: 04 가 성공했을 것 (헤드리스 기동 검증 통과)

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ -n "$DOMAIN" ] || die "DOMAIN 이 비어 있다. ~/orca-host.env 를 확인할 것."
command -v orca >/dev/null 2>&1 || die "orca 가 없다. 04 를 먼저 실행할 것."

# 04 가 남긴 판정을 그대로 따른다.
if [ -f "$HOME/.orca-needs-xvfb" ]; then
    EXEC="/usr/bin/xvfb-run -a /usr/bin/orca serve --port $ORCA_PORT --pairing-address wss://$DOMAIN"
    say "xvfb-run 으로 감싼다 (04 검증 결과)"
else
    EXEC="/usr/bin/orca serve --port $ORCA_PORT --pairing-address wss://$DOMAIN"
fi

# --pairing-address 는 클라이언트에게 광고할 주소만 바꾼다.
# 실제 바인딩은 로컬 $ORCA_PORT 그대로이고, 외부에서 직접 붙는 경로는 Lightsail 방화벽이 막는다.
sudo tee /etc/systemd/system/orca-serve.service >/dev/null <<UNIT
[Unit]
Description=Orca headless runtime
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Environment=HOME=/home/ubuntu
ExecStart=$EXEC
Restart=always
RestartSec=5
# 4GB 박스에서 런타임이 메모리를 독점하지 않도록
MemoryMax=2G

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now orca-serve
sudo systemctl restart orca-serve

say "기동 대기"
for _ in $(seq 1 30); do
    curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$ORCA_PORT/web-index.html" && break
    sleep 1
done

systemctl is-active --quiet orca-serve || {
    journalctl -u orca-serve -n 40 --no-pager >&2
    die "orca-serve 가 active 가 아니다."
}
ok "orca-serve active (127.0.0.1:$ORCA_PORT)"

cat <<TXT

페어링 링크는 서비스 로그에 나온다:
  journalctl -u orca-serve -n 100 --no-pager

⚠ 페어링 링크는 비밀번호와 동급이다. 메신저·이슈·문서에 남기지 않는다.

다음: ./06-caddy.sh
TXT

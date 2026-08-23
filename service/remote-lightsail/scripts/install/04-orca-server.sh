#!/usr/bin/env bash
# 호스트 설정 4/5 — Orca AppImage, 전용 계정, systemd 상시 서비스.

. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

need curl
need file
need jq
need tailscale

[[ "$ORCA_PORT" =~ ^[0-9]+$ ]] || die "ORCA_PORT는 숫자여야 한다."
((ORCA_PORT >= 1024 && ORCA_PORT <= 65535)) || die "ORCA_PORT는 1024~65535 범위여야 한다."
[[ "$ORCA_SERVICE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "ORCA_SERVICE_USER 형식이 잘못되었다."

tailscale_ip="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$tailscale_ip" ] || die "Tailscale이 연결되지 않았다. 먼저 'sudo tailscale up'을 실행할 것."

# Orca Web은 crypto.randomUUID 등을 사용한다. Tailscale IP의 평문 HTTP로 열면 브라우저가
# Web Crypto를 제한해 root가 렌더링되지 않고 빈 화면만 보인다. 기본 구성은 Tailscale Serve가
# TLS를 종료하고 localhost의 Orca로 WebSocket/HTTP를 프록시하게 한다.
configure_tailscale_serve=0
if [ -z "$ORCA_PAIRING_ADDRESS" ]; then
    tailscale_dns="$(tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
    [ -n "$tailscale_dns" ] || die "Tailscale MagicDNS 이름을 찾지 못했다. tailnet에서 MagicDNS를 활성화할 것."
    ORCA_PAIRING_ADDRESS="https://${tailscale_dns}"
    configure_tailscale_serve=1
else
    case "$ORCA_PAIRING_ADDRESS" in
        https://*|wss://*) ;;
        *.ts.net|*.ts.net:*) ORCA_PAIRING_ADDRESS="https://${ORCA_PAIRING_ADDRESS}" ;;
        *) die "ORCA_PAIRING_ADDRESS는 HTTPS/WSS 주소여야 한다. 평문 HTTP/WS는 브라우저에서 빈 화면을 만든다." ;;
    esac
fi

if [ "$configure_tailscale_serve" -eq 1 ]; then
    say "Tailscale Serve HTTPS → Orca localhost:${ORCA_PORT}"
    if ! serve_output="$(sudo tailscale serve --bg "$ORCA_PORT" 2>&1)"; then
        printf '%s\n' "$serve_output" >&2
        die "Tailscale Serve 활성화가 필요하다. 출력된 승인 URL은 관리 PC 브라우저에서 연 뒤 이 스크립트를 다시 실행할 것."
    fi
    printf '%s\n' "$serve_output"
fi

case "$(uname -m)" in
    x86_64)
        asset="orca-linux.AppImage"
        machine_pattern='x86-64'
        ;;
    aarch64|arm64)
        asset="orca-linux-arm64.AppImage"
        machine_pattern='ARM aarch64'
        ;;
    *) die "지원하지 않는 아키텍처: $(uname -m)" ;;
esac

if ! id "$ORCA_SERVICE_USER" >/dev/null 2>&1; then
    say "Orca 전용 계정 생성: $ORCA_SERVICE_USER"
    sudo useradd --system --create-home --shell /usr/sbin/nologin "$ORCA_SERVICE_USER"
fi
ORCA_SERVICE_GROUP="$(id -gn "$ORCA_SERVICE_USER")"

sudo install -d -o root -g root -m 0755 /opt/orca
sudo install -d -o "$ORCA_SERVICE_USER" -g "$ORCA_SERVICE_GROUP" -m 0750 \
    "/home/$ORCA_SERVICE_USER/workspace"

download_url="https://github.com/stablyai/orca/releases/download/${ORCA_VERSION}/${asset}"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

say "Orca ${ORCA_VERSION} 내려받기"
curl -fL --retry 3 "$download_url" -o "$tmp"
file_info="$(LC_ALL=C file "$tmp")"
grep -q 'ELF .* executable' <<<"$file_info" || die "다운로드 파일이 ELF 실행 파일이 아니다: $file_info"
grep -Fq "$machine_pattern" <<<"$file_info" || die "다운로드 파일 아키텍처가 호스트와 다르다: $file_info"
sudo install -o root -g root -m 0755 "$tmp" /opt/orca/orca-linux.AppImage.new

had_previous=0
if sudo test -f /opt/orca/orca-linux.AppImage; then
    if sudo test -f /opt/orca/orca-linux.AppImage.previous; then
        die "이전 실패 시도의 보존 바이너리가 있다: /opt/orca/orca-linux.AppImage.previous
  재시도 전에 저널과 프로필 백업을 확인하고 수동 복구 또는 정리할 것."
    fi
    had_previous=1
    sudo cp -a /opt/orca/orca-linux.AppImage /opt/orca/orca-linux.AppImage.previous
    if sudo test -f /opt/orca/VERSION; then
        sudo cp -a /opt/orca/VERSION /opt/orca/VERSION.previous
    fi
    sudo systemctl stop orca-serve.service 2>/dev/null || true
fi
sudo mv -f /opt/orca/orca-linux.AppImage.new /opt/orca/orca-linux.AppImage
printf '%s\n' "$ORCA_VERSION" | sudo tee /opt/orca/VERSION >/dev/null
sudo chown root:root /opt/orca/VERSION
sudo chmod 0644 /opt/orca/VERSION

say "Orca 서비스 설정"
sudo install -d -o root -g "$ORCA_SERVICE_GROUP" -m 0750 /etc/orca
{
    printf 'ORCA_PORT=%q\n' "$ORCA_PORT"
    printf 'ORCA_PAIRING_ADDRESS=%q\n' "$ORCA_PAIRING_ADDRESS"
} | sudo tee /etc/orca/orca.env >/dev/null
sudo chown root:"$ORCA_SERVICE_GROUP" /etc/orca/orca.env
sudo chmod 0640 /etc/orca/orca.env

say "호스트 방화벽: SSH만 허용 (Orca는 Tailscale Serve가 localhost로 프록시)"
sudo ufw default deny incoming >/dev/null
sudo ufw default allow outgoing >/dev/null
sudo ufw allow 22/tcp comment 'SSH; outer Lightsail firewall restricts source' >/dev/null
# 이전 평문 HTTP 구성의 direct rule이 있으면 제거한다. HTTPS Serve는 이 규칙이 필요 없다.
sudo ufw delete allow in on tailscale0 to any port "$ORCA_PORT" proto tcp >/dev/null 2>&1 || true
sudo ufw --force enable >/dev/null

sudo tee /etc/systemd/system/orca-serve.service >/dev/null <<UNIT
[Unit]
Description=Orca headless coding agent runtime
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
User=$ORCA_SERVICE_USER
Group=$ORCA_SERVICE_GROUP
WorkingDirectory=/home/$ORCA_SERVICE_USER
EnvironmentFile=/etc/orca/orca.env
Environment=HOME=/home/$ORCA_SERVICE_USER
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LIBGL_ALWAYS_SOFTWARE=1
ExecStart=/opt/orca/orca-linux.AppImage serve --port \${ORCA_PORT} --pairing-address \${ORCA_PAIRING_ADDRESS} --json
StandardOutput=journal
StandardError=journal
KillMode=mixed
Restart=on-failure
RestartPreventExitStatus=3
RestartSec=5
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl reset-failed orca-serve.service 2>/dev/null || true
start_marker="$(date --iso-8601=seconds)"
sudo systemctl enable --now orca-serve.service

ready=0
for _ in $(seq 1 60); do
    if sudo journalctl -u orca-serve.service --since "$start_marker" -o cat --no-pager \
        | jq -Re 'fromjson? | select(
            .type == "orca_server_ready" and
            .schemaVersion == 1 and
            .pairing.available == true and
            (.pairing.webClientUrl | type == "string" and length > 0)
        )' >/dev/null; then
        ready=1
        break
    fi
    systemctl is-active --quiet orca-serve.service || break
    sleep 1
done

if [ "$ready" -ne 1 ]; then
    sudo systemctl stop orca-serve.service 2>/dev/null || true
    if [ "$had_previous" -eq 1 ]; then
        warn "이전 바이너리는 /opt/orca/orca-linux.AppImage.previous에 보존했다."
        warn "상태 스키마가 바뀔 수 있으므로 바이너리만 되돌리지 말고 업그레이드 전 프로필 백업도 함께 복구한다."
    fi
    die "Orca 브라우저 준비 이벤트를 60초 안에 확인하지 못했다. 저널을 확인할 것."
fi

sudo rm -f /opt/orca/orca-linux.AppImage.previous /opt/orca/VERSION.previous

ok "Orca 서비스 실행 중"
echo
echo "에이전트 계정 등록 (최초 1회):"
echo "  sudo -u $ORCA_SERVICE_USER -H /bin/bash -c 'cd \"\$HOME\" && exec codex login --device-auth'"
echo "  sudo -u $ORCA_SERVICE_USER -H /bin/bash -c 'cd \"\$HOME\" && exec gh auth login'"
echo
echo "브라우저 URL: sudo $SCRIPT_DIR/util/show-orca-access.sh"
echo "다음: ./install/05-repos.sh"

#!/usr/bin/env bash
# 호스트 설정 3/6 — Tailscale 사설망.
#
# Orca 포트는 Lightsail 공인 방화벽에 열지 않는다. 브라우저와 서버가 같은
# tailnet에 있을 때만 tailscale0 경로로 접근한다.

. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

export DEBIAN_FRONTEND=noninteractive

need curl
need jq

if command -v tailscale >/dev/null 2>&1; then
    ok "Tailscale 이미 설치됨"
else
    . /etc/os-release
    [ "${ID:-}" = ubuntu ] || die "이 설치 스크립트는 Ubuntu를 대상으로 한다 (감지: ${ID:-unknown})."
    codename="${VERSION_CODENAME:-}"
    [ -n "$codename" ] || die "Ubuntu VERSION_CODENAME을 찾지 못했다."

    say "Tailscale 공식 APT 저장소 등록 ($codename)"
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" \
        | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" \
        | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq tailscale
fi

sudo systemctl enable --now tailscaled

if [ -n "$TAILSCALE_HOSTNAME" ]; then
    [[ "$TAILSCALE_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
        || die "TAILSCALE_HOSTNAME 형식이 잘못되었다: $TAILSCALE_HOSTNAME"
fi

tailscale_up_args=()
[ -z "$TAILSCALE_HOSTNAME" ] || tailscale_up_args+=(--hostname="$TAILSCALE_HOSTNAME")

if tailscale ip -4 >/dev/null 2>&1; then
    if [ -n "$TAILSCALE_HOSTNAME" ]; then
        sudo tailscale set --hostname="$TAILSCALE_HOSTNAME"
    fi
else
    say "Tailscale 최초 인증"
    warn "아래에 표시되는 URL을 관리 PC 브라우저에서 열어 인증한다. 인증될 때까지 이 단계는 대기한다."
    echo
    sudo tailscale up "${tailscale_up_args[@]}"
    echo
fi

tailscale_ip=""
for _ in $(seq 1 30); do
    tailscale_ip="$(tailscale ip -4 2>/dev/null | head -1)"
    [ -z "$tailscale_ip" ] || break
    sleep 1
done
[ -n "$tailscale_ip" ] || die "Tailscale 인증 후에도 IPv4를 받지 못했다. ./install/03-private-network.sh를 다시 실행할 것."

if [ -n "$TAILSCALE_HOSTNAME" ]; then
    hostname_converged=0
    for _ in $(seq 1 30); do
        current_hostname="$(tailscale status --json | jq -r '.Self.HostName // empty')"
        if [ "${current_hostname,,}" = "${TAILSCALE_HOSTNAME,,}" ]; then
            hostname_converged=1
            break
        fi
        sleep 1
    done
    [ "$hostname_converged" -eq 1 ] \
        || die "Tailscale 호스트명이 30초 안에 반영되지 않았다 (현재: ${current_hostname:-없음}, 기대: $TAILSCALE_HOSTNAME)."
fi

tailscale_dns="$(tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
[ -n "$tailscale_dns" ] || die "Tailscale MagicDNS 이름을 찾지 못했다. tailnet에서 MagicDNS를 활성화할 것."

ok "Tailscale 연결됨: $tailscale_ip"
ok "MagicDNS: $tailscale_dns"

cat <<'TXT'
관리 PC에도 Tailscale을 설치하고 같은 tailnet에 로그인해야 한다.
다음: ./install/04-orca-server.sh
TXT

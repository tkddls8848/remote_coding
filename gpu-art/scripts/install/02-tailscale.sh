#!/usr/bin/env bash
# 그림 서버 설정 2/5 — Tailscale 사설망.
#
# ComfyUI 는 보안 그룹에 열지 않는다. 관리 PC 와 이 서버가 같은 tailnet 에 있을 때만
# tailscale0 경로로 붙는다. (최상위 scripts/install/03-private-network.sh 와 같은 방식)

. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

export DEBIAN_FRONTEND=noninteractive
need curl
need jq

if command -v tailscale >/dev/null 2>&1; then
    ok "Tailscale 이미 설치됨"
else
    . /etc/os-release
    [ "${ID:-}" = ubuntu ] || die "Ubuntu 를 대상으로 한다 (감지: ${ID:-unknown})."
    codename="${VERSION_CODENAME:-}"
    [ -n "$codename" ] || die "Ubuntu VERSION_CODENAME 을 찾지 못했다."

    say "Tailscale 공식 APT 저장소 등록 ($codename)"
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.noarmor.gpg" \
        | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${codename}.tailscale-keyring.list" \
        | sudo tee /etc/apt/sources.list.d/tailscale.list >/dev/null
    retry 3 sudo apt-get update -qq
    retry 3 sudo apt-get install -y -qq tailscale
fi

sudo systemctl enable --now tailscaled

[ -n "$GPU_TAILSCALE_HOSTNAME" ] || die "GPU_TAILSCALE_HOSTNAME 이 비었다. 로컬에서 scripts/provision.sh 로 다시 복사할 것."
[[ "$GPU_TAILSCALE_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] \
    || die "GPU_TAILSCALE_HOSTNAME 형식이 잘못되었다: $GPU_TAILSCALE_HOSTNAME"

if tailscale ip -4 >/dev/null 2>&1; then
    sudo tailscale set --hostname="$GPU_TAILSCALE_HOSTNAME"
elif [ -n "$GPU_TS_AUTHKEY" ]; then
    say "Tailscale 인증 (auth key)"
    # 키는 명령 줄에 남지 않게 파일로 넘긴다.
    keyfile="$(mktemp)"
    trap 'rm -f "$keyfile"' EXIT
    printf '%s' "$GPU_TS_AUTHKEY" > "$keyfile"
    sudo tailscale up --hostname="$GPU_TAILSCALE_HOSTNAME" --auth-key="file:$keyfile"
else
    say "Tailscale 최초 인증"
    warn "아래 URL 을 관리 PC 브라우저에서 열어 인증한다. 인증될 때까지 기다린다."
    echo
    sudo tailscale up --hostname="$GPU_TAILSCALE_HOSTNAME"
    echo
fi

tailscale_ip=""
for _ in $(seq 1 30); do
    tailscale_ip="$(tailscale ip -4 2>/dev/null | head -1)"
    [ -z "$tailscale_ip" ] || break
    sleep 1
done
[ -n "$tailscale_ip" ] || die "Tailscale 인증 후에도 IPv4 를 받지 못했다. 이 스크립트를 다시 실행할 것."

tailscale_dns="$(tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
ok "Tailscale 연결됨: $tailscale_ip ${tailscale_dns:+($tailscale_dns)}"

cat <<'TXT'
관리 PC 도 같은 tailnet 에 로그인돼 있어야 한다.
tailnet 관리 화면에서 이 기기의 'Key expiry' 를 끄면 180 일마다 다시 인증하지 않아도 된다.
다음: ./install/03-comfyui.sh
TXT

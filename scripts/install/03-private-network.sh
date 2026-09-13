#!/usr/bin/env bash
# 호스트 설정 3/6 — Tailscale 사설망.
#
# Orca 포트는 Lightsail 공인 방화벽에 열지 않는다. 브라우저와 서버가 같은
# tailnet에 있을 때만 tailscale0 경로로 접근한다.

. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

export DEBIAN_FRONTEND=noninteractive

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

if tailscale ip -4 >/dev/null 2>&1; then
    ok "Tailscale 연결됨: $(tailscale ip -4 | head -1)"
else
    warn "Tailscale 인증이 아직 필요하다. 아래 명령의 URL을 브라우저에서 연 뒤 이 스크립트를 다시 실행한다."
    echo
    echo "  sudo tailscale up"
    echo
fi

cat <<'TXT'
관리 PC에도 Tailscale을 설치하고 같은 tailnet에 로그인해야 한다.
다음: Tailscale 연결 후 ./install/04-orca-server.sh
TXT

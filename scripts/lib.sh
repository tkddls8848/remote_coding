#!/usr/bin/env bash
# 모든 스크립트가 공통으로 쓰는 설정 로딩 / 출력 / 가드.
# 직접 실행하지 않고 source 한다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 설정: scripts/config.env (로컬) 또는 ~/orca-host.env (서버) 에서 읽는다.
for f in "$SCRIPT_DIR/config.env" "$HOME/orca-host.env"; do
    # shellcheck disable=SC1090
    [ -f "$f" ] && . "$f"
done

REGION="${REGION:-ap-northeast-2}"
INSTANCE_NAME="${INSTANCE_NAME:-orca-host}"
BUNDLE_ID="${BUNDLE_ID:-medium_3_0}"
BLUEPRINT_ID="${BLUEPRINT_ID:-ubuntu_24_04}"
KEY_PAIR_NAME="${KEY_PAIR_NAME:-orca-host-key}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-$HOME/.ssh/id_ed25519.pub}"
STATIC_IP_NAME="${STATIC_IP_NAME:-${INSTANCE_NAME}-ip}"
ORCA_PORT="${ORCA_PORT:-4224}"
DOMAIN="${DOMAIN:-}"
MY_IP="${MY_IP:-}"

export AWS_PAGER=""

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  xx\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' 가 필요하다. 먼저 설치할 것."; }

# AWS 자격증명이 실제로 유효한지 확인한다. 유효하지 않은 토큰이 환경변수에
# 들어있는 경우가 있어서, 리전 호출 전에 여기서 먼저 걸러낸다.
require_aws() {
    need aws
    aws sts get-caller-identity --query Arn --output text >/dev/null 2>&1 \
        || die "AWS 자격증명이 유효하지 않다. aws sts get-caller-identity 로 확인할 것."
    ok "AWS 인증: $(aws sts get-caller-identity --query Arn --output text)"
}

instance_exists() {
    aws lightsail get-instance --region "$REGION" --instance-name "$INSTANCE_NAME" \
        >/dev/null 2>&1
}

# 부착된 고정 IP. 없으면 빈 문자열.
static_ip_address() {
    aws lightsail get-static-ip --region "$REGION" --static-ip-name "$STATIC_IP_NAME" \
        --query 'staticIp.ipAddress' --output text 2>/dev/null | grep -v '^None$' || true
}

# 접속에 쓸 호스트명. DOMAIN 이 비어 있으면 sslip.io 로 대체한다.
resolve_host() {
    if [ -n "$DOMAIN" ]; then
        printf '%s' "$DOMAIN"
        return
    fi
    local ip="${STATIC_IP:-$(static_ip_address)}"
    [ -n "$ip" ] || die "DOMAIN 이 비어 있고 고정 IP 도 찾을 수 없다. 01 을 먼저 실행할 것."
    printf '%s.sslip.io' "$ip"
}

detect_my_ip() {
    [ -n "$MY_IP" ] && { printf '%s' "$MY_IP"; return; }
    curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]'
}

confirm() {
    local prompt="$1"
    [ "${ASSUME_YES:-0}" = "1" ] && return 0
    read -r -p "$prompt [y/N] " reply
    case "$reply" in [yY]*) return 0 ;; *) die "중단했다." ;; esac
}

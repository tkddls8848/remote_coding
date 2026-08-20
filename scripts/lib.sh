#!/usr/bin/env bash
# 모든 호스트 설정 스크립트가 공통으로 쓰는 설정 로딩 / 출력 / 가드.
# 직접 실행하지 않고 source 한다.
#
# AWS 자원(인스턴스/고정 IP/방화벽) 조회·생성은 여기 없다 — ../terraform 이 담당한다.
# 이 파일은 순수 호스트 설정 단계(03~09, verify-host, sync-host)에서만 쓴다.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

# 설정: scripts/config.env (로컬) 또는 ~/orca-host.env (서버) 에서 읽는다.
for f in "$SCRIPT_DIR/config.env" "$HOME/orca-host.env"; do
    # shellcheck disable=SC1090
    [ -f "$f" ] && . "$f"
done

ORCA_PORT="${ORCA_PORT:-4224}"
DOMAIN="${DOMAIN:-}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  xx\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' 가 필요하다. 먼저 설치할 것."; }

# terraform/ 의 output 값을 읽는다. 아직 apply 되지 않았으면 빈 문자열.
tf_output() {
    ( cd "$TF_DIR" && terraform output -raw "$1" 2>/dev/null ) || true
}

# 접속에 쓸 호스트명. DOMAIN 이 비어 있으면 terraform 의 고정 IP로 sslip.io 를 쓴다.
resolve_host() {
    if [ -n "$DOMAIN" ]; then
        printf '%s' "$DOMAIN"
        return
    fi
    local ip="${STATIC_IP:-$(tf_output static_ip)}"
    [ -n "$ip" ] || die "DOMAIN 이 비어 있고 terraform 의 고정 IP 도 찾을 수 없다. terraform apply 를 먼저 실행할 것 (terraform/README.md)."
    printf '%s.sslip.io' "$ip"
}

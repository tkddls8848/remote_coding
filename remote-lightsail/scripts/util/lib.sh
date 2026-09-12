#!/usr/bin/env bash
# 모든 호스트 설정 스크립트가 공통으로 쓰는 설정 로딩 / 출력 / 가드.
# 직접 실행하지 않고 source 한다.
#
# AWS 자원(인스턴스/고정 IP/방화벽) 조회·생성은 여기 없다 — ../../terraform 이 담당한다.
# 이 파일은 install/ 및 util/ 스크립트에서만 쓴다.

set -euo pipefail

UTIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$UTIL_DIR/.." && pwd)"
TF_DIR="$SCRIPT_DIR/../terraform"

# 설정: scripts/config.env (로컬) 또는 scripts/host.env (서버) 에서 읽는다.
for f in "$SCRIPT_DIR/config.env" "$SCRIPT_DIR/host.env"; do
    # shellcheck disable=SC1090
    [ -f "$f" ] && . "$f"
done

ORCA_VERSION="${ORCA_VERSION:-v1.4.188}"
ORCA_PORT="${ORCA_PORT:-6768}"
ORCA_SERVICE_USER="${ORCA_SERVICE_USER:-orca}"
ORCA_PAIRING_ADDRESS="${ORCA_PAIRING_ADDRESS:-}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  xx\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' 가 필요하다. 먼저 설치할 것."; }

# sudo 대상이 /home/ubuntu 아래의 접근 불가능한 현재 디렉터리를 물려받으면 gh/git/Orca가
# 시작 단계에서 실패할 수 있다. 서비스 계정 명령은 항상 그 계정의 HOME에서 실행한다.
as_orca() {
    sudo -u "$ORCA_SERVICE_USER" -H /bin/bash -c 'cd "$HOME" && exec "$@"' bash "$@"
}

# terraform/ 의 output 값을 읽는다. 아직 apply 되지 않았으면 빈 문자열.
# 주의: output 이 없을 때 terraform 은 exit 0 으로 "Warning: No outputs found" 를
#       stdout 에 흘린다. 그대로 두면 경고문이 값으로 잡히므로 걸러낸다.
tf_output() {
    local v
    v="$( cd "$TF_DIR" && terraform output -no-color -raw "$1" 2>/dev/null )" || return 0
    case "$v" in *"No outputs found"* | *"Warning:"* | *"Error:"*) return 0 ;; esac
    printf '%s' "$v"
}

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
# 서비스 계정의 로컬 비밀번호. 호스트 안에서 `su - orca` 로 넘어갈 때만 쓴다.
# 원격 로그인 경로는 아니다 — install/06-vscode-remote.sh 가 이 계정의 SSH 비밀번호
# 인증을 끄고 공개키만 받는다.
# 값은 커밋하지 않는 scripts/config.env(서버에서는 host.env)에만 둔다. 여기 기본값이
# 비어 있으면 04-orca-server.sh 는 비밀번호를 설정하지 않고 계정을 잠긴 채 남긴다.
ORCA_SERVICE_PASSWORD="${ORCA_SERVICE_PASSWORD:-}"
# 비밀번호를 쓸 때 요구하는 최소 길이. docs/stability-plan.md 6.9.
ORCA_SERVICE_PASSWORD_MIN_LEN="${ORCA_SERVICE_PASSWORD_MIN_LEN:-16}"
# 서비스 계정의 sudo 권한. 이 계정으로 붙은 사람과 에이전트가 호스트를 직접 관리한다.
#   nopasswd  — sudo 그룹 + NOPASSWD:ALL 드롭인 (기본). 비밀번호 없이 무엇이든 root.
#   whitelist — sudo 그룹 + ORCA_SUDO_WHITELIST 에 열거한 명령만 NOPASSWD.
#   password  — sudo 그룹만. 실행할 때마다 ORCA_SERVICE_PASSWORD 를 입력해야 한다.
#   off       — sudo 그룹에서 빼고 드롭인을 지운다.
# 이 호스트는 입주 앱과 공유한다. sudo 를 준다는 것은 이 계정이 /srv/<앱>/.env 를 포함해
# 호스트 전체를 읽고 쓸 수 있다는 뜻이다. docs/stability-plan.md 6.0~6.1 참조.
ORCA_SERVICE_SUDO="${ORCA_SERVICE_SUDO:-nopasswd}"
# whitelist 모드에서 NOPASSWD 로 허용할 명령. sudoers Cmnd 문법을 그대로 쓰며 줄 단위로
# 적는다. 에이전트가 실제로 쓰는 명령을 `sudoreplay` 로 관찰한 뒤 좁혀 나간다.
ORCA_SUDO_WHITELIST="${ORCA_SUDO_WHITELIST:-$(cat <<'WL'
/usr/bin/systemctl restart orca-serve.service
/usr/bin/systemctl stop orca-serve.service
/usr/bin/systemctl start orca-serve.service
/usr/bin/systemctl status orca-serve.service
/usr/bin/systemctl is-active orca-serve.service
/usr/bin/journalctl -u orca-serve.service *
/usr/bin/apt-get update
/usr/bin/apt-get install *
/usr/bin/apt-get upgrade
WL
)}"
# sudo I/O 로깅. root 로 무엇을 실행했는지 남기는 최소선이다 (sudoreplay 로 재생).
# docs/stability-plan.md 6.1-3 / 6.6-1 — P0 항목이므로 기본값이 on 이다.
ORCA_SUDO_LOG="${ORCA_SUDO_LOG:-on}"
ORCA_SUDO_LOG_DIR="${ORCA_SUDO_LOG_DIR:-/var/log/sudo-io}"
# orca-serve.service 의 메모리 상한. 커널 OOM killer 가 임의의 프로세스를 고르는 대신
# 한도를 넘은 이 서비스만 예측 가능하게 멈추게 한다. docs/stability-plan.md 5.3 / 6.4.
ORCA_MEMORY_HIGH="${ORCA_MEMORY_HIGH:-2G}"
ORCA_MEMORY_MAX="${ORCA_MEMORY_MAX:-2800M}"
# Orca 바이너리 무결성. ORCA_SHA256 을 적어 두면 04-orca-server.sh 가 다운로드를
# 그 값과 대조하고 다르면 설치하지 않는다. 비워 두면 릴리스의 체크섬 파일을 먼저 찾고,
# 그것도 없으면 경고한 뒤 실제 값을 알려 준다. docs/stability-plan.md 4.3.
ORCA_SHA256="${ORCA_SHA256:-}"
# 1 이면 기대 체크섬을 구하지 못했을 때 설치를 중단한다.
ORCA_REQUIRE_CHECKSUM="${ORCA_REQUIRE_CHECKSUM:-0}"
# 불완전 다운로드 거부 기준. AppImage 는 100MB 를 넘으므로 50MB 를 하한으로 둔다.
ORCA_MIN_BYTES="${ORCA_MIN_BYTES:-52428800}"
ORCA_PAIRING_ADDRESS="${ORCA_PAIRING_ADDRESS:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-}"
# 호스트 타임존. 입주 앱의 cron.d 시각(타임존을 선언할 수 없다)과 Lightsail 자동 스냅샷
# 시각(UTC 정시)이 같은 기준을 보도록 UTC 로 고정한다. 앱별 스케줄이 현지 시각을 원하면
# 유닛 파일의 systemd timer 에서 타임존을 선언한다.
HOST_TIMEZONE="${HOST_TIMEZONE:-UTC}"

# --- 에이전트 CLI 버전 ------------------------------------------------------
# latest 면 매 실행 최신을 받는다 (재현성 없음). 배포를 고정하려면 정확한 버전을 적는다.
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-latest}"
CODEX_VERSION="${CODEX_VERSION:-latest}"

# --- 저장소 클론 신뢰경계 ---------------------------------------------------
# REPOS=all 열거에 포크를 포함할지. 포크는 제3자가 쓴 코드이고 에이전트는 그것을 읽고
# 명령을 실행한다. 기본은 제외다. docs/stability-plan.md 6.2.
REPOS_INCLUDE_FORKS="${REPOS_INCLUDE_FORKS:-0}"
REPOS_INCLUDE_ARCHIVED="${REPOS_INCLUDE_ARCHIVED:-0}"

# --- 알림 -------------------------------------------------------------------
# 장애·보안 이벤트를 보낼 웹훅 (Slack/Discord 호환 JSON {"text": ...}).
# 비어 있으면 /var/log/orca-alert.log 에만 남긴다. 값은 커밋하지 않는다.
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-80}"
SWAP_WARN_PERCENT="${SWAP_WARN_PERCENT:-70}"
JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-500M}"

# --- 백업 -------------------------------------------------------------------
# s3://버킷/접두사 형태. 비어 있으면 util/backup-orca.sh 가 로컬 아카이브만 만든다.
BACKUP_S3_URI="${BACKUP_S3_URI:-}"
# SSE-KMS 고객 관리 키. 자격증명을 백업한다면 사실상 필수다 (7.1-3).
BACKUP_KMS_KEY_ID="${BACKUP_KMS_KEY_ID:-}"
# 자격증명(.codex, gh 토큰)까지 담을지. 담으면 복구는 쉬워지고 노출면은 넓어진다.
BACKUP_INCLUDE_CREDENTIALS="${BACKUP_INCLUDE_CREDENTIALS:-0}"
BACKUP_LOCAL_DIR="${BACKUP_LOCAL_DIR:-/var/backups/orca}"

# --- VS Code Remote-SSH 키 --------------------------------------------------
# orca 계정에만 등록할 전용 공개키. 파일 경로 또는 `ssh-ed25519 AAAA... 주석` 원문.
# 비워 두면 06-vscode-remote.sh 는 ubuntu 의 키를 복사하지 않고 중단한다 —
# 키 하나가 두 계정을 동시에 여는 상태를 기본값으로 두지 않는다 (6.3).
ORCA_SSH_PUBLIC_KEY="${ORCA_SSH_PUBLIC_KEY:-}"
# 1 이면 예전 동작대로 ubuntu 의 authorized_keys 를 복사한다. 의식적으로만 켠다.
ORCA_SSH_REUSE_ADMIN_KEY="${ORCA_SSH_REUSE_ADMIN_KEY:-0}"

# 설치 시점의 기준값(해시)을 두는 곳. verify-host.sh 가 드리프트를 여기와 대조한다.
BASELINE_DIR="${BASELINE_DIR:-/var/lib/orca-host/baseline}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  xx\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' 가 필요하다. 먼저 설치할 것."; }

# retry N CMD... — 지수 백오프로 N 회까지 다시 시도한다.
# npm registry / GitHub API / nodesource 중 하나의 일시 장애가 설치 전체를 되돌리지
# 않게 한다. docs/stability-plan.md 4.1.
#   retry 3 sudo apt-get install -y foo
# 명령이 파이프라인이면 함수로 감싸서 넘긴다 (retry 3 my_fn).
retry() {
    local tries="$1"; shift
    local delay="${RETRY_BASE_DELAY:-3}"
    local n=1
    while true; do
        if "$@"; then
            # 호출부가 stdout 을 캡처하는 경우가 있다. 진행 상황은 stderr 로만 낸다.
            [ "$n" -eq 1 ] || printf '\033[1;32m  ok\033[0m %s\n' "재시도 $n 회째 성공: $1" >&2
            return 0
        fi
        if [ "$n" -ge "$tries" ]; then
            warn "$tries 회 모두 실패: $*"
            return 1
        fi
        warn "실패 ($n/$tries) — ${delay}초 뒤 재시도: $1"
        sleep "$delay"
        n=$((n + 1))
        delay=$((delay * 2))
    done
}

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

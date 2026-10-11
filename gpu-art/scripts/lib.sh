#!/usr/bin/env bash
# gpu-art 스크립트가 공통으로 쓰는 설정 로딩 / 출력 / 가드. 직접 실행하지 않고 source 한다.
#
# 로컬에서는 저장소 최상위 .env 를, 서버에서는 provision.sh 가 복사해 둔 GPU_* 값만 담은
# ~/gpu-art/.env 를 읽는다(최상위 .env 의 다른 비밀은 그림 서버로 보내지 않는다).

set -euo pipefail

GPU_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPU_DIR="$(cd "$GPU_SCRIPT_DIR/.." && pwd)"
GPU_TERRAFORM_DIR="$GPU_DIR/terraform"

if [ -f "$GPU_DIR/.env" ]; then
    # 서버: provision.sh 가 걸러서 복사한 파일
    ENV_FILE="$GPU_DIR/.env"
else
    # 로컬: 저장소 최상위 .env 하나
    ENV_FILE="$(cd "$GPU_DIR/.." && pwd)/.env"
fi
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi

HOST_TIMEZONE="${HOST_TIMEZONE:-UTC}"

# --- 그림 서버 ---------------------------------------------------------------
# 비우면 terraform 의 instance_name 을 쓴다 (provision.sh 가 채워서 보낸다).
GPU_TAILSCALE_HOSTNAME="${GPU_TAILSCALE_HOSTNAME:-}"
# 비우면 03 단계에서 인증 URL 을 출력하고 기다린다. 값은 비밀이다 — 출력하지 않는다.
GPU_TS_AUTHKEY="${GPU_TS_AUTHKEY:-}"

# ComfyUI 와 사용자 노드 판. 게임 저장소의 godot/tools/sd/MODELS.md 와 같은 판을 쓴다 —
# 노트북과 같은 판이어야 같은 워크플로가 같은 그림을 낸다.
GPU_COMFY_VERSION="${GPU_COMFY_VERSION:-v0.39.0}"
GPU_COMFY_GGUF_COMMIT="${GPU_COMFY_GGUF_COMMIT:-6ea2651e7df66d7585f6ffee804b20e92fb38b8a}"
GPU_GGUF_PIP_VERSION="${GPU_GGUF_PIP_VERSION:-0.19.0}"
# PyTorch 휠 색인. cu128 은 NVIDIA 드라이버 525 이상에서 돈다(Deep Learning AMI 는 그보다 새것).
GPU_TORCH_INDEX_URL="${GPU_TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
GPU_COMFY_PORT="${GPU_COMFY_PORT:-8188}"
GPU_COMFY_ROOT="${GPU_COMFY_ROOT:-/srv/comfy}"
# 이 시간(분) 동안 그림 요청 · SSH 접속 · GPU 사용이 없으면 서버가 스스로 꺼진다. 0 이면 끄지 않는다.
GPU_IDLE_STOP_MINUTES="${GPU_IDLE_STOP_MINUTES:-30}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  xx\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' 가 필요하다. 먼저 설치할 것."; }

# retry N CMD... — 지수 백오프로 N 회까지 다시 시도한다.
retry() {
    local tries="$1"; shift
    local delay="${RETRY_BASE_DELAY:-3}"
    local n=1
    while true; do
        if "$@"; then
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

# gpu-art/terraform 의 output 값. 아직 apply 되지 않았으면 빈 문자열.
tf_output() {
    local v
    v="$( cd "$GPU_TERRAFORM_DIR" && terraform output -no-color -raw "$1" 2>/dev/null )" || return 0
    case "$v" in *"No outputs found"* | *"Warning:"* | *"Error:"*) return 0 ;; esac
    printf '%s' "$v"
}

# 로컬에서 AWS CLI 자격증명을 terraform/aws 호출이 읽을 수 있게 현재 프로세스에만 넘긴다
# (최상위 scripts/util/provision-host.sh 와 같은 방식 — `aws login` 세션을 쓰는 경우).
aws_env() {
    need aws
    aws sts get-caller-identity >/dev/null 2>&1 \
        || die "AWS 자격증명이 없거나 만료됐다. 'aws login' (또는 'aws configure') 을 먼저 실행할 것."
    if [ -z "${AWS_ACCESS_KEY_ID:-}" ]; then
        local credential_env
        credential_env="$(aws configure export-credentials --format env 2>/dev/null)" \
            || die "AWS CLI 자격증명을 환경 변수로 내보내지 못했다."
        eval "$credential_env"
    fi
}

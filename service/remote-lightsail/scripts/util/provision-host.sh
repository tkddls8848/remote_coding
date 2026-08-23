#!/usr/bin/env bash
# 인프라 생성부터 호스트 스크립트 복사까지 한 번에 수행한다.
#
#   실행 위치: 로컬
#   범위: terraform apply (인스턴스/고정 IP/방화벽) -> SSH 대기 -> util/sync-host.sh
#   범위 밖: install/*.sh 실행과 CLI 로그인. 서버에 붙어 사람이 직접 한다.
#
#   ./service/remote-lightsail/scripts/util/provision-host.sh [옵션]
#
#     -y, --auto-approve   terraform apply 를 확인 없이 실행한다
#         --phase X        build | final (기본: terraform.tfvars 값)
#         --skip-apply     이미 떠 있는 인스턴스에 복사만 한다
#         --ssh-wait N     SSH 대기 횟수 (기본 40, 5초 간격)
#     -h, --help           이 도움말

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TF_DIR="$(cd "$TF_DIR" && pwd)"

AUTO_APPROVE=0
PHASE=""
SKIP_APPLY=0
SSH_WAIT=40

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--auto-approve) AUTO_APPROVE=1 ;;
        --phase)           PHASE="${2:-}"; shift ;;
        --skip-apply)      SKIP_APPLY=1 ;;
        --ssh-wait)        SSH_WAIT="${2:-}"; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 die "알 수 없는 옵션: $1 (--help 참고)" ;;
    esac
    shift
done

[ -z "$PHASE" ] || [ "$PHASE" = build ] || [ "$PHASE" = final ] \
    || die "--phase 는 build 또는 final 이어야 한다."
[[ "$SSH_WAIT" =~ ^[0-9]+$ ]] || die "--ssh-wait 는 숫자여야 한다."

# --- 0. 전제 확인 -----------------------------------------------------------
say "전제 확인"
need terraform
need ssh
need scp
need ssh-keygen

if command -v aws >/dev/null 2>&1; then
    aws sts get-caller-identity >/dev/null 2>&1 \
        || die "AWS 자격증명이 없다. 'aws configure' 를 먼저 실행할 것."
    ok "AWS 자격증명"
else
    warn "aws CLI 가 없다. Terraform 이 기본 자격증명 체인으로 인증한다."
fi

# terraform.tfvars 에서 값 하나를 읽는다 (없으면 빈 문자열).
tfvar() {
    [ -f "$TF_DIR/terraform.tfvars" ] || return 0
    sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" \
        "$TF_DIR/terraform.tfvars" | tail -1
}

if [ ! -f "$TF_DIR/terraform.tfvars" ]; then
    cp "$TF_DIR/terraform.tfvars.example" "$TF_DIR/terraform.tfvars"
    warn "terraform.tfvars 가 없어 예시를 복사했다: $TF_DIR/terraform.tfvars"
    warn "인스턴스 이름이나 리전을 바꾸려면 지금 수정하고 다시 실행할 것."
fi

if [ ! -f "$SCRIPT_DIR/config.env" ]; then
    cp "$SCRIPT_DIR/config.example.env" "$SCRIPT_DIR/config.env"
    warn "config.env 가 없어 예시를 복사했다: $SCRIPT_DIR/config.env"
    warn "클론할 레포 목록(REPOS)은 install/05-repos.sh 실행 전에 맞춰 둘 것."
    # 이 실행에서 바로 반영한다.
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/config.env"
fi

# SSH 키: terraform 이 file() 로 읽는 공개키와, 접속에 쓸 개인키가 모두 있어야 한다.
PUB_KEY="$(tfvar ssh_public_key_path)"
PUB_KEY="${PUB_KEY:-$HOME/.ssh/id_ed25519.pub}"
PUB_KEY="${PUB_KEY/#\~/$HOME}"
[ -f "$PUB_KEY" ] || die "공개키가 없다: $PUB_KEY
  ssh-keygen -t ed25519 -f \"${PUB_KEY%.pub}\" 로 만들거나
  terraform.tfvars 의 ssh_public_key_path 를 고칠 것."
ok "공개키 $PUB_KEY"

SSH_KEY="${PUB_KEY%.pub}"
SSH_ARGS=(-o StrictHostKeyChecking=accept-new)
if [ -f "$SSH_KEY" ]; then
    SSH_ARGS+=(-o IdentitiesOnly=yes -i "$SSH_KEY")
else
    SSH_KEY=""
    warn "개인키 ${PUB_KEY%.pub} 가 없다. ssh 기본 키/에이전트로 접속을 시도한다."
fi
export SSH_KEY

# --- 1. 인프라 -------------------------------------------------------------
if [ "$SKIP_APPLY" -eq 1 ]; then
    say "인프라 생성 건너뜀 (--skip-apply)"
else
    say "terraform init"
    terraform -chdir="$TF_DIR" init -input=false

    apply_args=(-input=false)
    [ -n "$PHASE" ] && apply_args+=(-var "phase=$PHASE")
    [ "$AUTO_APPROVE" -eq 1 ] && apply_args+=(-auto-approve)

    say "terraform apply${PHASE:+ (phase=$PHASE)}"
    terraform -chdir="$TF_DIR" apply "${apply_args[@]}"
    ok "인프라 반영 완료"
fi

STATIC_IP="$(tf_output static_ip)"
[[ "$STATIC_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
    || die "static_ip output 을 읽지 못했다 (값: '${STATIC_IP:-<빈 값>}').
  terraform -chdir=\"$TF_DIR\" output 으로 상태를 확인할 것."
export STATIC_IP
ok "고정 IP $STATIC_IP"

# --- 2. SSH 대기 -----------------------------------------------------------
say "SSH 대기 (최대 $((SSH_WAIT * 5))초)"
err="$(mktemp)"
trap 'rm -f "$err"' EXIT

ssh_ready=0
for ((i = 1; i <= SSH_WAIT; i++)); do
    if ssh "${SSH_ARGS[@]}" -o BatchMode=yes -o ConnectTimeout=8 \
        "ubuntu@$STATIC_IP" true 2>"$err"; then
        ssh_ready=1
        break
    fi
    # 같은 고정 IP 를 재사용하면 예전 호스트 키가 남아 접속이 막힌다.
    if grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED" "$err"; then
        warn "known_hosts 의 옛 항목을 제거한다: $STATIC_IP"
        ssh-keygen -R "$STATIC_IP" >/dev/null 2>&1 || true
        continue
    fi
    printf '\r  .. %d/%d' "$i" "$SSH_WAIT"
    sleep 5
done
printf '\r'

if [ "$ssh_ready" -ne 1 ]; then
    cat "$err" >&2
    die "SSH 로 붙지 못했다. 방화벽(현재 공인 IP /32)과 인스턴스 상태를 확인할 것.
  네트워크가 바뀌었다면 terraform apply 를 다시 실행하면 /32 규칙이 갱신된다."
fi
ok "ubuntu@$STATIC_IP 접속 가능"

# --- 3. 스크립트 복사 ------------------------------------------------------
say "호스트 스크립트 복사"
SYNC_SHOW_NEXT_STEPS=0 bash "$UTIL_DIR/sync-host.sh"

cat <<TXT

여기까지가 자동 구간이다. 다음은 서버에서 사람이 직접 실행한다:

  ssh ubuntu@$STATIC_IP
  cd ~/remote-lightsail-scripts
  ./install/01-host-base.sh
  ./install/02-agent-cli.sh
  ./install/03-private-network.sh
  sudo tailscale up                # 최초 1회 브라우저 로그인
  ./install/04-orca-server.sh
  sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec codex login --device-auth'
  sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec gh auth login'
  ./install/05-repos.sh
  sudo ./util/show-orca-access.sh
  ./util/verify-host.sh
TXT

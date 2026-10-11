#!/usr/bin/env bash
# 그림 서버를 만들고 설치 스크립트를 복사한다.
#
#   실행 위치: 로컬 (Windows 면 Git Bash)
#   범위: terraform apply -> SSH 대기 -> gpu-art 스크립트 · models.txt · GPU_* 설정 복사
#   범위 밖: install/*.sh 실행. 서버에 붙어 사람이 직접 한다(Tailscale 인증이 끼어 있다).
#
#   ./gpu-art/scripts/provision.sh [옵션]
#
#     -y, --auto-approve   terraform apply 를 확인 없이 실행한다
#         --skip-apply     이미 떠 있는 서버에 복사만 한다
#         --ssh-wait N     SSH 대기 횟수 (기본 60, 5초 간격 — GPU AMI 는 첫 부팅이 느리다)
#     -h, --help           이 도움말

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AUTO_APPROVE=0
SKIP_APPLY=0
SSH_WAIT=60

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [ $# -gt 0 ]; do
    case "$1" in
        -y|--auto-approve) AUTO_APPROVE=1 ;;
        --skip-apply)      SKIP_APPLY=1 ;;
        --ssh-wait)        SSH_WAIT="${2:-}"; shift ;;
        -h|--help)         usage; exit 0 ;;
        *)                 die "알 수 없는 옵션: $1 (--help 참고)" ;;
    esac
    shift
done
[[ "$SSH_WAIT" =~ ^[0-9]+$ ]] || die "--ssh-wait 는 숫자여야 한다."

# --- 0. 전제 확인 -----------------------------------------------------------
say "전제 확인"
need terraform
need ssh
need scp
need tar
aws_env
ok "AWS 자격증명"

if [ ! -f "$GPU_TERRAFORM_DIR/terraform.tfvars" ]; then
    cp "$GPU_TERRAFORM_DIR/terraform.tfvars.example" "$GPU_TERRAFORM_DIR/terraform.tfvars"
    warn "terraform.tfvars 가 없어 예시를 복사했다: $GPU_TERRAFORM_DIR/terraform.tfvars"
    warn "리전 · 인스턴스 종류를 바꾸려면 지금 고치고 다시 실행할 것."
fi

tfvar() {
    sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"([^\"]*)\".*/\1/p" \
        "$GPU_TERRAFORM_DIR/terraform.tfvars" | tail -1
}
PUB_KEY="$(tfvar ssh_public_key_path)"
PUB_KEY="${PUB_KEY:-$HOME/.ssh/id_ed25519.pub}"
PUB_KEY="${PUB_KEY/#\~/$HOME}"
[ -f "$PUB_KEY" ] || die "공개키가 없다: $PUB_KEY
  ssh-keygen -t ed25519 -f \"${PUB_KEY%.pub}\" 로 만들거나 terraform.tfvars 의 ssh_public_key_path 를 고칠 것."
SSH_ARGS=(-o StrictHostKeyChecking=accept-new)
[ -f "${PUB_KEY%.pub}" ] && SSH_ARGS+=(-o IdentitiesOnly=yes -i "${PUB_KEY%.pub}")

# --- 1. 인프라 -------------------------------------------------------------
if [ "$SKIP_APPLY" -eq 1 ]; then
    say "인프라 생성 건너뜀 (--skip-apply)"
else
    say "terraform init"
    terraform -chdir="$GPU_TERRAFORM_DIR" init -input=false
    apply_args=(-input=false)
    [ "$AUTO_APPROVE" -eq 1 ] && apply_args+=(-auto-approve)
    say "terraform apply"
    terraform -chdir="$GPU_TERRAFORM_DIR" apply "${apply_args[@]}"
fi

INSTANCE_ID="$(tf_output instance_id)"
INSTANCE_NAME="$(tf_output instance_name)"
REGION="$(tf_output region)"
[ -n "$INSTANCE_ID" ] || die "instance_id output 이 없다. terraform apply 가 끝났는지 확인할 것."

# 공인 IP 는 켤 때마다 바뀐다 — state 가 아니라 지금 값을 묻는다.
state="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].State.Name' --output text)"
if [ "$state" != running ]; then
    say "서버 켜기 ($state)"
    aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
fi
HOST_IP="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
[[ "$HOST_IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "공인 IP 를 읽지 못했다 (값: '$HOST_IP')."
ok "$INSTANCE_ID $HOST_IP"

# --- 2. SSH 대기 -----------------------------------------------------------
say "SSH 대기 (최대 $((SSH_WAIT * 5))초)"
ready=0
for ((i = 1; i <= SSH_WAIT; i++)); do
    if ssh "${SSH_ARGS[@]}" -o BatchMode=yes -o ConnectTimeout=8 "ubuntu@$HOST_IP" true 2>/dev/null; then
        ready=1; break
    fi
    printf '\r  .. %d/%d' "$i" "$SSH_WAIT"
    sleep 5
done
echo
[ "$ready" -eq 1 ] || die "SSH 가 열리지 않았다. 보안 그룹의 내 IP(my_ip/admin_cidrs)와 키를 확인할 것."
ok "SSH 열림"

# --- 3. 복사 ---------------------------------------------------------------
# 최상위 .env 는 다른 서버의 비밀도 담고 있다. 그림 서버에는 GPU_* 와 시간대만 보낸다.
say "스크립트 · 설정 복사 (~/gpu-art)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/gpu-art"
cp -r "$GPU_DIR/scripts" "$GPU_DIR/models.txt" "$tmp/gpu-art/"
(
    umask 077
    {
        echo "# provision.sh 가 최상위 .env 에서 GPU_* 만 골라 만든 파일"
        printf 'HOST_TIMEZONE=%q\n' "$HOST_TIMEZONE"
        printf 'GPU_TAILSCALE_HOSTNAME=%q\n' "${GPU_TAILSCALE_HOSTNAME:-$INSTANCE_NAME}"
        for v in GPU_TS_AUTHKEY GPU_COMFY_VERSION GPU_COMFY_GGUF_COMMIT GPU_GGUF_PIP_VERSION \
                 GPU_TORCH_INDEX_URL GPU_COMFY_PORT GPU_COMFY_ROOT GPU_IDLE_STOP_MINUTES; do
            printf '%s=%q\n' "$v" "${!v}"
        done
    } > "$tmp/gpu-art/.env"
)
tar -C "$tmp" -cf "$tmp/gpu-art.tar" gpu-art
scp "${SSH_ARGS[@]}" -q "$tmp/gpu-art.tar" "ubuntu@$HOST_IP:/tmp/gpu-art.tar"
ssh "${SSH_ARGS[@]}" "ubuntu@$HOST_IP" \
    'tar -C ~ -xf /tmp/gpu-art.tar && rm -f /tmp/gpu-art.tar && chmod 600 ~/gpu-art/.env && find ~/gpu-art -name "*.sh" -exec chmod +x {} +'
ok "복사 끝"

cat <<TXT

다음 — 서버에 붙어 차례로 실행한다 (모델 받기까지 20~30분):
  ssh ${SSH_ARGS[*]} ubuntu@$HOST_IP
  cd ~/gpu-art/scripts
  ./install/01-base.sh
  ./install/02-tailscale.sh     # 처음에는 인증 URL 이 뜬다 — 관리 PC 브라우저에서 연다
  ./install/03-comfyui.sh
  ./install/04-models.sh
  ./install/05-idle-stop.sh

끝나면 관리 PC 에서: ./gpu-art/scripts/gpu.sh status
TXT

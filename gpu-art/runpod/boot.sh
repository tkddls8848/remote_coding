#!/usr/bin/env bash
# RunPod 팟 안에서 켤 때마다 도는 준비 스크립트. gpu.py 가 base64 로 BOOT_SH 에 실어 보낸다.
#
# 저장 공간은 없다. 팟을 켤 때마다 팟 자체 디스크(/opt)에 처음부터 조립하고, 팟을 지우면 같이 사라진다.
#   /opt/art/    boot.log comfyui.log · models/(models.txt, 켤 때마다 받는다)
#   /opt/ComfyUI · /opt/venv   ComfyUI 코드 · 가상 환경
#   /opt/output · /opt/input   그린 그림 · 올린 그림 — 관리 PC 가 받아 간다
#
# 관리 PC 는 SSH(공개키로만)로 붙고, ComfyUI 는 그 SSH 터널로 쓴다(gpu.py 가 연다).
# ComfyUI 는 127.0.0.1 에만 묶고, 공개 포트는 22(SSH) 하나뿐이다(gpu.py 가 ports=['22/tcp'] 로 만든다).
set -euo pipefail

W=/opt/art
mkdir -p "$W"
exec > >(tee -a "$W/boot.log") 2>&1
say() { printf '[boot %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
# 준비가 어디서든 실패하면 멈춰 기다린다 — 컨테이너가 끝나면 RunPod 이 같은 준비를 되풀이하며 값만 나간다.
# booting 표시를 지우면 유휴 감시가 IDLE_MIN 분 뒤 팟을 지운다.
trap 'say "준비 실패(줄 $LINENO) — SSH 로 붙어 $W/boot.log 를 볼 것. 놀면 스스로 지운다"; rm -f "$W/booting"; sleep infinity' ERR
touch "$W/booting"
say "pod ${RUNPOD_POD_ID:-?} · gpu $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)"

# --- SSH (공개키로만) — 먼저 띄워서 준비 중에도 붙어 볼 수 있게 한다 ---------------
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq curl git ca-certificates openssh-server >/dev/null
mkdir -p /root/.ssh /run/sshd && chmod 700 /root/.ssh
# PUBLIC_KEY 는 RunPod 계정 설정의 공개키, ART_SSH_PUBKEY 는 gpu.py 가 관리 PC 의 공개키를 실어 보낸 것
printf '%s\n%s\n' "${PUBLIC_KEY:-}" "${ART_SSH_PUBKEY:-}" | grep -E '^(ssh-|ecdsa-|sk-)' | sort -u > /root/.ssh/authorized_keys || true
chmod 600 /root/.ssh/authorized_keys
[ -s /root/.ssh/authorized_keys ] || say "!! 공개키가 없다 — SSH 로 붙을 수 없다(RunPod 계정 설정 또는 관리 PC 의 ~/.ssh/id_ed25519.pub)"
ssh-keygen -A >/dev/null
cat > /etc/ssh/sshd_config.d/art.conf <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
AllowTcpForwarding local
X11Forwarding no
ClientAliveInterval 30
EOF
/usr/sbin/sshd
say "sshd 켜짐"

# --- 오래 놀면 스스로 지운다 — idle_guard.sh (gpu.py 가 IDLE_SH 로 실어 보낸다) ----------
# 준비 중($W/booting)에는 놀고 있다고 보지 않는다(최대 90분).
echo "$IDLE_SH" | base64 -d > /opt/idle-guard.sh
(setsid nohup bash /opt/idle-guard.sh >/dev/null 2>&1 &)

# --- 모델 (models.txt) — 뒤에서 동시에 받고 sha256 을 확인한다 ----------------------
M=$W/models
fetch() {   # fetch <경로> <주소> <sha256>
    local dest=$M/$1
    mkdir -p "$(dirname "$dest")"
    curl -fL --retry 5 --retry-delay 5 -C - -sS -o "$dest.part" "$2" || { say "받기 실패: $1"; return 1; }
    local got; got=$(sha256sum "$dest.part" | cut -d' ' -f1)
    if [ "$got" != "$3" ]; then rm -f "$dest.part"; say "sha256 다름: $1 ($got)"; return 1; fi
    mv -f "$dest.part" "$dest"
    say "받음 $1"
}
say "모델 받기 시작 (ComfyUI 설치와 동시에)"
pids=()
while read -r rel url sum; do
    case "$rel" in ''|'#'*) continue ;; /*|*..*) say "건너뜀(경로): $rel"; continue ;; esac
    fetch "$rel" "$url" "$sum" & pids+=($!)
done < <(echo "$MODELS_TXT" | base64 -d)

# --- ComfyUI + ComfyUI-GGUF (판 고정) -----------------------------------------
APP=/opt/ComfyUI
say "ComfyUI $COMFY_VERSION 받기"
git clone -q -c advice.detachedHead=false --depth 1 --branch "$COMFY_VERSION" https://github.com/Comfy-Org/ComfyUI.git "$APP"
GG=$APP/custom_nodes/ComfyUI-GGUF
git clone -q https://github.com/city96/ComfyUI-GGUF.git "$GG"
git -C "$GG" -c advice.detachedHead=false checkout -q "$GGUF_COMMIT"
mkdir -p "$M"
rm -rf "$APP/models" && ln -s "$M" "$APP/models"

PY=$(command -v python3 || command -v python)
say "Python 의존성 (이미지의 PyTorch 를 쓴다)"
"$PY" -m venv --system-site-packages /opt/venv
/opt/venv/bin/pip install -q --no-cache-dir -r "$APP/requirements.txt" "gguf==$GGUF_PIP" sentencepiece protobuf
/opt/venv/bin/python -c 'import torch; assert torch.cuda.is_available(); print("[boot] torch", torch.__version__, torch.cuda.get_device_name(0))'

fail=0
for p in "${pids[@]}"; do wait "$p" || fail=1; done
[ "$fail" = 0 ] || false   # → trap ERR
say "모델 준비됨 ($(du -sh "$M" | cut -f1))"

# --- ComfyUI 띄우기 -------------------------------------------------------------
mkdir -p /opt/output /opt/input
cd "$APP"
/opt/venv/bin/python main.py --listen 127.0.0.1 --port 8188 --output-directory /opt/output --input-directory /opt/input \
    --preview-method none > "$W/comfyui.log" 2>&1 &
COMFY=$!
for _ in $(seq 1 120); do curl -fsS -m 3 http://127.0.0.1:8188/system_stats >/dev/null 2>&1 && break; sleep 2; done
say "ComfyUI 준비됨 — 127.0.0.1:8188 (관리 PC 는 SSH 터널로)"
rm -f "$W/booting"
while kill -0 "$COMFY" 2>/dev/null; do sleep 60; done
say "ComfyUI 가 멈췄다 — $W/comfyui.log"
tail -40 "$W/comfyui.log" || true
sleep infinity

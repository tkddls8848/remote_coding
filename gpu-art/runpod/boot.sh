#!/usr/bin/env bash
# RunPod 팟 안에서 켤 때마다 도는 준비 스크립트. gpu.py 가 base64 로 BOOT_SH 에 실어 보낸다.
#
#   /workspace (네트워크 볼륨, 팟을 지워도 남는다 — 큰 파일은 빠르지만 작은 파일을 많이 쓰면 아주 느리다)
#     tailscale/   노드 상태 — 다음 팟도 같은 tailnet 기기(같은 이름)로 붙는다
#     models/      모델(models.txt, 처음 한 번 받는다)
#     pipcache/    받은 파이썬 휠 — 다음 팟은 인터넷 대신 여기서 깐다
#     boot.log comfyui.log   (그린 그림 사본은 팟 디스크 /opt/output — 관리 PC 가 받아 간다)
#   /opt (팟 자체 디스크, 켤 때마다 새로) — ComfyUI 코드 · 가상 환경. 2026-10-11: 가상 환경을 볼륨에 두니 pip 가 16분 넘게 걸렸다.
#
# ComfyUI 는 127.0.0.1 에만 묶는다. Tailscale(userspace)이 tailnet 에서 온 연결을 이 주소로 넘긴다.
# 공개 포트는 하나도 열지 않는다(gpu.py 가 ports=[] 로 만든다).
set -euo pipefail

W=/workspace
mkdir -p "$W"
exec > >(tee -a "$W/boot.log") 2>&1
say() { printf '[boot %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
say "pod ${RUNPOD_POD_ID:-?} · gpu $(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1)"

export DEBIAN_FRONTEND=noninteractive
if ! command -v curl >/dev/null || ! command -v git >/dev/null; then
    apt-get update -qq && apt-get install -y -qq curl git ca-certificates >/dev/null
fi

# --- Tailscale (userspace — 컨테이너에는 TUN 이 없다) -------------------------
TS=$W/tools/tailscale
if [ ! -x "$TS/tailscaled" ]; then
    say "Tailscale 받기"
    tgz=$(curl -fsSL 'https://pkgs.tailscale.com/stable/?mode=json' | python3 -c 'import json,sys; print(json.load(sys.stdin)["Tarballs"]["amd64"])')
    mkdir -p "$TS" && curl -fsSL "https://pkgs.tailscale.com/stable/$tgz" | tar -xz -C "$TS" --strip-components=1
fi
mkdir -p "$W/tailscale"
"$TS/tailscaled" --tun=userspace-networking --statedir="$W/tailscale" --socket=/tmp/tailscaled.sock >/tmp/tailscaled.log 2>&1 &
sleep 2
tsc() { "$TS/tailscale" --socket=/tmp/tailscaled.sock "$@"; }
if [ -n "${TS_AUTHKEY:-}" ]; then
    tsc up --hostname="$TS_HOST" --ssh --auth-key="$TS_AUTHKEY"
else
    tsc up --hostname="$TS_HOST" --ssh
fi
unset TS_AUTHKEY
say "Tailscale $(tsc ip -4 | head -1) ($TS_HOST)"

# --- ComfyUI + ComfyUI-GGUF (판 고정) -----------------------------------------
APP=/opt/ComfyUI
say "ComfyUI $COMFY_VERSION 받기"
git clone -q -c advice.detachedHead=false --depth 1 --branch "$COMFY_VERSION" https://github.com/Comfy-Org/ComfyUI.git "$APP"
GG=$APP/custom_nodes/ComfyUI-GGUF
git clone -q https://github.com/city96/ComfyUI-GGUF.git "$GG"
git -C "$GG" -c advice.detachedHead=false checkout -q "$GGUF_COMMIT"
# 모델은 볼륨에 둔다(예전 자리 $W/ComfyUI/models 에 받은 것이 있으면 옮긴다)
mkdir -p "$W/models"
if [ -d "$W/ComfyUI/models" ] && [ ! -L "$W/ComfyUI/models" ]; then cp -rn "$W/ComfyUI/models/." "$W/models/" 2>/dev/null || true; fi
rm -rf "$APP/models" && ln -s "$W/models" "$APP/models"
( rm -rf "$W/venv" "$W/ComfyUI" ) >/dev/null 2>&1 &   # 예전 배치(볼륨 위 코드 · 가상 환경)를 뒤에서 치운다

PY=$(command -v python3 || command -v python)
say "Python 의존성 (이미지의 PyTorch 를 쓴다 · 휠은 $W/pipcache)"
"$PY" -m venv --system-site-packages /opt/venv
PIP_CACHE_DIR=$W/pipcache /opt/venv/bin/pip install -q -r "$APP/requirements.txt" "gguf==$GGUF_PIP" sentencepiece protobuf
/opt/venv/bin/python -c 'import torch; assert torch.cuda.is_available(); print("[boot] torch", torch.__version__, torch.cuda.get_device_name(0))'

# --- 모델 (models.txt, sha256 확인은 처음 받을 때 한 번) ------------------------
M=$W/models
echo "$MODELS_TXT" | base64 -d | while read -r rel url sum; do
    case "$rel" in ''|'#'*) continue ;; /*|*..*) say "건너뜀(경로): $rel"; continue ;; esac
    dest=$M/$rel
    [ -f "$dest" ] && [ "$(cat "$dest.sha256" 2>/dev/null)" = "$sum" ] && continue
    mkdir -p "$(dirname "$dest")"
    say "받기 $rel"
    curl -fL --retry 5 --retry-delay 5 -C - -sS -o "$dest.part" "$url"
    got=$(sha256sum "$dest.part" | cut -d' ' -f1)
    if [ "$got" != "$sum" ]; then rm -f "$dest.part"; say "sha256 다름 — 멈춤: $rel ($got)"; exit 1; fi
    mv -f "$dest.part" "$dest"; echo "$sum" > "$dest.sha256"
done

# --- ComfyUI 띄우기 -------------------------------------------------------------
mkdir -p /opt/output /opt/input   # 그린 그림 · 올린 그림은 관리 PC 가 받아 간다 — 저장 공간에 쌓지 않는다
cd "$APP"
/opt/venv/bin/python main.py --listen 127.0.0.1 --port 8188 --output-directory /opt/output --input-directory /opt/input \
    --preview-method none > "$W/comfyui.log" 2>&1 &
COMFY=$!
for _ in $(seq 1 120); do curl -fsS -m 3 http://127.0.0.1:8188/system_stats >/dev/null 2>&1 && break; sleep 2; done
say "ComfyUI 준비됨 — http://$TS_HOST:8188"

# --- 오래 놀면 스스로 지운다(볼륨은 남는다) — idle_guard.sh (gpu.py 가 IDLE_SH 로 실어 보낸다) ----------
echo "$IDLE_SH" | base64 -d > /opt/idle-guard.sh
(setsid nohup bash /opt/idle-guard.sh >/dev/null 2>&1 &)
while kill -0 "$COMFY" 2>/dev/null; do sleep 60; done
say "ComfyUI 가 멈췄다 — $W/comfyui.log"
tail -40 "$W/comfyui.log" || true
sleep infinity

#!/usr/bin/env bash
# 그림 서버 설정 3/5 — ComfyUI + ComfyUI-GGUF 를 systemd 서비스로.
#
# 판은 노트북과 같게 고정한다(.env 의 GPU_COMFY_VERSION · GPU_COMFY_GGUF_COMMIT).
# ComfyUI 는 Tailscale 주소에만 묶는다 — 공인 주소나 0.0.0.0 으로 듣지 않는다.
# 다시 실행해도 된다(이미 있는 것은 판만 맞춘다).

. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

need git
need python3
command -v tailscale >/dev/null 2>&1 || die "Tailscale 이 없다. ./install/02-tailscale.sh 를 먼저."

ROOT="$GPU_COMFY_ROOT"
APP="$ROOT/ComfyUI"
VENV="$ROOT/venv"
PIP="$VENV/bin/pip"

say "폴더 $ROOT"
sudo mkdir -p "$ROOT"
sudo chown "$(id -un):$(id -gn)" "$ROOT"

say "ComfyUI $GPU_COMFY_VERSION"
if [ -d "$APP/.git" ]; then
    git -C "$APP" fetch -q --depth 1 origin "refs/tags/$GPU_COMFY_VERSION:refs/tags/$GPU_COMFY_VERSION"
    git -C "$APP" -c advice.detachedHead=false checkout -q "$GPU_COMFY_VERSION"
else
    retry 3 git clone -q --depth 1 --branch "$GPU_COMFY_VERSION" https://github.com/Comfy-Org/ComfyUI.git "$APP"
fi
ok "$(git -C "$APP" rev-parse --short HEAD)"

say "ComfyUI-GGUF $GPU_COMFY_GGUF_COMMIT"
GGUF="$APP/custom_nodes/ComfyUI-GGUF"
if [ ! -d "$GGUF/.git" ]; then
    retry 3 git clone -q https://github.com/city96/ComfyUI-GGUF.git "$GGUF"
fi
git -C "$GGUF" fetch -q origin
git -C "$GGUF" -c advice.detachedHead=false checkout -q "$GPU_COMFY_GGUF_COMMIT"
ok "$(git -C "$GGUF" rev-parse --short HEAD)"

say "Python 환경 $VENV"
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
retry 3 "$PIP" install -q --upgrade pip
say "PyTorch ($GPU_TORCH_INDEX_URL)"
retry 3 "$PIP" install -q torch torchvision torchaudio --index-url "$GPU_TORCH_INDEX_URL"
say "ComfyUI 의존성"
retry 3 "$PIP" install -q -r "$APP/requirements.txt"
retry 3 "$PIP" install -q "gguf==$GPU_GGUF_PIP_VERSION" sentencepiece protobuf

"$VENV/bin/python" - <<'PY' || die "PyTorch 가 GPU 를 보지 못한다. 드라이버와 GPU_TORCH_INDEX_URL(cu 판)을 맞출 것."
import torch
assert torch.cuda.is_available(), "cuda not available"
print("  ok torch", torch.__version__, "·", torch.cuda.get_device_name(0))
PY

mkdir -p "$APP/models"/{unet,text_encoders,vae,loras} "$ROOT/output" "$ROOT/input"

say "실행 스크립트 $ROOT/run.sh"
# Tailscale 주소는 기기마다 다르고 인증 전에는 없으므로 시작할 때마다 읽는다.
cat > "$ROOT/run.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for _ in \$(seq 1 60); do
    ip="\$(tailscale ip -4 2>/dev/null | head -1)"
    [ -n "\$ip" ] && break
    sleep 2
done
[ -n "\${ip:-}" ] || { echo "Tailscale 주소가 없다" >&2; exit 1; }
cd "$APP"
exec "$VENV/bin/python" main.py --listen "\$ip" --port $GPU_COMFY_PORT \\
    --output-directory "$ROOT/output" --input-directory "$ROOT/input" --preview-method none
EOF
chmod +x "$ROOT/run.sh"

say "systemd 유닛 comfyui.service"
sudo tee /etc/systemd/system/comfyui.service >/dev/null <<EOF
[Unit]
Description=ComfyUI (art GPU host, Tailscale only)
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
User=$(id -un)
Group=$(id -gn)
ExecStart=$ROOT/run.sh
Restart=on-failure
RestartSec=10
# 모델을 올리는 동안 RAM 을 많이 쓴다. 넘치면 커널이 아무거나 죽이는 대신 이 서비스만 멈춘다.
MemoryMax=90%

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable comfyui.service >/dev/null
sudo systemctl restart comfyui.service

ts_ip="$(tailscale ip -4 | head -1)"
say "ComfyUI 응답 대기 (http://$ts_ip:$GPU_COMFY_PORT)"
for _ in $(seq 1 90); do
    if curl -fsS -m 3 "http://$ts_ip:$GPU_COMFY_PORT/system_stats" >/dev/null 2>&1; then
        ok "ComfyUI 응답함"
        echo "다음: ./install/04-models.sh"
        exit 0
    fi
    sleep 2
done
sudo journalctl -u comfyui.service -n 40 --no-pager >&2 || true
die "ComfyUI 가 3분 안에 응답하지 않았다 (위 로그 참고)."

#!/usr/bin/env bash
# 그림 서버 설정 5/5 — 오래 놀면 스스로 끄기 (돈이 새지 않게).
#
# 5분마다 본다. 아래 셋이 모두 없는 상태가 GPU_IDLE_STOP_MINUTES 분 이어지면 poweroff 한다:
#   - ComfyUI 대기열에 그릴 그림이 있다
#   - SSH 로 붙은 사람이 있다
#   - GPU 사용률이 10% 를 넘는다
# terraform 이 instance_initiated_shutdown_behavior = "stop" 이라 지워지지 않고 '중지'된다.
# 다시 켜는 것은 관리 PC 의 scripts/gpu.sh start.
# GPU_IDLE_STOP_MINUTES=0 이면 타이머를 끈다.

. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

[[ "$GPU_IDLE_STOP_MINUTES" =~ ^[0-9]+$ ]] || die "GPU_IDLE_STOP_MINUTES 는 숫자여야 한다."

if [ "$GPU_IDLE_STOP_MINUTES" -eq 0 ]; then
    sudo systemctl disable --now gpu-idle-stop.timer 2>/dev/null || true
    ok "유휴 자동 끄기 꺼짐 (GPU_IDLE_STOP_MINUTES=0)"
    exit 0
fi

sudo mkdir -p /etc/gpu-art
sudo tee /etc/gpu-art/idle.env >/dev/null <<EOF
IDLE_MINUTES=$GPU_IDLE_STOP_MINUTES
COMFY_PORT=$GPU_COMFY_PORT
EOF

sudo tee /usr/local/bin/gpu-idle-check >/dev/null <<'EOF'
#!/usr/bin/env bash
# gpu-idle-stop.service 가 5분마다 부른다. 마지막으로 바빴던 시각은 /run 에 둔다
# (부팅하면 지워지므로 켠 직후에는 다시 IDLE_MINUTES 를 센다).
set -u
. /etc/gpu-art/idle.env
STATE=/run/gpu-idle-last-busy
now=$(date +%s)
reason=""

ip="$(tailscale ip -4 2>/dev/null | head -1)"
if [ -n "$ip" ]; then
    q="$(curl -fsS -m 5 "http://$ip:$COMFY_PORT/queue" 2>/dev/null || true)"
    n="$(printf '%s' "$q" | jq -r '((.queue_running // []) | length) + ((.queue_pending // []) | length)' 2>/dev/null || echo 0)"
    [ "${n:-0}" -gt 0 ] && reason="comfy queue $n"
fi
[ -z "$reason" ] && [ -n "$(who)" ] && reason="ssh session"
util="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | sort -n | tail -1)"
[ -z "$reason" ] && [ "${util:-0}" -gt 10 ] && reason="gpu ${util}%"

if [ -n "$reason" ] || [ ! -f "$STATE" ]; then
    echo "$now" > "$STATE"
    exit 0
fi

idle=$(( (now - $(cat "$STATE")) / 60 ))
if [ "$idle" -ge "$IDLE_MINUTES" ]; then
    logger -t gpu-idle-stop "idle ${idle}m >= ${IDLE_MINUTES}m — powering off"
    systemctl poweroff
fi
EOF
sudo chmod 755 /usr/local/bin/gpu-idle-check

sudo tee /etc/systemd/system/gpu-idle-stop.service >/dev/null <<'EOF'
[Unit]
Description=Power off the art GPU host when idle

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gpu-idle-check
EOF

sudo tee /etc/systemd/system/gpu-idle-stop.timer >/dev/null <<'EOF'
[Unit]
Description=Check every 5 minutes whether the art GPU host is idle

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now gpu-idle-stop.timer >/dev/null
ok "유휴 ${GPU_IDLE_STOP_MINUTES}분이면 스스로 꺼진다 (기록: journalctl -t gpu-idle-stop)"

cat <<'TXT'
설치 끝. 관리 PC 에서:
  ./gpu-art/scripts/gpu.sh status
TXT

#!/usr/bin/env bash
# 그림 서버 설정 1/5 — 기본 패키지 · 시간대 · GPU 확인.

. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

export DEBIAN_FRONTEND=noninteractive

say "시간대 $HOST_TIMEZONE"
sudo timedatectl set-timezone "$HOST_TIMEZONE"

say "기본 패키지"
retry 3 sudo apt-get update -qq
retry 3 sudo apt-get install -y -qq git curl jq python3-venv python3-dev build-essential

say "GPU 확인"
command -v nvidia-smi >/dev/null 2>&1 \
    || die "nvidia-smi 가 없다. NVIDIA 드라이버가 든 Deep Learning Base AMI 로 만들었는지 확인할 것 (terraform output ami_name)."
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader \
    || die "nvidia-smi 가 GPU 를 읽지 못했다. 인스턴스를 한 번 재부팅한 뒤 다시 실행할 것."
ok "$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"

free -g | awk '/^Mem:/ { if ($2 < 30) { print "  !! RAM " $2 "GB — ComfyUI 가 모델을 올리다 멈출 수 있다 (32GB 권장)" > "/dev/stderr" } }'
df -h / | tail -1

echo "다음: ./install/02-tailscale.sh"

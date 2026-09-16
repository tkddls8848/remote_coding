#!/usr/bin/env bash
# 호스트 설정 1/6 — Orca/코딩 에이전트 공통 툴체인, 스왑, Node, 보안 패치.
#
#   실행 위치: 서버 (ubuntu 계정)

. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

export DEBIAN_FRONTEND=noninteractive

# --- 타임존 ---------------------------------------------------------------
# 입주 앱의 cron.d 는 타임존을 선언할 수 없어 호스트 설정을 그대로 따르고, Lightsail
# 자동 스냅샷 시각은 UTC 정시다. 두 시각을 같은 기준으로 읽으려면 호스트가 UTC 여야
# 한다. 기본 Ubuntu 이미지도 UTC 지만, 가정이 아니라 선언으로 남긴다.
if [ "$(timedatectl show -p Timezone --value)" = "$HOST_TIMEZONE" ]; then
    ok "타임존 $HOST_TIMEZONE"
else
    say "타임존 $HOST_TIMEZONE 적용"
    sudo timedatectl set-timezone "$HOST_TIMEZONE"
    ok "타임존 $(timedatectl show -p Timezone --value)"
fi

say "패키지 갱신"
sudo apt-get update -qq
sudo apt-get upgrade -y -qq

say "빌드 도구 설치"
# Xvfb와 AppImage 런타임 패키지는 Orca headless serve에 필요하다.
sudo apt-get install -y -qq \
    build-essential python3 python3-venv git gh curl ca-certificates unzip tmux \
    file jq xvfb zlib1g-dev ufw \
    libatk1.0-0t64 libatk-bridge2.0-0t64 libatspi2.0-0t64 \
    libgtk-3-0t64 libasound2t64 libcups2t64 libnss3 libnspr4 \
    libdrm2 libgbm1 libxss1 libxtst6 libxkbcommon0 \
    libsecret-1-0 libnotify4 xdg-utils

if apt-cache show libfuse2t64 >/dev/null 2>&1; then
    sudo apt-get install -y -qq libfuse2t64
elif apt-cache show libfuse2 >/dev/null 2>&1; then
    sudo apt-get install -y -qq libfuse2
else
    warn "FUSE 2 패키지가 없다. AppImage 실행이 실패하면 추출 실행 방식으로 전환할 것."
fi

# --- 스왑 4GB ---------------------------------------------------------------
if swapon --show | grep -q '/swapfile'; then
    ok "스왑 이미 활성"
else
    say "스왑 4GB 생성"
    sudo fallocate -l 4G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile >/dev/null
    sudo swapon /swapfile
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab >/dev/null
    ok "스왑 활성 + fstab 등록"
fi

# --- Node -------------------------------------------------------------------
if command -v node >/dev/null 2>&1 && node -v | grep -qE '^v(2[2-9]|[3-9][0-9])\.'; then
    ok "Node $(node -v) 이미 설치됨"
else
    say "Node 22 설치"
    curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - >/dev/null
    sudo apt-get install -y -qq nodejs
    ok "Node $(node -v)"
fi

# --- 보안 패치 --------------------------------------------------------------
say "unattended-upgrades"
sudo apt-get install -y -qq unattended-upgrades
# dpkg-reconfigure 는 대화형이라 설정 파일을 직접 쓴다 (동일한 결과).
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
    | sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null
ok "보안 패치 자동 적용 켜짐"

free -h
say "다음: ./install/02-agent-cli.sh"

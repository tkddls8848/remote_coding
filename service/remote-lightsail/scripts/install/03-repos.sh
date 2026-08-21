#!/usr/bin/env bash
# 호스트 설정 3/3 — 개발용 GitHub 레포 클론.
#
#   실행 위치: 서버 (ubuntu 계정)
#   전제: gh auth login (device flow) 완료

. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

: "${REPOS:?scripts/host.env 에 REPOS 가 없다}"
: "${GITHUB_OWNER:?scripts/host.env 에 GITHUB_OWNER 가 없다}"

if ! command -v gh >/dev/null 2>&1; then
    say "gh 설치"
    sudo apt-get install -y -qq gh || {
        warn "apt 에 gh 가 없다. https://cli.github.com 설치 절차를 따를 것."
        exit 1
    }
fi

gh auth status >/dev/null 2>&1 || {
    warn "GitHub 인증이 안 되어 있다. 먼저 실행할 것: gh auth login"
    exit 1
}

mkdir -p "$HOME/workspace"
for r in $REPOS; do
    if [ -d "$HOME/workspace/$r/.git" ]; then
        ok "$r 이미 클론됨"
    else
        say "클론: $GITHUB_OWNER/$r"
        git -C "$HOME/workspace" clone "https://github.com/$GITHUB_OWNER/$r.git" || warn "$r 클론 실패 — 건너뛴다"
    fi
done

ok "개발 레포 위치: $HOME/workspace"

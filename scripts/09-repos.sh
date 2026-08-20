#!/usr/bin/env bash
# Phase 9 — 레포 클론 + Orca 에 등록.
#
#   실행 위치: 서버
#   전제: gh auth login (device flow) 이 끝나 있을 것

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

: "${REPOS:?~/orca-host.env 에 REPOS 가 없다}"
: "${GITHUB_OWNER:?~/orca-host.env 에 GITHUB_OWNER 가 없다}"

if ! command -v gh >/dev/null 2>&1; then
    say "gh 설치"
    sudo apt-get install -y -qq gh || {
        warn "apt 에 gh 가 없다. https://cli.github.com 설치 절차를 따를 것."
        exit 1
    }
fi

gh auth status >/dev/null 2>&1 || {
    warn "GitHub 인증이 안 되어 있다. 먼저 실행할 것:  gh auth login"
    exit 1
}

mkdir -p ~/orca
for r in $REPOS; do
    if [ -d "$HOME/orca/$r/.git" ]; then
        ok "$r 이미 클론됨"
    else
        say "클론: $GITHUB_OWNER/$r"
        git -C ~/orca clone "https://github.com/$GITHUB_OWNER/$r.git" || warn "$r 클론 실패 — 건너뛴다"
    fi
done

for r in $REPOS; do
    [ -d "$HOME/orca/$r/.git" ] || continue
    if orca repo add --path "$HOME/orca/$r" >/dev/null 2>&1; then
        ok "$r 등록"
    else
        # 이미 등록되어 있으면 add 가 실패한다. 목록으로 실제 상태를 확인한다.
        warn "$r 등록 명령 실패 — 아래 repo list 에 있는지 확인할 것"
    fi
done

orca repo list

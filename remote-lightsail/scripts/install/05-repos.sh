#!/usr/bin/env bash
# 호스트 설정 5/6 — Orca 서비스 계정의 개발 저장소 클론.

. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

: "${REPOS:?scripts/host.env 에 REPOS 가 없다}"
: "${GITHUB_OWNER:?scripts/host.env 에 GITHUB_OWNER 가 없다}"

id "$ORCA_SERVICE_USER" >/dev/null 2>&1 \
    || die "Orca 서비스 계정이 없다. 먼저 ./install/04-orca-server.sh를 실행할 것."
command -v gh >/dev/null 2>&1 || die "gh가 없다. sudo apt-get install gh로 설치할 것."

as_orca gh auth status >/dev/null 2>&1 || {
    warn "Orca 서비스 계정의 GitHub 인증이 없다. 먼저 실행할 것:"
    warn "sudo -u $ORCA_SERVICE_USER -H /bin/bash -c 'cd \"\$HOME\" && exec gh auth login'"
    exit 1
}

workspace="/home/$ORCA_SERVICE_USER/workspace"
service_group="$(id -gn "$ORCA_SERVICE_USER")"
sudo install -d -o "$ORCA_SERVICE_USER" -g "$service_group" -m 0750 "$workspace"

for repo in $REPOS; do
    if sudo -u "$ORCA_SERVICE_USER" test -d "$workspace/$repo/.git"; then
        ok "$repo 이미 클론됨"
    else
        say "클론: $GITHUB_OWNER/$repo"
        as_orca git -C "$workspace" clone \
            "https://github.com/$GITHUB_OWNER/$repo.git" \
            || warn "$repo 클론 실패 — 건너뛴다"
    fi

    if sudo -u "$ORCA_SERVICE_USER" test -d "$workspace/$repo/.git"; then
        as_orca /opt/orca/orca-linux.AppImage \
            repo add --path "$workspace/$repo" --json >/dev/null \
            && ok "$repo Orca에 등록됨" \
            || warn "$repo Orca 등록 실패 — 서비스 상태와 로그를 확인한다"
    fi
done

ok "Orca 개발 저장소 위치: $workspace"
echo "다음: ./install/06-vscode-remote.sh"

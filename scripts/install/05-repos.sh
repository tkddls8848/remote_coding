#!/usr/bin/env bash
# 호스트 설정 5/6 — Orca 서비스 계정의 개발 저장소 클론.

. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

: "${GITHUB_OWNER:?scripts/host.env 에 GITHUB_OWNER 가 없다}"
REPOS="${REPOS:-all}"
REPOS_EXCLUDE="${REPOS_EXCLUDE:-}"
REPOS_LIMIT="${REPOS_LIMIT:-300}"

id "$ORCA_SERVICE_USER" >/dev/null 2>&1 \
    || die "Orca 서비스 계정이 없다. 먼저 ./install/04-orca-server.sh를 실행할 것."
command -v gh >/dev/null 2>&1 || die "gh가 없다. sudo apt-get install gh로 설치할 것."

as_orca gh auth status >/dev/null 2>&1 || {
    warn "Orca 서비스 계정의 GitHub 인증이 없다. 먼저 실행할 것:"
    warn "sudo -u $ORCA_SERVICE_USER -H /bin/bash -c 'cd \"\$HOME\" && exec gh auth login'"
    exit 1
}

# REPOS=all 이면 소유 저장소를 API 로 열거한다. GitHub 프로필의 Repositories 탭에 보이는
# 것과 같은 범위 — 프라이빗·포크·보관됨(archived)까지 전부다. 프라이빗을 받으려면 토큰에
# repo 스코프가 있어야 한다. 없으면 공개 저장소만 조용히 돌아오므로 먼저 막는다.
# 특정 저장소를 빼려면 REPOS_EXCLUDE 에 이름을 적는다.
if [ "$REPOS" = "all" ]; then
    as_orca gh auth status 2>&1 | grep -q "'repo'" \
        || die "토큰에 repo 스코프가 없어 프라이빗 저장소를 못 가져온다. 먼저 실행할 것:
  sudo -u $ORCA_SERVICE_USER -H /bin/bash -c 'cd \"\$HOME\" && exec gh auth refresh -s repo'"

    say "$GITHUB_OWNER 의 저장소 열거 (프라이빗·포크·보관 포함 — 소유 저장소 전부)"
    REPOS="$(as_orca gh repo list "$GITHUB_OWNER" \
        --limit "$REPOS_LIMIT" \
        --json name --jq '.[].name' | tr '\n' ' ')" \
        || die "gh repo list 실패. 인증과 네트워크를 확인한다."
    [ -n "${REPOS// /}" ] || die "열거 결과가 비었다. GITHUB_OWNER=$GITHUB_OWNER 를 확인한다."
fi

# gh 로그인 때 git 자격증명 연동을 건너뛰었으면 프라이빗 저장소 clone 이 인증을 물어보며
# 멈춘다. 헬퍼를 맞춰 두고, 그래도 자격증명이 없으면 프롬프트 대신 즉시 실패하게 한다.
as_orca gh auth setup-git \
    || warn "gh auth setup-git 실패 — 프라이빗 저장소 클론이 막힐 수 있다"

workspace="/home/$ORCA_SERVICE_USER/workspace"
service_group="$(id -gn "$ORCA_SERVICE_USER")"
sudo install -d -o "$ORCA_SERVICE_USER" -g "$service_group" -m 0750 "$workspace"

for repo in $REPOS; do
    case " $REPOS_EXCLUDE " in
        *" $repo "*) warn "$repo 제외됨 (REPOS_EXCLUDE)"; continue ;;
    esac

    if sudo -u "$ORCA_SERVICE_USER" test -d "$workspace/$repo/.git"; then
        ok "$repo 이미 클론됨"
    else
        say "클론: $GITHUB_OWNER/$repo"
        as_orca env GIT_TERMINAL_PROMPT=0 git -C "$workspace" clone \
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
say "새 저장소를 만든 뒤에는 이 스크립트를 다시 돌리면 된다 (이미 있는 것은 건너뛴다)."
echo "다음: ./install/06-vscode-remote.sh"

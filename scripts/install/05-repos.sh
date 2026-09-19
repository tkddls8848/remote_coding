#!/usr/bin/env bash
# 호스트 설정 5/6 — Orca 서비스 계정의 개발 저장소 클론.
#
# 여기 등록되는 저장소가 이 호스트의 신뢰경계다. 에이전트는 이 코드의 README·설정·빌드
# 스크립트를 읽고 그에 따라 명령을 실행하며, 의존성 설치 한 번이 곧 임의 코드 실행이다.
# 그래서 REPOS 는 사람이 선언하는 값이고, all 열거에서도 포크와 보관 저장소는 기본으로
# 뺀다 — 포크는 제3자가 쓴 코드다. docs/stability-plan.md 6.2.

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

# REPOS=all 이면 소유 저장소를 API 로 열거한다. 프라이빗은 포함하되(토큰에 repo 스코프가
# 있어야 한다) 포크와 보관됨은 REPOS_INCLUDE_* 로 명시적으로 켜야만 들어온다.
if [ "$REPOS" = "all" ]; then
    as_orca gh auth status 2>&1 | grep -q "'repo'" \
        || die "토큰에 repo 스코프가 없어 프라이빗 저장소를 못 가져온다. 먼저 실행할 것:
  sudo -u $ORCA_SERVICE_USER -H /bin/bash -c 'cd \"\$HOME\" && exec gh auth refresh -s repo'"

    list_args=(--limit "$REPOS_LIMIT" --json name --jq '.[].name')
    scope_desc="프라이빗 포함"
    if [ "$REPOS_INCLUDE_FORKS" = 1 ]; then
        scope_desc="$scope_desc, 포크 포함"
    else
        # --source 는 포크가 아닌 저장소만 남긴다.
        list_args=(--source "${list_args[@]}")
        scope_desc="$scope_desc, 포크 제외"
    fi
    if [ "$REPOS_INCLUDE_ARCHIVED" = 1 ]; then
        scope_desc="$scope_desc, 보관 포함"
    else
        list_args=(--no-archived "${list_args[@]}")
        scope_desc="$scope_desc, 보관 제외"
    fi

    warn "REPOS=all 이다. 열거 결과가 GitHub 계정 상태에 따라 자동으로 바뀌므로 신뢰경계를"
    warn "사람이 선언한 것이 아니다. 실제 작업 대상만 REPOS 에 적는 것을 권장한다."

    say "$GITHUB_OWNER 의 저장소 열거 ($scope_desc)"
    list_repos() { as_orca gh repo list "$GITHUB_OWNER" "${list_args[@]}"; }
    repo_lines="$(retry 3 list_repos)" \
        || die "gh repo list 가 3회 모두 실패했다. 인증과 네트워크를 확인한다."
    REPOS="$(printf '%s' "$repo_lines" | tr '\n' ' ')"
    [ -n "${REPOS// /}" ] || die "열거 결과가 비었다. GITHUB_OWNER=$GITHUB_OWNER 를 확인한다."
fi

say "대상 저장소: $REPOS"

# gh 로그인 때 git 자격증명 연동을 건너뛰었으면 프라이빗 저장소 clone 이 인증을 물어보며
# 멈춘다. 헬퍼를 맞춰 두고, 그래도 자격증명이 없으면 프롬프트 대신 즉시 실패하게 한다.
as_orca gh auth setup-git \
    || warn "gh auth setup-git 실패 — 프라이빗 저장소 클론이 막힐 수 있다"

workspace="/home/$ORCA_SERVICE_USER/workspace"
service_group="$(id -gn "$ORCA_SERVICE_USER")"
sudo install -d -o "$ORCA_SERVICE_USER" -g "$service_group" -m 0750 "$workspace"

clone_repo() {
    as_orca env GIT_TERMINAL_PROMPT=0 git -C "$workspace" clone \
        "https://github.com/$GITHUB_OWNER/$1.git"
}
fetch_repo() {
    as_orca env GIT_TERMINAL_PROMPT=0 git -C "$workspace/$1" fetch --all --prune --quiet
}

for repo in $REPOS; do
    case " $REPOS_EXCLUDE " in
        *" $repo "*) warn "$repo 제외됨 (REPOS_EXCLUDE)"; continue ;;
    esac

    if sudo -u "$ORCA_SERVICE_USER" test -d "$workspace/$repo/.git"; then
        # 이미 있으면 다시 클론하지 않고 원격만 따라잡는다. 작업 트리는 건드리지 않는다
        # (체크아웃·머지는 사람과 에이전트의 몫이다). docs/stability-plan.md 4.2-3.
        if retry 3 fetch_repo "$repo"; then
            ok "$repo 이미 클론됨 — fetch 완료"
        else
            warn "$repo fetch 실패 — 기존 클론을 그대로 둔다"
        fi
    else
        say "클론: $GITHUB_OWNER/$repo"
        retry 3 clone_repo "$repo" || warn "$repo 클론이 3회 모두 실패 — 건너뛴다"
    fi

    if sudo -u "$ORCA_SERVICE_USER" test -d "$workspace/$repo/.git"; then
        as_orca /opt/orca/orca-linux.AppImage \
            repo add --path "$workspace/$repo" --json >/dev/null \
            && ok "$repo Orca에 등록됨" \
            || warn "$repo Orca 등록 실패 — 서비스 상태와 로그를 확인한다"
    fi
done

ok "Orca 개발 저장소 위치: $workspace"
say "새 저장소를 만든 뒤에는 이 스크립트를 다시 돌리면 된다 (이미 있는 것은 fetch 만 한다)."
cat <<'TXT'

에이전트의 명령 자동 승인 정책도 함께 확인한다. 자동 승인이 켜져 있으면 저장소를
좁혀도 방어선이 하나 줄어든다. 이 값은 이 저장소의 코드가 아니라 Orca·Claude Code·
Codex 각각의 런타임 설정에 있다 (docs/stability-plan.md 6.2-3).

다음: ./install/06-vscode-remote.sh
TXT

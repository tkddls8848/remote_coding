#!/usr/bin/env bash
# 호스트 설정 2/6 — Claude Code와 Codex CLI 설치.
#
#   실행 위치: 서버 (ubuntu 계정)
#
# 버전은 config.env 의 CLAUDE_CODE_VERSION / CODEX_VERSION 으로 고정한다. latest 면
# 매 실행 최신을 받는다 — 재현성이 필요하면 정확한 버전을 적는다.
# 이미 그 버전이면 재설치하지 않는다 (docs/stability-plan.md 4.2).

. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

need node
need npm
need jq

installed_version() {
    npm ls -g --depth 0 --json 2>/dev/null \
        | jq -r --arg p "$1" '.dependencies[$p].version // empty' 2>/dev/null
}

install_pkg() {
    local pkg="$1" want="$2" have
    have="$(installed_version "$pkg")"

    if [ -n "$have" ] && [ "$want" != latest ] && [ "$have" = "$want" ]; then
        ok "$pkg@$have 이미 설치됨"
        return 0
    fi

    say "설치: $pkg@$want${have:+ (현재 $have)}"
    # npm registry 도 일시 장애가 있다. --fetch-retries 는 npm 자체 재시도이고,
    # retry 는 그 바깥에서 한 번 더 감싼다 (docs/stability-plan.md 4.1).
    retry 3 sudo npm i -g --no-fund --no-audit --fetch-retries 5 "$pkg@$want" >/dev/null \
        || die "$pkg@$want 설치가 3회 모두 실패했다."
    ok "$pkg@$(installed_version "$pkg")"
}

install_pkg @anthropic-ai/claude-code "$CLAUDE_CODE_VERSION"
install_pkg @openai/codex "$CODEX_VERSION"

if [ "$CLAUDE_CODE_VERSION" = latest ] || [ "$CODEX_VERSION" = latest ]; then
    warn "버전이 latest 다. 배포를 재현 가능하게 하려면 config.env 에 정확한 버전을 적는다:"
    warn "  npm view @openai/codex version"
fi

cat <<'TXT'

로그인은 Orca 서비스 계정이 생성된 뒤 수행한다. ubuntu 계정으로 먼저 로그인하면
Orca 서비스가 그 자격증명을 볼 수 없다.

다음: ./install/03-private-network.sh
TXT

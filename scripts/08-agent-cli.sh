#!/usr/bin/env bash
# Phase 8 — 에이전트 CLI 설치.
#
#   실행 위치: 서버
#
# 설치까지만 자동이다. 로그인은 device auth 라서 화면에 뜨는 코드를 사람이
# 브라우저에 입력해야 한다 — 자동화할 수 없는 구간이다.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need node
need npm

for pkg in @anthropic-ai/claude-code @openai/codex; do
    say "설치: $pkg"
    sudo npm i -g "$pkg" >/dev/null
done
ok "설치 완료"

cat <<'TXT'

여기서부터는 사람이 직접 한다 (device auth):

  claude      # 출력되는 URL/코드를 브라우저에 입력
  codex       # 동일

두 CLI 모두 로그인 상태가 홈 디렉터리에 저장되므로, 한 번 해두면
이후 서버 재부팅이나 클라이언트 재접속에 다시 필요하지 않다.

다음: ./09-repos.sh
TXT

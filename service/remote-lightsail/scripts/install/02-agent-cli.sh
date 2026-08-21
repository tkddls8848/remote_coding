#!/usr/bin/env bash
# 호스트 설정 2/3 — Claude Code와 Codex CLI 설치.
#
#   실행 위치: 서버 (ubuntu 계정)

. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

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
이후 서버 재부팅이나 SSH 재접속에 다시 필요하지 않다.

다음: ./install/03-repos.sh
TXT

#!/usr/bin/env bash
# 호스트 설정 2/5 — Claude Code와 Codex CLI 설치.
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

로그인은 Orca 서비스 계정이 생성된 뒤 수행한다. ubuntu 계정으로 먼저 로그인하면
Orca 서비스가 그 자격증명을 볼 수 없다.

다음: ./install/03-private-network.sh
TXT

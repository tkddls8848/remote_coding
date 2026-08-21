#!/usr/bin/env bash
# 서버 쪽 점검 (계획서 검증 절차).
#
#   실행 위치: 서버
#   실패해도 끝까지 돌면서 전부 보여준다.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set +e

fail=0
check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$label"; else warn "$label — 실패"; fail=1; fi
}

say "서비스"
check "stock-chatbot active" systemctl is-active --quiet "$STOCK_CHATBOT_SERVICE"
check "stock-chatbot 부팅 시 자동 시작" systemctl is-enabled --quiet "$STOCK_CHATBOT_SERVICE"

say "개발 CLI"
check "tmux 설치" bash -lc 'command -v tmux'
check "Claude Code 설치" bash -lc 'command -v claude'
check "Codex 설치" bash -lc 'command -v codex'

say "메모리 / 스왑"
free -h
swapon --show | grep -q '/swapfile' && ok "스왑 활성" || { warn "스왑 없음"; fail=1; }

say "최근 로그 (에러만)"
journalctl -u "$STOCK_CHATBOT_SERVICE" --since "10 min ago" --no-pager 2>/dev/null \
    | grep -iE 'error|fatal|denied' | tail -10 || true

echo
[ $fail -eq 0 ] && ok "서버 쪽 점검 통과" || warn "실패 항목이 있다 (위 참고)"

cat <<'TXT'

로컬에서 확인할 나머지:
  terraform -chdir=service/remote-lightsail/terraform plan
  INSTANCE_NAME=$(terraform -chdir=service/remote-lightsail/terraform output -raw instance_name)
  aws lightsail get-instance-port-states --region ap-northeast-2 --instance-name "$INSTANCE_NAME"

사람이 직접 확인할 시나리오:
  1) ssh -t ubuntu@<STATIC_IP> tmux new -As dev 로 접속한다
  2) ~/workspace 에서 Claude Code 또는 Codex를 실행한다
  3) SSH 연결을 끊고 다시 접속해 tmux 세션이 유지되는지 확인한다
  4) sudo reboot 후 stock-chatbot이 자동으로 다시 실행되는지 확인한다
TXT
exit $fail

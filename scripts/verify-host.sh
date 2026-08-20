#!/usr/bin/env bash
# 서버 쪽 점검 (계획서 4절 체크리스트).
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
check "orca-serve active" systemctl is-active --quiet orca-serve
check "caddy active"      systemctl is-active --quiet caddy
check "orca-serve 부팅 시 자동 시작" systemctl is-enabled --quiet orca-serve
check "caddy 부팅 시 자동 시작"      systemctl is-enabled --quiet caddy

say "런타임"
check "127.0.0.1:$ORCA_PORT 웹 번들 응답" \
    curl -fsS -o /dev/null --max-time 5 "http://127.0.0.1:$ORCA_PORT/web-index.html"

if [ -n "$DOMAIN" ]; then
    code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/web-index.html" 2>/dev/null)
    if [ "$code" = "200" ]; then ok "https://$DOMAIN/web-index.html → 200"
    else warn "https://$DOMAIN/web-index.html → ${code:-응답 없음}"; fail=1; fi
fi

say "메모리 / 스왑"
free -h
swapon --show | grep -q '/swapfile' && ok "스왑 활성" || { warn "스왑 없음"; fail=1; }

say "최근 로그 (에러만)"
journalctl -u orca-serve --since "10 min ago" --no-pager 2>/dev/null \
    | grep -iE 'error|fatal|denied' | tail -10 || true

echo
[ $fail -eq 0 ] && ok "서버 쪽 점검 통과" || warn "실패 항목이 있다 (위 참고)"

cat <<'TXT'

로컬에서 확인할 나머지:
  ./scripts/verify-aws.sh     # 방화벽이 443 하나인지

사람이 직접 확인할 시나리오:
  1) 데스크탑에서 붙어 워크트리를 만들고 에이전트를 돌린다
  2) 클라이언트를 완전히 종료한다
  3) 다른 기기(또는 브라우저)로 붙어 같은 세션이 그대로인지 확인한다
  4) sudo reboot 후 사람 개입 없이 다시 붙는지 확인한다
TXT
exit $fail

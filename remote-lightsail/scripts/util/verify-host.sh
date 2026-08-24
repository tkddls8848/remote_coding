#!/usr/bin/env bash
# 서버 쪽 점검. 실패해도 끝까지 확인한 뒤 비정상 종료한다.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set +e

fail=0
check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$label"; else warn "$label — 실패"; fail=1; fi
}

say "Orca 상시 서비스"
check "orca-serve active" systemctl is-active --quiet orca-serve.service
check "orca-serve 부팅 시 자동 시작" systemctl is-enabled --quiet orca-serve.service
check "Orca AppImage" test -x /opt/orca/orca-linux.AppImage
check "Orca 준비 이벤트" bash -lc \
    'sudo journalctl -u orca-serve.service -o cat --no-pager | jq -Re '\''fromjson? | select(.type == "orca_server_ready" and .schemaVersion == 1 and .pairing.available == true and (.advertisedEndpoint | startswith("wss://")) and (.pairing.webClientUrl | startswith("https://")))'\'' >/dev/null'
check "Orca Web Client HTML" curl -fsS "http://127.0.0.1:${ORCA_PORT}/web-index.html"

say "사설망"
check "tailscaled active" systemctl is-active --quiet tailscaled.service
check "Tailscale IPv4" bash -lc 'tailscale ip -4 | grep -Eq "^100\\."'
check "Tailscale Serve HTTPS" bash -lc \
    "sudo tailscale serve status | grep -Fq 'proxy http://127.0.0.1:${ORCA_PORT}'"
check "UFW 활성" bash -lc 'sudo ufw status | grep -q "Status: active"'

say "개발 CLI"
check "Codex 설치" bash -lc 'command -v codex'
check "Claude Code 설치" bash -lc 'command -v claude'
check "GitHub CLI 설치" bash -lc 'command -v gh'
check "Orca 서비스 계정" id "$ORCA_SERVICE_USER"
check "Codex 인증" as_orca codex login status
check "GitHub 인증" as_orca gh auth status

say "메모리 / 스왑"
free -h
swapon --show | grep -q '/swapfile' && ok "스왑 활성" || { warn "스왑 없음"; fail=1; }

say "공인 방화벽 확인 안내"
cat <<'TXT'
Lightsail 공인 방화벽은 TCP 22(관리자 공인 IP /32)만 허용해야 한다.
Orca는 Tailscale Serve HTTPS를 통해서만 접근한다. TCP 6768은 Lightsail 공인 방화벽에 추가하면 안 된다.
TXT

say "현재 Orca 프로세스의 예상 밖 오류"
# 이전 실패 시도의 로그는 제외하고 현재 active 프로세스가 시작된 뒤만 본다.
# GUI 세션이 없는 Electron이 출력하는 D-Bus NameHasOwner 경고는 headless serve의
# 준비 여부와 무관한 알려진 잡음이므로 여기서는 숨긴다.
orca_started_at="$(systemctl show orca-serve.service -p ActiveEnterTimestamp --value 2>/dev/null)"
[ -n "$orca_started_at" ] || orca_started_at="15 min ago"
unexpected_errors="$(journalctl -u orca-serve.service --since "$orca_started_at" --no-pager 2>/dev/null \
    | grep -iE 'error|fatal|denied|oom' \
    | grep -viE 'dbus/(bus|object_proxy)\.cc|Failed to connect to the bus|DBus\.NameHasOwner' \
    | tail -20 || true)"
if [ -n "$unexpected_errors" ]; then
    printf '%s\n' "$unexpected_errors"
else
    ok "현재 프로세스에서 예상 밖 오류 없음"
fi

echo
[ "$fail" -eq 0 ] && ok "서버 점검 통과" || warn "실패 항목이 있다 (위 참고)"

cat <<TXT

브라우저 URL:
  sudo $SCRIPT_DIR/util/show-orca-access.sh

빈 화면 진단:
  sudo $SCRIPT_DIR/util/diagnose-web-client.sh

로컬 인프라 검사:
  terraform -chdir=remote-lightsail/terraform plan
  aws lightsail get-instance-port-states --region ap-northeast-1 --instance-name orca-host-tokyo
TXT
exit "$fail"

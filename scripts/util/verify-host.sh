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
orca_started_at="$(systemctl show orca-serve.service -p ActiveEnterTimestamp --value 2>/dev/null)"
[ -n "$orca_started_at" ] || orca_started_at="15 min ago"
check "Orca 준비 이벤트" bash -lc \
    'sudo journalctl -u orca-serve.service --since "$1" -o cat --no-pager | jq -Re '\''fromjson? | select(.type == "orca_server_ready" and .schemaVersion == 1 and .pairing.available == true and (.advertisedEndpoint | startswith("wss://")) and (.pairing.webClientUrl | startswith("https://")))'\'' >/dev/null' \
    bash "$orca_started_at"
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
if [ -n "$ORCA_SERVICE_PASSWORD" ]; then
    check "$ORCA_SERVICE_USER 로컬 비밀번호 설정됨" bash -lc \
        "sudo passwd -S '$ORCA_SERVICE_USER' | awk '{print \$2}' | grep -qx P"
fi
check "Codex 인증" as_orca codex login status
check "GitHub 인증" as_orca gh auth status

say "VS Code Remote-SSH"
check "$ORCA_SERVICE_USER 로그인 셸" bash -lc \
    "getent passwd '$ORCA_SERVICE_USER' | cut -d: -f7 | grep -qx /bin/bash"
check "$ORCA_SERVICE_USER authorized_keys" bash -lc \
    "sudo test -s \"\$(getent passwd '$ORCA_SERVICE_USER' | cut -d: -f6)/.ssh/authorized_keys\""
check "sshd 드롭인" test -f /etc/ssh/sshd_config.d/60-orca-vscode.conf
check "$ORCA_SERVICE_USER SSH 비밀번호 인증 차단" bash -lc \
    "sudo sshd -T -C user='$ORCA_SERVICE_USER',host=localhost,addr=127.0.0.1 \
        | grep -qix 'passwordauthentication no'"
check "sshd 설정 유효" sudo sshd -t
# sudo 권한은 ORCA_SERVICE_SUDO 가 선언한 상태와 같은지를 본다 (있음/없음 자체가
# 아니라 선언과 실제가 갈라졌는지가 점검 대상이다).
case "$ORCA_SERVICE_SUDO" in
    nopasswd)
        check "$ORCA_SERVICE_USER sudo 비밀번호 없이 허용" bash -lc \
            "sudo -l -U '$ORCA_SERVICE_USER' 2>/dev/null | grep -q 'NOPASSWD: ALL'"
        ;;
    password)
        check "$ORCA_SERVICE_USER sudo 그룹" bash -lc \
            "id -nG '$ORCA_SERVICE_USER' | tr ' ' '\n' | grep -qx -e sudo -e admin"
        ;;
    off)
        check "$ORCA_SERVICE_USER sudo 그룹 아님" bash -lc \
            "! id -nG '$ORCA_SERVICE_USER' | tr ' ' '\n' | grep -qx -e sudo -e admin"
        ;;
    *)
        warn "ORCA_SERVICE_SUDO 값이 잘못됐다: $ORCA_SERVICE_SUDO"
        fail=1
        ;;
esac
check "inotify 감시 한도" bash -lc \
    '[ "$(sysctl -n fs.inotify.max_user_watches)" -ge 524288 ]'

# 이 호스트에 얹힌 다른 프로젝트(입주 앱)의 유닛·경로·포트는 여기서 검사하지 않는다.
# 각 프로젝트가 자기 저장소에서 점검한다 — 예: stock_chatbot 은 infra/scripts/verify-app.sh.
# 여기서는 입주 앱이 호스트 자원을 고갈시키지 않는지만 본다.
say "입주 앱 여유 자원"
check "루트 파일시스템 여유 20% 이상" bash -lc \
    '[ "$(df --output=pcent / | tr -dc 0-9)" -le 80 ]'

say "호스트 시각 기준"
# 입주 앱의 cron.d 백업 시각과 Lightsail 자동 스냅샷 시각이 같은 기준을 보는지는
# 여기서만 확인할 수 있다 — 앱 쪽 스크립트는 호스트 설정을 바꾸지 않는다.
check "타임존 $HOST_TIMEZONE" bash -lc \
    "[ \"\$(timedatectl show -p Timezone --value)\" = '$HOST_TIMEZONE' ]"

say "메모리 / 스왑"
free -h
swapon --show | grep -q '/swapfile' && ok "스왑 활성" || { warn "스왑 없음"; fail=1; }

say "공인 방화벽 확인 안내"
cat <<'TXT'
Lightsail 공인 방화벽의 기본값은 TCP 22(관리자 공인 IP /32)만 허용한다.
입주 앱이 공개 웹을 실제로 서비스할 때만 enable_public_web 으로 80/443 을 연다.
그 밖의 앱 내부 포트와 Orca 의 TCP 6768 은 추가하지 않는다.
Orca는 Tailscale Serve HTTPS를 통해서만 접근한다.
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
  terraform -chdir=terraform plan
  aws lightsail get-instance-port-states --region ap-northeast-1 --instance-name orca-host-tokyo
TXT
exit "$fail"

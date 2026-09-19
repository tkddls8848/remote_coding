#!/usr/bin/env bash
# 호스트 설정 7/7 — 장애 알림, 자원 감시, 보안 이벤트 감사.
#
#   실행 위치: 서버 (ubuntu 계정)
#
# 5절의 알림은 전부 가용성 알림이고(서비스 다운, 디스크 참, OOM), 6.6 은 보안 이벤트를
# 남기는 계층이다. 둘 다 같은 알림 경로(/usr/local/sbin/orca-notify)를 쓴다.
# docs/stability-plan.md 5.1, 5.2, 5.3, 6.6, 11.

. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

[[ "$DISK_WARN_PERCENT" =~ ^[0-9]+$ ]] || die "DISK_WARN_PERCENT 는 숫자여야 한다."
[[ "$SWAP_WARN_PERCENT" =~ ^[0-9]+$ ]] || die "SWAP_WARN_PERCENT 는 숫자여야 한다."

# --- 1. 알림 경로 -----------------------------------------------------------
# 웹훅이 있으면 POST 하고, 없거나 실패하면 로그 파일에만 남긴다. 알림 실패가 감시
# 자체를 중단시키지 않게 항상 0 으로 끝난다.
say "알림 경로 설치 (/usr/local/sbin/orca-notify)"
sudo install -d -o root -g root -m 0750 /etc/orca
sudo tee /etc/orca/alert.env >/dev/null <<CONF
# install/07-monitoring.sh 가 생성. 웹훅은 비밀이므로 root 만 읽는다.
ALERT_WEBHOOK=$(printf '%q' "$ALERT_WEBHOOK")
CONF
sudo chown root:root /etc/orca/alert.env
sudo chmod 0600 /etc/orca/alert.env

sudo tee /usr/local/sbin/orca-notify >/dev/null <<'NOTIFY'
#!/usr/bin/env bash
# install/07-monitoring.sh 가 생성. 알림 한 건을 웹훅과 로컬 로그로 보낸다.
#   orca-notify <심각도> <메시지...>
# 알림 실패가 호출자를 죽이지 않도록 언제나 0 으로 끝난다.
set -uo pipefail

severity="${1:-info}"; shift || true
message="$*"
host="$(hostname)"
stamp="$(date --iso-8601=seconds)"
line="[$severity] $host $stamp — $message"

log=/var/log/orca-alert.log
printf '%s\n' "$line" >> "$log" 2>/dev/null || true
logger -t orca-notify -p "daemon.${severity/critical/err}" -- "$message" 2>/dev/null || true

# shellcheck disable=SC1091
[ -r /etc/orca/alert.env ] && . /etc/orca/alert.env
if [ -n "${ALERT_WEBHOOK:-}" ]; then
    payload="$(printf '%s' "$line" | python3 -c 'import json,sys; print(json.dumps({"text": sys.stdin.read()}))' 2>/dev/null)"
    [ -n "$payload" ] || payload="{\"text\": \"$host $severity\"}"
    curl -fsS -m 10 --retry 2 -X POST -H 'Content-Type: application/json' \
        -d "$payload" "$ALERT_WEBHOOK" >/dev/null 2>&1 \
        || printf '%s\n' "[warn] $host $stamp — webhook POST 실패" >> "$log" 2>/dev/null || true
fi
exit 0
NOTIFY
sudo chown root:root /usr/local/sbin/orca-notify
sudo chmod 0755 /usr/local/sbin/orca-notify
sudo touch /var/log/orca-alert.log
sudo chmod 0640 /var/log/orca-alert.log

sudo tee /etc/logrotate.d/orca-alert >/dev/null <<'CONF'
/var/log/orca-alert.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    create 0640 root root
}
CONF

if [ -n "$ALERT_WEBHOOK" ]; then
    ok "웹훅 설정됨 (/etc/orca/alert.env, 0600 root)"
else
    warn "ALERT_WEBHOOK 이 비어 있다 — 알림은 /var/log/orca-alert.log 에만 남는다."
    warn "config.env 에 웹훅을 적고 util/sync-host.sh 를 다시 돌리면 외부로 나간다."
fi

# --- 2. orca-serve 장애 알림 (5.1) ------------------------------------------
# 유닛이 재시작 한도를 소진해 failed 로 떨어지면 systemd 가 이 유닛을 띄운다.
# 04-orca-server.sh 의 OnFailure=orca-alert@%N.service 가 가리키는 대상이다.
say "systemd OnFailure 훅"
sudo tee /etc/systemd/system/orca-alert@.service >/dev/null <<'UNIT'
[Unit]
Description=Alert that %i failed
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/orca-notify critical "%i 가 failed 상태다. journalctl -u %i -n 100 확인 필요"
UNIT

# OnFailure 는 재시작 한도를 소진한 뒤에만 뜬다. 그 사이의 조용한 다운과 부팅 실패를
# 잡으려면 주기 확인이 따로 필요하다.
sudo tee /etc/systemd/system/orca-watch.service >/dev/null <<'UNIT'
[Unit]
Description=Check that orca-serve is running

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/orca-watch
UNIT

sudo tee /etc/systemd/system/orca-watch.timer >/dev/null <<'UNIT'
[Unit]
Description=Run orca-watch every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
UNIT

sudo tee /usr/local/sbin/orca-watch >/dev/null <<'WATCH'
#!/usr/bin/env bash
# install/07-monitoring.sh 가 생성. orca-serve 가 죽어 있으면 알린다.
# 같은 장애로 5분마다 알림이 쏟아지지 않도록 상태가 바뀔 때만 보낸다.
set -uo pipefail
state_file=/run/orca-watch.state
prev="$(cat "$state_file" 2>/dev/null || echo unknown)"

if systemctl is-active --quiet orca-serve.service; then
    now=up
    [ "$prev" = down ] && /usr/local/sbin/orca-notify info "orca-serve 가 다시 올라왔다"
else
    now=down
    if [ "$prev" != down ]; then
        detail="$(systemctl show orca-serve.service -p ActiveState -p Result --value 2>/dev/null | paste -sd' ' -)"
        /usr/local/sbin/orca-notify critical "orca-serve 가 실행 중이 아니다 ($detail)"
    fi
fi
printf '%s' "$now" > "$state_file" 2>/dev/null || true
exit 0
WATCH
sudo chmod 0755 /usr/local/sbin/orca-watch
ok "orca-alert@.service / orca-watch.timer"

# --- 3. 디스크·메모리 감시 (5.2, 5.3) ---------------------------------------
say "자원 감시 (디스크 ${DISK_WARN_PERCENT}%, 스왑 ${SWAP_WARN_PERCENT}%)"
retry 3 sudo apt-get install -y -qq sysstat || warn "sysstat 설치 실패 — sar 통계 없이 진행한다."
# sysstat 은 패키지 기본값이 수집 비활성이다. 15분 단위 수집을 켠다 (5.3-2).
if [ -f /etc/default/sysstat ]; then
    sudo sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
    sudo systemctl enable --now sysstat.service >/dev/null 2>&1 || true
fi

sudo tee /usr/local/sbin/orca-resource-watch >/dev/null <<WATCH
#!/usr/bin/env bash
# install/07-monitoring.sh 가 생성. 디스크·스왑·OOM 을 본다.
set -uo pipefail
DISK_WARN=$DISK_WARN_PERCENT
SWAP_WARN=$SWAP_WARN_PERCENT
WORKSPACE=/home/$ORCA_SERVICE_USER/workspace
WATCH
sudo tee -a /usr/local/sbin/orca-resource-watch >/dev/null <<'WATCH'

notify() { /usr/local/sbin/orca-notify "$@"; }

# 같은 조건으로 매시간 알리지 않도록 조건별로 최근 알림 시각을 남긴다 (6시간 침묵).
throttle() {
    local key="$1" f="/run/orca-watch.$1" now
    now="$(date +%s)"
    if [ -f "$f" ] && [ $(( now - $(cat "$f" 2>/dev/null || echo 0) )) -lt 21600 ]; then
        return 1
    fi
    printf '%s' "$now" > "$f" 2>/dev/null || true
    return 0
}

# 디스크 — 꽉 차면 Orca 가 크래시하고 데이터가 상한다 (5.2).
disk_pct="$(df --output=pcent / | tr -dc '0-9')"
if [ "${disk_pct:-0}" -ge "$DISK_WARN" ]; then
    if throttle disk; then
        top="$(du -xh --max-depth=1 / 2>/dev/null | sort -rh | head -5 | tr '\n' ' ')"
        notify warning "루트 파일시스템 ${disk_pct}% 사용 (기준 ${DISK_WARN}%). 상위: $top"
    fi
fi

# 스왑 지속 사용은 성능 저하와 데이터 장애의 전조다 (5.3).
read -r swap_total swap_used < <(free -m | awk '/^Swap:/ {print $2, $3}')
if [ "${swap_total:-0}" -gt 0 ]; then
    swap_pct=$(( swap_used * 100 / swap_total ))
    if [ "$swap_pct" -ge "$SWAP_WARN" ] && throttle swap; then
        notify warning "스왑 ${swap_pct}% 사용 (${swap_used}M/${swap_total}M, 기준 ${SWAP_WARN}%)"
    fi
else
    throttle noswap && notify warning "스왑이 활성화되어 있지 않다 (install/01-host-base.sh 확인)"
fi

# OOM kill 은 로그에만 남고 아무도 보지 않는다. 마지막 확인 시점 이후만 본다.
oom_marker=/run/orca-watch.oom-since
since="$(cat "$oom_marker" 2>/dev/null || echo '-1h')"
oom="$(journalctl -k --since "$since" --no-pager 2>/dev/null \
    | grep -iE 'killed process|out of memory' | tail -3 || true)"
date --iso-8601=seconds > "$oom_marker" 2>/dev/null || true
if [ -n "$oom" ]; then
    notify critical "OOM kill 감지: $(printf '%s' "$oom" | tr '\n' ' | ')"
fi

# 워크스페이스 증가 추이 — 어디가 먹는지 나중에 되짚을 수 있게 남긴다 (5.2-3).
if [ -d "$WORKSPACE" ]; then
    printf '%s %s\n' "$(date --iso-8601=seconds)" "$(du -sk "$WORKSPACE" 2>/dev/null | awk '{print $1}')" \
        >> /var/log/orca-workspace-size.log 2>/dev/null || true
fi
exit 0
WATCH
sudo chmod 0755 /usr/local/sbin/orca-resource-watch

sudo tee /etc/systemd/system/orca-resource-watch.service >/dev/null <<'UNIT'
[Unit]
Description=Check disk, swap and OOM state

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/orca-resource-watch
UNIT

sudo tee /etc/systemd/system/orca-resource-watch.timer >/dev/null <<'UNIT'
[Unit]
Description=Run orca-resource-watch hourly

[Timer]
OnBootSec=5min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
UNIT
ok "orca-resource-watch.timer"

# --- 4. 보안 이벤트 감사 (6.6) ----------------------------------------------
say "auditd 최소 규칙"
if retry 3 sudo apt-get install -y -qq auditd audispd-plugins; then
    sudo tee /etc/audit/rules.d/60-orca.rules >/dev/null <<'RULES'
# install/07-monitoring.sh 가 생성. docs/stability-plan.md 6.6-2.
# 이 호스트에서 "침해 범위를 특정"하려면 최소한 아래 네 곳의 변경은 남아야 한다.
-w /etc/sudoers -p wa -k orca_privesc
-w /etc/sudoers.d/ -p wa -k orca_privesc
-w /home/orca/.ssh/authorized_keys -p wa -k orca_access
-w /home/ubuntu/.ssh/authorized_keys -p wa -k orca_access
-w /opt/orca/orca-linux.AppImage -p wa -k orca_binary
-w /etc/systemd/system/ -p wa -k orca_units
-w /etc/ssh/sshd_config.d/ -p wa -k orca_access
RULES
    sudo augenrules --load >/dev/null 2>&1 || sudo systemctl restart auditd || true
    sudo systemctl enable auditd >/dev/null 2>&1 || true
    ok "auditd 규칙 적용 (ausearch -k orca_privesc 로 조회)"
else
    warn "auditd 설치 실패 — 6.6-2 는 적용되지 않았다."
fi

# SSH 로그인 알림 (6.6-3). PAM 세션 시작 시점에 알린다.
say "SSH 로그인 알림"
sudo tee /usr/local/sbin/orca-ssh-login-notify >/dev/null <<'LOGIN'
#!/usr/bin/env bash
# install/07-monitoring.sh 가 생성. sshd PAM 세션 열림에서 호출된다.
set -uo pipefail
[ "${PAM_TYPE:-}" = open_session ] || exit 0
/usr/local/sbin/orca-notify info \
    "SSH 로그인: user=${PAM_USER:-?} from=${PAM_RHOST:-?} service=${PAM_SERVICE:-?}"
exit 0
LOGIN
sudo chmod 0755 /usr/local/sbin/orca-ssh-login-notify

pam_line='session optional pam_exec.so quiet /usr/local/sbin/orca-ssh-login-notify'
if grep -qF "$pam_line" /etc/pam.d/sshd; then
    ok "PAM 훅 이미 등록됨"
else
    # 앞에 주석을 붙여 어디서 왔는지 남긴다. pam_exec 는 optional 이므로 실패해도
    # 로그인을 막지 않는다.
    printf '\n# install/07-monitoring.sh 가 추가 (docs/stability-plan.md 6.6-3)\n%s\n' \
        "$pam_line" | sudo tee -a /etc/pam.d/sshd >/dev/null
    ok "PAM 훅 등록"
fi

# --- 5. GitHub 토큰 유효성 (6.7) --------------------------------------------
say "GitHub 토큰 주간 점검"
sudo tee /usr/local/sbin/orca-token-check >/dev/null <<TOKEN
#!/usr/bin/env bash
# install/07-monitoring.sh 가 생성. 토큰 존재가 아니라 유효성을 본다 (6.7-1).
set -uo pipefail
if ! sudo -u $ORCA_SERVICE_USER -H /bin/bash -c 'cd "\$HOME" && exec gh api user -q .login' >/dev/null 2>&1; then
    /usr/local/sbin/orca-notify critical "GitHub 토큰이 유효하지 않다 (gh api user 실패). 에이전트의 push 가 막힌다."
fi
if ! sudo -u $ORCA_SERVICE_USER -H /bin/bash -c 'cd "\$HOME" && exec codex login status' >/dev/null 2>&1; then
    /usr/local/sbin/orca-notify warning "Codex 인증이 유효하지 않다 (codex login status 실패)."
fi
exit 0
TOKEN
sudo chmod 0755 /usr/local/sbin/orca-token-check

sudo tee /etc/systemd/system/orca-token-check.service >/dev/null <<'UNIT'
[Unit]
Description=Check agent credentials are still valid

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/orca-token-check
UNIT

sudo tee /etc/systemd/system/orca-token-check.timer >/dev/null <<'UNIT'
[Unit]
Description=Run orca-token-check weekly

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# --- 5b. Orca 새 버전 확인 (8.1) --------------------------------------------
say "Orca 버전 주간 확인"
update_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/util/check-orca-update.sh"
sudo tee /etc/systemd/system/orca-update-check.service >/dev/null <<UNIT
[Unit]
Description=Check for a newer Orca release

[Service]
Type=oneshot
User=$(id -un)
# 새 버전이 있으면 스크립트가 1 로 끝나므로 실패로 보지 않는다.
ExecStart=/bin/bash -lc '$update_path --notify || true'
UNIT

sudo tee /etc/systemd/system/orca-update-check.timer >/dev/null <<'UNIT'
[Unit]
Description=Run check-orca-update.sh weekly

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# --- 6. 드리프트·점검 정기 실행 (6.6-4, 11.4) -------------------------------
say "verify-host 일일 실행"
verify_path="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/util/verify-host.sh"
sudo tee /etc/systemd/system/orca-verify.service >/dev/null <<UNIT
[Unit]
Description=Daily host verification (drift and health)

[Service]
Type=oneshot
User=$(id -un)
ExecStart=/bin/bash -lc '$verify_path || /usr/local/sbin/orca-notify warning "verify-host.sh 에 실패 항목이 있다"'
UNIT

sudo tee /etc/systemd/system/orca-verify.timer >/dev/null <<'UNIT'
[Unit]
Description=Run verify-host.sh daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
UNIT

# --- 7. 활성화 --------------------------------------------------------------
sudo systemctl daemon-reload
for t in orca-watch orca-resource-watch orca-token-check orca-update-check orca-verify; do
    sudo systemctl enable --now "$t.timer" >/dev/null
    ok "$t.timer 활성"
done

echo
ok "감시·감사 계층 설치 완료"
cat <<TXT

확인:
  systemctl list-timers 'orca-*' --no-pager
  sudo /usr/local/sbin/orca-notify info "테스트 알림"
  tail -5 /var/log/orca-alert.log
  sudo sudoreplay -l            # root 로 실행한 내역
  sudo ausearch -k orca_privesc # sudoers 변경 시도

점검: ./util/verify-host.sh
TXT

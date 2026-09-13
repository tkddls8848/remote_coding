#!/usr/bin/env bash
# 호스트 설정 6/6 — VS Code Remote-SSH 접속 (Orca 서비스 계정).
#
#   실행 위치: 서버 (ubuntu 계정)
#
# VS Code는 에이전트와 같은 계정으로 붙는다. ubuntu로 붙어 /home/orca/workspace를
# 편집하면 새 파일 소유자가 갈라져 Orca가 쓰지 못하는 경로가 생긴다.
# 그래서 orca에 로그인 셸과 공개키를 주되, sudo 없이 키 인증만 허용한다.

. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

id "$ORCA_SERVICE_USER" >/dev/null 2>&1 \
    || die "Orca 서비스 계정이 없다. 먼저 ./install/04-orca-server.sh를 실행할 것."

ORCA_HOME="$(getent passwd "$ORCA_SERVICE_USER" | cut -d: -f6)"
[ -n "$ORCA_HOME" ] && [ -d "$ORCA_HOME" ] \
    || die "$ORCA_SERVICE_USER 의 홈 디렉터리를 찾지 못했다."
ORCA_GROUP="$(id -gn "$ORCA_SERVICE_USER")"

# --- 1. VS Code Server 실행 전제 --------------------------------------------
# 서버 측 부트스트랩은 tar 아카이브를 내려받아 푼다. Node는 번들이라 별도 설치가 없다.
say "VS Code Server 전제 패키지"
export DEBIAN_FRONTEND=noninteractive
sudo apt-get install -y -qq curl wget tar
ok "curl / wget / tar"

# --- 2. 로그인 셸 -----------------------------------------------------------
current_shell="$(getent passwd "$ORCA_SERVICE_USER" | cut -d: -f7)"
if [ "$current_shell" = /bin/bash ]; then
    ok "$ORCA_SERVICE_USER 로그인 셸 이미 /bin/bash"
else
    say "$ORCA_SERVICE_USER 로그인 셸을 /bin/bash 로 변경 (기존: $current_shell)"
    sudo usermod --shell /bin/bash "$ORCA_SERVICE_USER"
fi

# 서비스 계정에 셸을 준 이상 권한 상승 경로가 없는지는 명시적으로 확인한다.
if id -nG "$ORCA_SERVICE_USER" | tr ' ' '\n' | grep -qx -e sudo -e admin; then
    warn "$ORCA_SERVICE_USER 가 sudo 그룹에 있다. 서비스 계정에는 필요하지 않다:"
    warn "  sudo deluser $ORCA_SERVICE_USER sudo"
else
    ok "$ORCA_SERVICE_USER 는 sudo 그룹이 아님"
fi

# --- 3. 공개키 ---------------------------------------------------------------
# 관리 PC가 이미 ubuntu로 붙고 있으므로 같은 Lightsail 키페어를 그대로 쓴다.
admin_home="$(getent passwd ubuntu | cut -d: -f6)"
[ -n "$admin_home" ] || die "ubuntu 계정을 찾지 못했다. Lightsail 기본 관리 계정이 필요하다."
src_keys="$admin_home/.ssh/authorized_keys"
sudo test -s "$src_keys" \
    || die "ubuntu 계정의 authorized_keys가 비어 있다: $src_keys
  Lightsail 키페어로 접속 중인지 확인할 것."

sudo install -d -o "$ORCA_SERVICE_USER" -g "$ORCA_GROUP" -m 0700 "$ORCA_HOME/.ssh"
sudo touch "$ORCA_HOME/.ssh/authorized_keys"

# 이미 있는 키는 유지하고 없는 키만 더한다 (멱등, 순서 무관).
added="$(sudo bash -c '
    set -euo pipefail
    src="$1"; dst="$2"
    tmp="$(mktemp)"
    trap "rm -f \"$tmp\"" EXIT
    cat "$dst" > "$tmp"
    # 끝에 개행이 없으면 append 한 키가 마지막 줄에 붙어버린다.
    if [ -s "$tmp" ] && [ -n "$(tail -c1 "$tmp")" ]; then echo >> "$tmp"; fi
    n=0
    while IFS= read -r line; do
        case "$line" in ""|\#*) continue ;; esac
        grep -qxF "$line" "$tmp" || { printf "%s\n" "$line" >> "$tmp"; n=$((n + 1)); }
    done < "$src"
    cat "$tmp" > "$dst"
    printf "%s" "$n"
' bash "$src_keys" "$ORCA_HOME/.ssh/authorized_keys")"

sudo chown "$ORCA_SERVICE_USER:$ORCA_GROUP" "$ORCA_HOME/.ssh/authorized_keys"
sudo chmod 0600 "$ORCA_HOME/.ssh/authorized_keys"
# sshd StrictModes는 홈이 그룹/기타 쓰기 가능이면 키를 무시한다.
sudo chmod g-w,o-w "$ORCA_HOME"
ok "authorized_keys 구성 (신규 ${added}개)"

# --- 4. sshd ----------------------------------------------------------------
say "sshd: $ORCA_SERVICE_USER 는 키 인증 전용"
sshd_dropin=/etc/ssh/sshd_config.d/60-orca-vscode.conf
sudo tee "$sshd_dropin" >/dev/null <<CONF
# install/06-vscode-remote.sh 가 생성. VS Code Remote-SSH 용 $ORCA_SERVICE_USER 로그인.
#
# /etc/ssh/sshd_config 의 Include 는 파일 맨 위에 있다. 이 파일이 Match 블록으로 끝나면
# 메인 설정의 나머지 전체가 그 Match 안으로 들어간다. 반드시 'Match all' 로 닫는다.
Match User $ORCA_SERVICE_USER
    PubkeyAuthentication yes
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    PermitTTY yes
    AllowTcpForwarding yes
    AllowAgentForwarding no
    X11Forwarding no
Match all
CONF
sudo chmod 0644 "$sshd_dropin"

if ! sshd_check="$(sudo sshd -t 2>&1)"; then
    sudo rm -f "$sshd_dropin"
    printf '%s\n' "$sshd_check" >&2
    die "sshd 설정 검증 실패. 드롭인을 되돌렸다."
fi
sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd
ok "sshd 반영"

# --- 5. 파일 감시 한도 -------------------------------------------------------
# VS Code는 워크스페이스 전체를 inotify로 감시한다. 기본 한도로는 저장소 몇 개만 열어도
# "Visual Studio Code is unable to watch for file changes" 가 뜬다.
say "inotify 한도 상향"
sudo tee /etc/sysctl.d/60-vscode-remote.conf >/dev/null <<'CONF'
# install/06-vscode-remote.sh 가 생성. VS Code Remote-SSH 파일 감시용.
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
CONF
sudo sysctl -q --system
ok "max_user_watches = $(sysctl -n fs.inotify.max_user_watches)"

# --- 6. VS Code Server 설치 위치 --------------------------------------------
sudo install -d -o "$ORCA_SERVICE_USER" -g "$ORCA_GROUP" -m 0700 "$ORCA_HOME/.vscode-server"
ok "$ORCA_HOME/.vscode-server"

# --- 7. 접속 정보 -----------------------------------------------------------
tailscale_dns=""
if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    tailscale_dns="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' || true)"
    tailscale_dns="${tailscale_dns%.}"
fi
host_target="${tailscale_dns:-$(hostname -I | awk '{print $1}')}"

echo
ok "VS Code Remote-SSH 준비 완료"
cat <<TXT

관리 PC(같은 tailnet)의 ~/.ssh/config 에 추가한다:

  Host orca
      HostName ${host_target}
      User ${ORCA_SERVICE_USER}
      IdentityFile ~/.ssh/id_ed25519
      ServerAliveInterval 30
      ServerAliveCountMax 6

VS Code에서 Remote-SSH: Connect to Host... → orca → 폴더 열기:

  ${ORCA_HOME}/workspace

TXT

if [ -n "$tailscale_dns" ]; then
    ok "Tailscale MagicDNS 이름으로 접속한다: $tailscale_dns"
    echo "  공인 IP는 관리자 IP가 바뀔 때마다 terraform apply 로 /32 규칙을 갱신해야 한다."
else
    warn "Tailscale MagicDNS 이름을 찾지 못해 로컬 IP를 적었다."
    warn "Tailscale 연결 후 이 스크립트를 다시 실행하면 tailnet 주소로 갱신된다."
fi

echo
warn "4GB(medium_3_0)에서 VS Code Server와 확장은 Orca와 메모리를 나눠 쓴다."
warn "무거운 확장(원격 언어 서버, 인덱서)을 상시 켜 두려면 large_3_0(8GB) 이상을 권장한다."
echo
echo "점검: ./util/verify-host.sh"

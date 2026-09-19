#!/usr/bin/env bash
# 호스트 설정 6/6 — VS Code Remote-SSH 접속 (Orca 서비스 계정).
#
#   실행 위치: 서버 (ubuntu 계정)
#
# VS Code는 에이전트와 같은 계정으로 붙는다. ubuntu로 붙어 /home/orca/workspace를
# 편집하면 새 파일 소유자가 갈라져 Orca가 쓰지 못하는 경로가 생긴다.
# 그래서 orca에 로그인 셸과 공개키를 주고, SSH는 키 인증만 받는다.
# 이 계정의 sudo 권한은 04-orca-server.sh 가 ORCA_SERVICE_SUDO 로 정한다.
#
# 공개키는 orca 전용 키를 쓴다(ORCA_SSH_PUBLIC_KEY). ubuntu 의 키를 복사하면 키 하나가
# 두 계정을 동시에 열고, orca 는 sudo 를 가지므로 키 탈취가 곧 호스트 root 다.
# docs/stability-plan.md 6.3.

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

# 셸을 준 이상 권한 상승 경로가 어디까지인지는 눈에 보이게 남긴다. 값을 바꾸는 곳은
# 04-orca-server.sh 하나뿐이다 (여기서 고치면 두 벌이 되어 갈라진다).
if id -nG "$ORCA_SERVICE_USER" | tr ' ' '\n' | grep -qx -e sudo -e admin; then
    ok "$ORCA_SERVICE_USER 는 sudo 그룹 (ORCA_SERVICE_SUDO=$ORCA_SERVICE_SUDO)"
    [ "$ORCA_SERVICE_SUDO" = off ] \
        && warn "설정은 off 인데 그룹에 남아 있다. ./install/04-orca-server.sh 를 다시 돌릴 것."
else
    ok "$ORCA_SERVICE_USER 는 sudo 그룹이 아님 (ORCA_SERVICE_SUDO=$ORCA_SERVICE_SUDO)"
    [ "$ORCA_SERVICE_SUDO" = off ] \
        || warn "설정은 $ORCA_SERVICE_SUDO 인데 권한이 없다. ./install/04-orca-server.sh 를 다시 돌릴 것."
fi

# --- 3. 공개키 ---------------------------------------------------------------
# orca 는 sudo 를 가진다. ubuntu 의 키를 그대로 복사하면 키 하나가 두 계정을 동시에 열고,
# ubuntu 키 탈취가 곧 호스트 root 다 — 계정 분리가 형식으로만 남는다.
# 그래서 기본은 orca 전용 키다. docs/stability-plan.md 6.3.
#
# 관리 PC에서:
#   ssh-keygen -t ed25519 -f ~/.ssh/orca_vscode -C "vscode->orca"
# 그리고 config.env 에:
#   ORCA_SSH_PUBLIC_KEY=~/.ssh/orca_vscode.pub
admin_home="$(getent passwd ubuntu | cut -d: -f6)"
[ -n "$admin_home" ] || die "ubuntu 계정을 찾지 못했다. Lightsail 기본 관리 계정이 필요하다."
admin_keys="$admin_home/.ssh/authorized_keys"

new_keys="$(mktemp)"
trap 'rm -f "$new_keys"' EXIT

if [ -n "$ORCA_SSH_PUBLIC_KEY" ]; then
    case "$ORCA_SSH_PUBLIC_KEY" in
        ssh-*|ecdsa-*|sk-ssh-*|sk-ecdsa-*) printf '%s\n' "$ORCA_SSH_PUBLIC_KEY" > "$new_keys" ;;
        *)
            [ -f "$ORCA_SSH_PUBLIC_KEY" ] \
                || die "ORCA_SSH_PUBLIC_KEY 가 공개키 원문도, 이 서버에 있는 파일도 아니다: $ORCA_SSH_PUBLIC_KEY
  로컬 config.env 에 파일 경로로 적었다면 util/sync-host.sh 를 다시 돌린다 (내용으로 풀어 보낸다)."
            cat "$ORCA_SSH_PUBLIC_KEY" > "$new_keys"
            ;;
    esac
    ok "orca 전용 공개키 사용"
elif [ "$ORCA_SSH_REUSE_ADMIN_KEY" = 1 ]; then
    sudo test -s "$admin_keys" \
        || die "ubuntu 계정의 authorized_keys가 비어 있다: $admin_keys
  Lightsail 키페어로 접속 중인지 확인할 것."
    sudo cat "$admin_keys" > "$new_keys"
    warn "ubuntu 의 키를 orca 로 복사한다 (ORCA_SSH_REUSE_ADMIN_KEY=1)."
    warn "키 하나가 두 계정을 연다 — ubuntu 키가 털리면 orca 를 거쳐 그대로 호스트 root 다."
else
    die "orca 에 등록할 공개키가 없다.
  전용 키를 만들어 config.env 의 ORCA_SSH_PUBLIC_KEY 에 적고 util/sync-host.sh 를 다시 돌린다:
    ssh-keygen -t ed25519 -f ~/.ssh/orca_vscode -C \"vscode->orca\"
    ORCA_SSH_PUBLIC_KEY=~/.ssh/orca_vscode.pub
  ubuntu 의 키를 그대로 쓰려면(권장하지 않음) ORCA_SSH_REUSE_ADMIN_KEY=1 로 둔다.
  docs/stability-plan.md 6.3 참조."
fi

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
' bash "$new_keys" "$ORCA_HOME/.ssh/authorized_keys")"

sudo chown "$ORCA_SERVICE_USER:$ORCA_GROUP" "$ORCA_HOME/.ssh/authorized_keys"
sudo chmod 0600 "$ORCA_HOME/.ssh/authorized_keys"
# sshd StrictModes는 홈이 그룹/기타 쓰기 가능이면 키를 무시한다.
sudo chmod g-w,o-w "$ORCA_HOME"
ok "authorized_keys 구성 (신규 ${added}개)"

# 두 계정의 키가 겹치면 계정 분리가 형식으로만 남는다. 상태를 눈에 보이게 남긴다.
# 비교는 키 타입+본문만 본다 (주석/옵션은 다를 수 있다).
keyprint() { sudo awk 'NF >= 2 && $1 !~ /^#/ { print $1" "$2 }' "$1" 2>/dev/null | sort -u; }
shared="$(comm -12 <(keyprint "$admin_keys") <(keyprint "$ORCA_HOME/.ssh/authorized_keys") | wc -l)"
if [ "${shared:-0}" -gt 0 ]; then
    warn "ubuntu 와 $ORCA_SERVICE_USER 가 공개키 ${shared}개를 공유한다."
    warn "그 키 하나가 두 계정을 동시에 열고, $ORCA_SERVICE_USER 는 sudo 를 가진다 (6.3)."
else
    ok "ubuntu 와 $ORCA_SERVICE_USER 의 공개키가 겹치지 않는다"
fi

# 키 교체 절차는 docs/lightsail-plan.md 4.3 "SSH 키 교체" 에 있다.

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
      IdentityFile ~/.ssh/orca_vscode
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
# --- 8. 드리프트 기준값 ------------------------------------------------------
# authorized_keys 가 나중에 바뀌면 verify-host.sh 가 알아챈다 (6.6-4).
sudo install -d -o root -g root -m 0700 "$BASELINE_DIR"
sudo sha256sum "$ORCA_HOME/.ssh/authorized_keys" | awk '{print $1}' \
    | sudo tee "$BASELINE_DIR/orca-authorized-keys.sha256" >/dev/null
sudo chmod 0600 "$BASELINE_DIR/orca-authorized-keys.sha256"
ok "authorized_keys 기준값 기록"

echo
echo "다음: ./install/07-monitoring.sh"
echo "점검: ./util/verify-host.sh"

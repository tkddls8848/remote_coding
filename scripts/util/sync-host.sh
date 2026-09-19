#!/usr/bin/env bash
# 호스트에서 실행할 CLI 스크립트와 설정을 서버로 복사한다.
#
#   실행 위치: 로컬
#   전제: terraform apply (terraform/) 로 인스턴스가 떠 있고, SSH 가 열려 있을 것
#         (build/final 모두 SSH 22가 현재 공인 IP에 열려 있음)

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need scp
need ssh
need terraform

STATIC_IP="${STATIC_IP:-$(tf_output static_ip)}"
[ -n "$STATIC_IP" ] || die "고정 IP 를 찾을 수 없다. terraform apply 를 먼저 실행할 것 (terraform/README.md)."
export STATIC_IP

# Keep the Tailscale MagicDNS name aligned with the stable Lightsail instance name.
# The default Ubuntu EC2 hostname (ip-172-...) can change when an instance is rebuilt.
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-$(tf_output instance_name)}"

say "대상: ubuntu@$STATIC_IP"

# 기본 키가 아닌 키로 만든 인스턴스면 provision-host.sh 가 SSH_KEY 를 넘겨준다.
SSH_ARGS=(-o StrictHostKeyChecking=accept-new)
[ -n "${SSH_KEY:-}" ] && SSH_ARGS+=(-o IdentitiesOnly=yes -i "$SSH_KEY")

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<TXT
# sync-host.sh 가 생성. 서버 스크립트가 읽는다.
REPOS="${REPOS:-all}"
REPOS_EXCLUDE="${REPOS_EXCLUDE:-}"
REPOS_LIMIT="${REPOS_LIMIT:-300}"
REPOS_INCLUDE_FORKS="${REPOS_INCLUDE_FORKS:-0}"
REPOS_INCLUDE_ARCHIVED="${REPOS_INCLUDE_ARCHIVED:-0}"
GITHUB_OWNER="${GITHUB_OWNER:-}"
ORCA_VERSION="${ORCA_VERSION:-v1.4.188}"
ORCA_PORT="${ORCA_PORT:-6768}"
ORCA_SERVICE_USER="${ORCA_SERVICE_USER:-orca}"
ORCA_SERVICE_SUDO="${ORCA_SERVICE_SUDO:-nopasswd}"
ORCA_SUDO_LOG="${ORCA_SUDO_LOG:-on}"
ORCA_SUDO_LOG_DIR="${ORCA_SUDO_LOG_DIR:-/var/log/sudo-io}"
ORCA_SERVICE_PASSWORD_MIN_LEN="${ORCA_SERVICE_PASSWORD_MIN_LEN:-16}"
ORCA_MEMORY_HIGH="${ORCA_MEMORY_HIGH:-2G}"
ORCA_MEMORY_MAX="${ORCA_MEMORY_MAX:-2800M}"
ORCA_SHA256="${ORCA_SHA256:-}"
ORCA_REQUIRE_CHECKSUM="${ORCA_REQUIRE_CHECKSUM:-0}"
ORCA_MIN_BYTES="${ORCA_MIN_BYTES:-52428800}"
ORCA_PAIRING_ADDRESS="${ORCA_PAIRING_ADDRESS:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-}"
HOST_TIMEZONE="${HOST_TIMEZONE:-UTC}"
CLAUDE_CODE_VERSION="${CLAUDE_CODE_VERSION:-latest}"
CODEX_VERSION="${CODEX_VERSION:-latest}"
ORCA_SSH_REUSE_ADMIN_KEY="${ORCA_SSH_REUSE_ADMIN_KEY:-0}"
DISK_WARN_PERCENT="${DISK_WARN_PERCENT:-80}"
SWAP_WARN_PERCENT="${SWAP_WARN_PERCENT:-70}"
JOURNAL_MAX_USE="${JOURNAL_MAX_USE:-500M}"
BACKUP_S3_URI="${BACKUP_S3_URI:-}"
BACKUP_KMS_KEY_ID="${BACKUP_KMS_KEY_ID:-}"
BACKUP_INCLUDE_CREDENTIALS="${BACKUP_INCLUDE_CREDENTIALS:-0}"
BACKUP_LOCAL_DIR="${BACKUP_LOCAL_DIR:-/var/backups/orca}"
TXT
# 아래 값들은 셸 메타문자·줄바꿈·비밀을 담을 수 있다. host.env 는 그대로 source 되므로
# 인용해서 쓴다.
printf 'ORCA_SERVICE_PASSWORD=%q\n'  "${ORCA_SERVICE_PASSWORD:-}"  >> "$tmp"
printf 'ORCA_SUDO_WHITELIST=%q\n'    "${ORCA_SUDO_WHITELIST:-}"    >> "$tmp"
printf 'ALERT_WEBHOOK=%q\n'          "${ALERT_WEBHOOK:-}"          >> "$tmp"
# 로컬에서는 파일 경로로 적는 편이 자연스럽지만 서버는 그 파일을 볼 수 없다.
# 경로면 여기서 내용으로 풀어 보낸다.
vscode_key="${ORCA_SSH_PUBLIC_KEY:-}"
if [ -n "$vscode_key" ]; then
    key_path="${vscode_key/#\~/$HOME}"
    if [ -f "$key_path" ]; then
        vscode_key="$(head -1 "$key_path")"
    fi
    case "$vscode_key" in
        ssh-*|ecdsa-*|sk-ssh-*|sk-ecdsa-*) ;;
        *) die "ORCA_SSH_PUBLIC_KEY 가 OpenSSH 공개키도, 읽을 수 있는 파일 경로도 아니다: $vscode_key" ;;
    esac
fi
printf 'ORCA_SSH_PUBLIC_KEY=%q\n'    "$vscode_key"                 >> "$tmp"

ssh "${SSH_ARGS[@]}" "ubuntu@$STATIC_IP" 'rm -rf ~/remote-lightsail-scripts && mkdir -p ~/remote-lightsail-scripts'
scp "${SSH_ARGS[@]}" -qr "$SCRIPT_DIR"/install "$SCRIPT_DIR"/util "ubuntu@$STATIC_IP:~/remote-lightsail-scripts/"
scp "${SSH_ARGS[@]}" -q "$tmp" "ubuntu@$STATIC_IP:~/remote-lightsail-scripts/host.env"
# host.env 는 이제 서비스 계정 비밀번호를 담으므로 ubuntu 만 읽게 한다.
ssh "${SSH_ARGS[@]}" "ubuntu@$STATIC_IP" 'find ~/remote-lightsail-scripts -type f -name "*.sh" -exec chmod +x {} + && chmod 600 ~/remote-lightsail-scripts/host.env'
ok "복사 완료"

# 단독 실행할 때만 다음 단계를 안내한다. provision-host.sh가 호출한 경우에는
# 상위 스크립트가 같은 안내를 한 번만 출력한다.
if [ "${SYNC_SHOW_NEXT_STEPS:-1}" = 1 ]; then
cat <<TXT

서버에 붙어서 순서대로 실행한다:

  ssh ubuntu@$STATIC_IP
  cd ~/remote-lightsail-scripts
  ./install/01-host-base.sh  # 툴체인 + 스왑 + Node
  ./install/02-agent-cli.sh  # Claude/Codex CLI 설치 (로그인은 사람이 직접)
  ./install/03-private-network.sh  # 최초 실행 시 인증 URL을 출력하고 완료될 때까지 대기
  ./install/04-orca-server.sh
  sudo -u orca -H /bin/bash -c 'cd "\$HOME" && exec codex login --device-auth'
  sudo -u orca -H /bin/bash -c 'cd "\$HOME" && exec gh auth login'
  ./install/05-repos.sh
  ./install/06-vscode-remote.sh
  ./install/07-monitoring.sh
  sudo ./util/show-orca-access.sh
  ./util/verify-host.sh
TXT
fi

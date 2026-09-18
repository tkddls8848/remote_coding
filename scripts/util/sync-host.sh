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
GITHUB_OWNER="${GITHUB_OWNER:-}"
ORCA_VERSION="${ORCA_VERSION:-v1.4.188}"
ORCA_PORT="${ORCA_PORT:-6768}"
ORCA_SERVICE_USER="${ORCA_SERVICE_USER:-orca}"
ORCA_SERVICE_SUDO="${ORCA_SERVICE_SUDO:-nopasswd}"
ORCA_PAIRING_ADDRESS="${ORCA_PAIRING_ADDRESS:-}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-}"
HOST_TIMEZONE="${HOST_TIMEZONE:-UTC}"
TXT
# 비밀번호에는 셸 메타문자가 들어갈 수 있다. host.env 는 그대로 source 되므로 인용해 쓴다.
printf 'ORCA_SERVICE_PASSWORD=%q\n' "${ORCA_SERVICE_PASSWORD:-}" >> "$tmp"

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
  sudo ./util/show-orca-access.sh
  ./util/verify-host.sh
TXT
fi

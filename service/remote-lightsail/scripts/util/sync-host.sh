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

say "대상: ubuntu@$STATIC_IP"

# 기본 키가 아닌 키로 만든 인스턴스면 provision-host.sh 가 SSH_KEY 를 넘겨준다.
SSH_ARGS=(-o StrictHostKeyChecking=accept-new)
[ -n "${SSH_KEY:-}" ] && SSH_ARGS+=(-o IdentitiesOnly=yes -i "$SSH_KEY")

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<TXT
# sync-host.sh 가 생성. 서버 스크립트가 읽는다.
REPOS="${REPOS:-}"
GITHUB_OWNER="${GITHUB_OWNER:-}"
STOCK_CHATBOT_SERVICE="${STOCK_CHATBOT_SERVICE:-stock-chatbot}"
TXT

ssh "${SSH_ARGS[@]}" "ubuntu@$STATIC_IP" 'rm -rf ~/remote-lightsail-scripts && mkdir -p ~/remote-lightsail-scripts'
scp "${SSH_ARGS[@]}" -qr "$SCRIPT_DIR"/install "$SCRIPT_DIR"/util "ubuntu@$STATIC_IP:~/remote-lightsail-scripts/"
scp "${SSH_ARGS[@]}" -q "$tmp" "ubuntu@$STATIC_IP:~/remote-lightsail-scripts/host.env"
ssh "${SSH_ARGS[@]}" "ubuntu@$STATIC_IP" 'find ~/remote-lightsail-scripts -type f -name "*.sh" -exec chmod +x {} +'
ok "복사 완료"

cat <<TXT

서버에 붙어서 순서대로 실행한다:

  ssh ubuntu@$STATIC_IP
  cd ~/remote-lightsail-scripts
  ./install/01-host-base.sh  # 툴체인 + 스왑 2GB + Node + tmux
  ./install/02-agent-cli.sh  # Claude/Codex CLI 설치 (로그인은 사람이 직접)
  ./install/03-repos.sh      # 개발 레포 클론
  ./util/verify-host.sh      # CLI + stock_chatbot 점검
TXT

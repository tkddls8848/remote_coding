#!/usr/bin/env bash
# 호스트에서 실행할 스크립트(03~09)와 설정을 서버로 복사한다.
#
#   실행 위치: 로컬
#   SSH 가 열려 있어야 한다 (02 실행 후 / 07 실행 전).

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need scp
need ssh

STATIC_IP="${STATIC_IP:-$(static_ip_address)}"
[ -n "$STATIC_IP" ] || die "고정 IP 를 찾을 수 없다. 01 을 먼저 실행할 것."
export STATIC_IP
host="$(resolve_host)"

say "대상: ubuntu@$STATIC_IP (접속 호스트명 $host)"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<TXT
# sync-host.sh 가 생성. 서버에서 03~09 스크립트가 읽는다.
DOMAIN=$host
ORCA_PORT=$ORCA_PORT
REPOS="${REPOS:-}"
GITHUB_OWNER="${GITHUB_OWNER:-}"
TXT

scp -q "$tmp" "ubuntu@$STATIC_IP:~/orca-host.env"
scp -q "$SCRIPT_DIR"/lib.sh \
       "$SCRIPT_DIR"/03-host-base.sh "$SCRIPT_DIR"/04-install-orca.sh \
       "$SCRIPT_DIR"/05-orca-service.sh "$SCRIPT_DIR"/06-caddy.sh \
       "$SCRIPT_DIR"/08-agent-cli.sh "$SCRIPT_DIR"/09-repos.sh \
       "$SCRIPT_DIR"/verify-host.sh "ubuntu@$STATIC_IP:~/"

ssh "ubuntu@$STATIC_IP" 'chmod +x ~/*.sh'
ok "복사 완료"

cat <<TXT

서버에 붙어서 순서대로 실행한다:

  ssh ubuntu@$STATIC_IP
  ./03-host-base.sh       # 툴체인 + 스왑 2GB + Node
  ./04-install-orca.sh    # Orca 설치 + 헤드리스 기동 검증 (가장 불확실한 단계)
  ./05-orca-service.sh    # systemd 서비스 등록
  ./06-caddy.sh           # Caddy 로 HTTPS/WSS 종단
  ./verify-host.sh        # 서버 쪽 점검
  ./08-agent-cli.sh       # 에이전트 CLI 설치 (로그인은 사람이 직접)
  ./09-repos.sh           # 레포 클론 + orca 등록

그 다음 로컬에서:
  ./scripts/07-firewall-final.sh
TXT

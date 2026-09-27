#!/usr/bin/env bash
# 설치된 Orca 버전과 GitHub Releases 의 최신 버전을 비교한다.
# docs/stability-plan.md 8.1.
#
#   실행 위치: 서버 또는 로컬
#   ./util/check-orca-update.sh [--notify]
#
#     --notify   새 버전이 있으면 /usr/local/sbin/orca-notify 로 알린다 (서버 전용)

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need curl
need jq

NOTIFY=0
[ "${1:-}" = "--notify" ] && NOTIFY=1

installed="unknown"
if [ -r /opt/orca/VERSION ]; then
    installed="$(cat /opt/orca/VERSION)"
elif sudo test -r /opt/orca/VERSION 2>/dev/null; then
    installed="$(sudo cat /opt/orca/VERSION)"
fi

if [ "$installed" = unknown ]; then
    say "설치 버전 기록이 없다. ORCA_VERSION=$ORCA_VERSION 은 설치 정책이다."
fi

fetch_latest() {
    curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/stablyai/orca/releases/latest
}
release="$(retry 3 fetch_latest)" || die "GitHub Releases API 호출이 3회 모두 실패했다."

latest="$(jq -r '.tag_name // empty' <<<"$release")"
[ -n "$latest" ] || die "최신 릴리스 태그를 읽지 못했다."
published="$(jq -r '.published_at // empty' <<<"$release")"

say "설치됨: $installed"
say "최신:   $latest${published:+ ($published)}"

if [ "$installed" = "$latest" ]; then
    ok "최신 버전이다."
    exit 0
fi

warn "새 버전이 있다: $installed → $latest"
if [ "$NOTIFY" = 1 ] && [ -x /usr/local/sbin/orca-notify ]; then
    /usr/local/sbin/orca-notify info "Orca 새 버전: $installed → $latest"
fi

cat <<TXT

업그레이드 절차 (docs/lightsail-plan.md 7절):
  1. 스냅샷을 먼저 만든다
     aws lightsail create-instance-snapshot --region ap-northeast-1 \\
       --instance-name <인스턴스> --instance-snapshot-name orca-host-\$(date -u +%Y%m%d)-preupgrade
  2. ./util/backup-orca.sh 로 프로필을 백업한다
  3. 최상위 .env 의 ORCA_VERSION=latest 를 유지하고 ORCA_SHA256 은 비운다 (버전 고정 시 $latest 지정)
  4. ./util/sync-host.sh
  5. ./install/04-orca-server.sh   # latest는 실행 시 안정판을 조회한다. SHA256 고정은 태그 고정 시에만 한다
  6. ./util/verify-host.sh

다운그레이드는 바이너리만 되돌리지 않는다. 상태 스키마가 바뀔 수 있으므로 같은 시점의
Orca 프로필 백업을 함께 복구한다.
TXT
exit 1

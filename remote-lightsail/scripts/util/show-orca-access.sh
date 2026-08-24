#!/usr/bin/env bash
# 가장 최근 Orca 준비 이벤트에서 브라우저 접속 URL을 꺼낸다.
# Pairing URL은 비밀번호와 같은 capability이므로 화면 공유/로그 첨부를 금지한다.

set -euo pipefail

url_only=false
if [ "${1:-}" = "--url-only" ]; then
    url_only=true
elif [ "$#" -ne 0 ]; then
    echo "사용법: $0 [--url-only]" >&2
    exit 2
fi

command -v jq >/dev/null 2>&1 || { echo "jq가 필요하다." >&2; exit 1; }

ready="$({ journalctl -u orca-serve.service -o cat --no-pager 2>/dev/null || true; } \
    | jq -Rrc 'fromjson? | select(.type == "orca_server_ready" and .schemaVersion == 1)' \
    | tail -1)"

[ -n "$ready" ] || {
    echo "Orca 준비 이벤트를 찾지 못했다." >&2
    echo "sudo systemctl status orca-serve --no-pager" >&2
    echo "sudo journalctl -u orca-serve -n 100 --no-pager" >&2
    exit 1
}

available="$(jq -r '.pairing.available // false' <<<"$ready")"
if [ "$available" != true ]; then
    jq -r '"Pairing URL 생성 실패: \(.pairing.reason // "unknown")\n\(.pairing.guidance // "")"' <<<"$ready" >&2
    exit 1
fi

web_url="$(jq -r '.pairing.webClientUrl // empty' <<<"$ready")"
[ -n "$web_url" ] || { echo "준비 이벤트에 Web Client URL이 없다." >&2; exit 1; }

if [ "$url_only" = false ]; then
    cat <<'TXT'
아래 URL은 Orca 런타임 접근 권한을 포함한다. 관리 PC의 브라우저에서만 열고 공유하지 않는다.
관리 PC는 서버와 같은 Tailscale tailnet에 연결되어 있어야 한다.

TXT
fi
printf '%s\n' "$web_url"

#!/usr/bin/env bash
# 페어링 토큰을 출력하지 않고 Orca Web Client의 서버 측 전달 상태를 점검한다.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
set +e

fail=0
tmp_html="$(mktemp)"
tmp_asset="$(mktemp)"
trap 'rm -f "$tmp_html" "$tmp_asset"' EXIT

say "Orca 서비스"
if systemctl is-active --quiet orca-serve.service; then
    ok "orca-serve active"
else
    warn "orca-serve가 active가 아니다"
    fail=1
fi

orca_started_at="$(systemctl show orca-serve.service -p ActiveEnterTimestamp --value 2>/dev/null)"
[ -n "$orca_started_at" ] || orca_started_at="15 min ago"
ready="$({ journalctl -u orca-serve.service --since "$orca_started_at" -o cat --no-pager 2>/dev/null || true; } \
    | jq -Rrc 'fromjson? | select(.type == "orca_server_ready" and .schemaVersion == 1)' \
    | tail -1)"
if [ -n "$ready" ]; then
    jq -r '"  bound:     \(.boundEndpoint // "없음")\n  advertised: \(.advertisedEndpoint // "없음")\n  pairing:   \(.pairing.available // false)"' <<<"$ready"
    if jq -e '(.advertisedEndpoint | startswith("wss://")) and (.pairing.webClientUrl | startswith("https://"))' \
        <<<"$ready" >/dev/null; then
        ok "HTTPS/WSS 보안 컨텍스트"
    else
        warn "광고 주소가 HTTPS/WSS가 아니다 — 브라우저 Web Crypto가 차단되어 빈 화면이 된다"
        fail=1
    fi
else
    warn "Orca 준비 이벤트가 없다"
    fail=1
fi

say "로컬 Web Client 응답"
base="http://127.0.0.1:${ORCA_PORT}"
html_meta="$(curl -sS -o "$tmp_html" -w '%{http_code}|%{content_type}|%{size_download}' \
    "$base/web-index.html" 2>&1)"
curl_rc=$?
html_code="${html_meta%%|*}"
if [ "$curl_rc" -eq 0 ] && [ "$html_code" = 200 ]; then
    printf '  HTML: %s\n' "$html_meta"
else
    warn "HTML 요청 실패: $html_meta"
    fail=1
fi

if grep -Eqi '<!doctype html|<html' "$tmp_html"; then
    ok "HTML 문서 확인"
else
    warn "응답이 HTML 문서처럼 보이지 않는다"
    fail=1
fi

asset="$(grep -Eo 'src="[^"]+\.js[^\"]*"' "$tmp_html" | head -1 | cut -d'"' -f2)"
if [ -n "$asset" ]; then
    case "$asset" in
        http://*|https://*) asset_url="$asset" ;;
        /*) asset_url="$base$asset" ;;
        *) asset_url="$base/$asset" ;;
    esac
    asset_meta="$(curl -sS -o "$tmp_asset" -w '%{http_code}|%{content_type}|%{size_download}' \
        "$asset_url" 2>&1)"
    asset_rc=$?
    asset_code="${asset_meta%%|*}"
    if [ "$asset_rc" -eq 0 ] && [ "$asset_code" = 200 ]; then
        printf '  JavaScript: %s\n' "$asset_meta"
    else
        warn "JavaScript 요청 실패: $asset_meta"
        fail=1
    fi
else
    warn "HTML에서 JavaScript 번들을 찾지 못했다"
    fail=1
fi

say "Tailscale"
tailscale_ip="$(tailscale ip -4 2>/dev/null | head -1)"
tailscale_dns="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
if [[ "$tailscale_ip" =~ ^100\. ]]; then
    ok "서버 IP: $tailscale_ip"
else
    warn "Tailscale IPv4를 찾지 못했다"
    fail=1
fi
if [ -n "$tailscale_dns" ]; then
    echo "  관리 PC 테스트 주소: https://${tailscale_dns}/web-index.html"
else
    warn "Tailscale MagicDNS 이름을 찾지 못했다"
    fail=1
fi

if sudo tailscale serve status 2>/dev/null | grep -Fq "proxy http://127.0.0.1:${ORCA_PORT}"; then
    ok "Tailscale Serve HTTPS 프록시"
else
    warn "Tailscale Serve가 Orca를 프록시하지 않는다"
    fail=1
fi

echo
if [ "$fail" -eq 0 ]; then
    ok "서버 측 Web Client 응답 정상"
    echo "브라우저가 계속 비어 있으면 F12 > Console의 빨간 오류만 복사한다."
    echo "pairing URL과 #pairing= 뒤의 값은 복사하지 않는다."
else
    warn "서버 측 실패 항목이 있다"
fi
exit "$fail"

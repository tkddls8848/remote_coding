#!/usr/bin/env bash
# Phase 4 — Orca 설치 + 헤드리스 기동 검증.
#
#   실행 위치: 서버
#
# 계획서에서 가장 불확실한 단계다. Orca 는 Electron 앱이고 서버에는 디스플레이가 없다.
# 여기서 헤드리스 기동을 실제로 확인하고, 실패하면 xvfb 래핑이 필요하다는 표시를
# ~/.orca-needs-xvfb 로 남긴다. 05 가 그 표시를 읽어서 서비스 정의를 바꾼다.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export DEBIAN_FRONTEND=noninteractive
NEEDS_XVFB_FLAG="$HOME/.orca-needs-xvfb"

if command -v orca >/dev/null 2>&1; then
    ok "orca 이미 설치됨"
else
    say "최신 릴리스 .deb 주소 조회"
    DEB_URL=$(curl -fsSL https://api.github.com/repos/stablyai/orca/releases/latest \
        | grep -o 'https://[^"]*orca-ide_[^"]*_amd64\.deb' | head -1)
    [ -n "$DEB_URL" ] || die "amd64 .deb 를 찾지 못했다. 릴리스 페이지를 직접 확인할 것."
    say "다운로드: $DEB_URL"
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    curl -fsSL -o "$tmpdir/orca.deb" "$DEB_URL"
    sudo apt-get install -y -qq "$tmpdir/orca.deb"
    ok "설치 완료"
fi

# --- 헤드리스 기동 검증 -----------------------------------------------------
say "헤드리스 기동 검증 (디스플레이 없이 뜨는지)"
rm -f "$NEEDS_XVFB_FLAG"

probe() {
    # $1 을 앞에 붙여 orca serve 를 잠깐 띄우고 웹 번들이 응답하는지 본다.
    local wrapper="$1" log rc=1 pid
    log="$(mktemp)"
    # shellcheck disable=SC2086
    $wrapper /usr/bin/orca serve --port "$ORCA_PORT" >"$log" 2>&1 &
    pid=$!
    for _ in $(seq 1 30); do
        if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$ORCA_PORT/web-index.html"; then
            rc=0; break
        fi
        kill -0 "$pid" 2>/dev/null || break   # 프로세스가 죽었으면 더 기다릴 이유가 없다
        sleep 1
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ $rc -eq 0 ] || { warn "기동 실패. 마지막 로그:"; tail -20 "$log" >&2; }
    rm -f "$log"
    return $rc
}

if probe ""; then
    ok "디스플레이 없이 기동됨 — xvfb 불필요"
else
    warn "그냥은 기동되지 않는다. xvfb 로 우회를 시도한다."
    sudo apt-get install -y -qq xvfb
    if probe "xvfb-run -a"; then
        touch "$NEEDS_XVFB_FLAG"
        ok "xvfb-run 으로 기동됨 — 05 가 서비스를 xvfb-run 으로 감싼다"
    else
        die "xvfb 로도 기동되지 않는다. 여기서 멈추고 위 로그를 확인할 것.
계획서 6절의 ' Electron 헤드리스 기동 실패' 리스크가 현실화된 경우다."
    fi
fi

say "다음: ./05-orca-service.sh"

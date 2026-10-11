#!/usr/bin/env bash
# RunPod 팟 안에서 도는 유휴 감시 — IDLE_MIN 분(기본 30) 동안 그림 대기열 · GPU 사용 · Tailscale SSH 접속이 모두 없으면 이 팟을 지운다.
# 저장 공간(/workspace)은 남는다. boot.sh 가 켤 때 띄우고, 이미 떠 있는 팟에는 관리 PC 에서 올려 띄울 수도 있다:
#   tailscale ssh root@art-gpu 'cat > /opt/idle-guard.sh && (setsid nohup bash /opt/idle-guard.sh >/dev/null 2>&1 &)' < gpu-art/runpod/idle_guard.sh
# 팟 전용 키(RUNPOD_API_KEY, RunPod 이 넣어 준다)는 REST 에서 403 이고 GraphQL 에서만 통한다(2026-10-11 확인).
set -u
W=/workspace
# ssh 로 띄우면 PATH 에 이미지의 파이썬(/opt/conda/bin)이 없다
export PATH="/opt/conda/bin:/usr/local/bin:$PATH"
command -v python3 >/dev/null || { echo "[idle] python3 없음" >> $W/boot.log; exit 1; }
envof() { tr '\0' '\n' < /proc/1/environ | grep "^$1=" | cut -d= -f2-; }   # ssh 로 띄우면 팟 환경 변수가 없다 — 1번 프로세스에서 읽는다
POD=${RUNPOD_POD_ID:-$(envof RUNPOD_POD_ID)}
KEY=${RUNPOD_API_KEY:-$(envof RUNPOD_API_KEY)}
IDLE_MIN=${IDLE_MIN:-$(envof IDLE_MIN)}; IDLE_MIN=${IDLE_MIN:-30}
LOG=$W/boot.log
say() { printf '[idle %s] %s\n' "$(date -u +%H:%M:%S)" "$*" >> "$LOG"; }

# 하나만 돈다
exec 9>/tmp/idle-guard.lock
flock -n 9 || exit 0

gql() {   # gql <mutation> — 결과를 찍는다
    python3 - "$1" "$POD" "$KEY" <<'PY'
import json, sys, urllib.request
m, pod, key = sys.argv[1:]
q = 'mutation { %s(input: {podId: "%s"}) %s }' % (m, pod, '{ id }' if m == 'podStop' else '')
req = urllib.request.Request('https://api.runpod.io/graphql', data=json.dumps({'query': q}).encode(),
                            headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + key, 'User-Agent': 'art-gpu/1.0'})
r = json.load(urllib.request.urlopen(req, timeout=30))
print(json.dumps(r)[:200])
sys.exit(1 if r.get('errors') else 0)
PY
}

say "감시 시작 — ${IDLE_MIN}분 놀면 팟($POD)을 지운다"
last=$(date +%s)
while true; do
    sleep 300 9>&-   # 잠금(fd 9)을 기다리는 자식에게 넘기지 않는다
    [ -f "$W/idle_min" ] && IDLE_MIN=$(tr -dc 0-9 < "$W/idle_min")   # 팟을 다시 만들지 않고 바꿀 수 있게
    [ "${IDLE_MIN:-0}" -gt 0 ] || continue
    q=$(curl -fsS -m 5 http://127.0.0.1:8188/queue 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("queue_running",[]))+len(d.get("queue_pending",[])))' 2>/dev/null || echo 0)
    u=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | sort -n | tail -1)
    s=$(pgrep -fc 'be-child ssh' 2>/dev/null || true)
    if [ "${q:-0}" -gt 0 ] || [ "${u:-0}" -gt 10 ] || [ "${s:-0}" -gt 0 ]; then last=$(date +%s); continue; fi
    idle=$(( ($(date +%s) - last) / 60 ))
    if [ "$idle" -ge "$IDLE_MIN" ]; then
        say "유휴 ${idle}분 — 팟을 지운다"
        if out=$(gql podTerminate 2>&1); then say "지움: $out"; elif out=$(gql podStop 2>&1); then say "멈춤: $out"; else say "스스로 지우지 못했다: $out — 관리 PC 에서 gpu.py stop"; fi
        sleep 600 9>&-
    fi
done

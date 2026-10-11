#!/usr/bin/env bash
# 그림 서버 켜기 · 끄기 · 상태 (관리 PC 에서).
#
#   ./gpu-art/scripts/gpu.sh start    켜고 ComfyUI 가 응답할 때까지 기다린 뒤 주소를 알려 준다
#   ./gpu-art/scripts/gpu.sh stop     끈다 (디스크 값만 남는다)
#   ./gpu-art/scripts/gpu.sh status   켜져 있는지 · ComfyUI 가 응답하는지
#   ./gpu-art/scripts/gpu.sh url      게임 도구에 넘길 COMFY_URL 만 출력
#
# 게임 도구는 COMFY_URL 환경 변수로 이 서버를 쓴다:
#   PowerShell:  $env:COMFY_URL = (bash ./gpu-art/scripts/gpu.sh url)
#   Git Bash:    export COMFY_URL="$(./gpu-art/scripts/gpu.sh url)"

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need terraform
need curl

INSTANCE_ID="$(tf_output instance_id)"
REGION="$(tf_output region)"
TS_HOST="${GPU_TAILSCALE_HOSTNAME:-$(tf_output instance_name)}"
[ -n "$INSTANCE_ID" ] || die "gpu-art/terraform 에 만든 서버가 없다. ./gpu-art/scripts/provision.sh 를 먼저."
URL="http://$TS_HOST:$GPU_COMFY_PORT"

state() {
    aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' --output text
}
comfy_up() { curl -fsS -m 4 "$URL/system_stats" >/dev/null 2>&1; }

case "${1:-status}" in
    start)
        aws_env
        s="$(state)"
        if [ "$s" != running ]; then
            [ "$s" = stopping ] && { say "끄는 중 — 다 꺼질 때까지 기다린다"; aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"; }
            say "켜기"
            aws ec2 start-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
            aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
        fi
        say "ComfyUI 응답 대기 ($URL)"
        for _ in $(seq 1 90); do
            if comfy_up; then ok "켜짐 — COMFY_URL=$URL"; exit 0; fi
            sleep 4
        done
        die "6분 안에 ComfyUI 가 응답하지 않았다. 관리 PC 가 같은 tailnet 에 있는지, 서버에서 'journalctl -u comfyui' 를 볼 것."
        ;;
    stop)
        aws_env
        say "끄기"
        aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
        ok "끄는 중 (디스크와 설치는 남는다)"
        ;;
    status)
        aws_env
        s="$(state)"
        echo "서버: $s ($INSTANCE_ID, $REGION)"
        if [ "$s" = running ]; then
            if comfy_up; then echo "ComfyUI: 응답함 — COMFY_URL=$URL"; else echo "ComfyUI: 응답 없음 ($URL)"; fi
        fi
        ;;
    url)
        printf '%s\n' "$URL"
        ;;
    *)
        sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac

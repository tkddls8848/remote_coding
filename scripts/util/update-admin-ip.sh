#!/usr/bin/env bash
# 현재 공인 IP 를 감지해 terraform.tfvars 의 my_ip 를 갱신하고 apply 한다.
# docs/stability-plan.md 8.2.
#
#   실행 위치: 로컬
#   ./util/update-admin-ip.sh [-y] [--ip 203.0.113.10]
#
#     -y, --yes    terraform apply 를 확인 없이 실행한다
#         --ip X   자동 감지 대신 이 값을 쓴다
#
# 근본 해결은 Tailscale SSH 경로다 — tailnet 안에서는 공인 IP 가 바뀌어도 붙을 수 있고
# 이 스크립트가 필요 없다 (docs/stability-plan.md 3.2-2).

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

need terraform
need curl

AUTO=0
IP=""
while [ $# -gt 0 ]; do
    case "$1" in
        -y|--yes) AUTO=1 ;;
        --ip)     IP="${2:-}"; shift ;;
        -h|--help) sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "알 수 없는 옵션: $1 (--help 참고)" ;;
    esac
    shift
done

TF_DIR="$(cd "$TF_DIR" && pwd)"
tfvars="$TF_DIR/terraform.tfvars"
[ -f "$tfvars" ] || die "terraform.tfvars 가 없다: $tfvars"

if [ -z "$IP" ]; then
    # 감지처가 하나면 그 하나의 장애가 곧 이 스크립트의 장애다. 순서대로 시도한다.
    for url in https://checkip.amazonaws.com https://api.ipify.org https://ifconfig.me/ip; do
        IP="$(curl -fsS -m 10 "$url" 2>/dev/null | tr -d '[:space:]')" || IP=""
        [ -n "$IP" ] && { ok "공인 IP $IP ($url)"; break; }
        warn "IP 감지 실패: $url"
    done
fi

[[ "$IP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] \
    || die "공인 IP 를 감지하지 못했다. --ip 로 직접 지정할 것."

current="$(sed -n -E 's/^[[:space:]]*my_ip[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' "$tfvars" | tail -1)"
if [ "$current" = "$IP" ]; then
    ok "terraform.tfvars 의 my_ip 가 이미 $IP 다."
    exit 0
fi

say "my_ip: ${current:-<비어 있음>} → $IP"
if grep -qE '^[[:space:]]*#?[[:space:]]*my_ip[[:space:]]*=' "$tfvars"; then
    # 주석 처리된 줄도 함께 살린다.
    sed -i -E "s|^[[:space:]]*#?[[:space:]]*my_ip[[:space:]]*=.*|my_ip = \"$IP\"|" "$tfvars"
else
    printf '\n# util/update-admin-ip.sh 가 갱신한다.\nmy_ip = "%s"\n' "$IP" >> "$tfvars"
fi
ok "terraform.tfvars 갱신"

apply_args=(-input=false)
[ "$AUTO" = 1 ] && apply_args+=(-auto-approve)
say "terraform apply"
terraform -chdir="$TF_DIR" apply "${apply_args[@]}"
ok "SSH /32 규칙 갱신 완료"

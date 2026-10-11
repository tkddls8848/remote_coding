#!/usr/bin/env bash
# 그림 서버 설정 4/5 — 모델 받기 (gpu-art/models.txt, 약 17GB).
#
# 이미 있고 sha256 이 맞으면 건너뛴다. 받다 끊기면 이어 받는다. sha256 이 다르면 지우고 멈춘다.

. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

need curl
need sha256sum

MODELS_DIR="$GPU_COMFY_ROOT/ComfyUI/models"
LIST="$GPU_DIR/models.txt"
[ -d "$MODELS_DIR" ] || die "$MODELS_DIR 이 없다. ./install/03-comfyui.sh 를 먼저."
[ -f "$LIST" ] || die "$LIST 이 없다."

# 100GB 디스크면 AMI · ComfyUI 를 깔고 남는 자리가 빠듯하다. 모델(약 17GB) + 여유를 먼저 본다.
free_gb=$(( $(df --output=avail -k "$MODELS_DIR" | tail -1) / 1024 / 1024 ))
[ "$free_gb" -ge 22 ] || die "디스크 남은 자리 ${free_gb}GB — 모델에 22GB 이상 필요하다. terraform.tfvars 의 root_volume_gb 를 늘려 apply 한 뒤 'sudo growpart /dev/nvme0n1 1 && sudo resize2fs /dev/nvme0n1p1'."
ok "디스크 남은 자리 ${free_gb}GB"

fetch() { curl -fL --retry 5 --retry-delay 5 -C - -sS -o "$1" "$2"; }

n=0
while read -r rel url sum; do
    case "$rel" in ''|'#'*) continue ;; esac
    [ -n "${url:-}" ] && [[ "${sum:-}" =~ ^[0-9a-f]{64}$ ]] || die "models.txt 줄 형식이 잘못됐다: $rel"
    case "$rel" in /*|*..*) die "models.txt 경로는 models/ 아래 상대 경로여야 한다: $rel" ;; esac

    dest="$MODELS_DIR/$rel"
    mkdir -p "$(dirname "$dest")"
    if [ -f "$dest" ] && [ "$(sha256sum "$dest" | cut -d' ' -f1)" = "$sum" ]; then
        ok "있음 $rel"
        continue
    fi

    say "받기 $rel"
    retry 3 fetch "$dest.part" "$url" || die "받지 못했다: $url"
    got="$(sha256sum "$dest.part" | cut -d' ' -f1)"
    if [ "$got" != "$sum" ]; then
        rm -f "$dest.part"
        die "sha256 이 다르다: $rel
  기대 $sum
  실제 $got
  출처가 파일을 바꿨을 수 있다. 게임 저장소 MODELS.md 와 대조한 뒤 models.txt 를 고칠 것."
    fi
    mv -f "$dest.part" "$dest"
    ok "$rel"
    n=$((n + 1))
done < "$LIST"

ok "모델 준비 끝 (새로 받음 $n 개)"
df -h "$MODELS_DIR" | tail -1
echo "다음: ./install/05-idle-stop.sh"

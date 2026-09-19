#!/usr/bin/env bash
# Orca 상태·프로필 오프사이트 백업. docs/stability-plan.md 7.1.
#
#   실행 위치: 서버 (ubuntu 계정, sudo 필요)
#   ./util/backup-orca.sh [--dry-run]
#
# 주의 — 자격증명까지 담으면 이 조치는 노출면을 넓힌다.
# /home/orca/.codex 와 gh 토큰은 자격증명이다. S3 로 복사하면 자격증명의 사본이 하나 더
# 생기고 그 버킷이 새로운 침해 대상이 된다. 기본값은 자격증명 제외이며, 담으려면
# BACKUP_INCLUDE_CREDENTIALS=1 과 함께 버킷 통제(SSE-KMS, PutObject 만 허용, 버저닝 +
# Object Lock)를 반드시 같이 건다. 대안은 백업하지 않고 재발급 절차만 문서화하는 것이다
# — `codex login` 과 `gh auth login` 은 몇 분이면 끝난다.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

need tar
id "$ORCA_SERVICE_USER" >/dev/null 2>&1 || die "$ORCA_SERVICE_USER 계정이 없다."

orca_home="$(getent passwd "$ORCA_SERVICE_USER" | cut -d: -f6)"
[ -n "$orca_home" ] || die "$ORCA_SERVICE_USER 의 홈 디렉터리를 찾지 못했다."

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
archive="$BACKUP_LOCAL_DIR/orca-$stamp.tar.gz"

# 담는 것: Orca 프로필과 페어링 키. 이것이 없으면 인스턴스를 새로 세워도 기존
# 워크트리·세션 상태가 돌아오지 않는다.
paths=(
    "$orca_home/.config/orca"
    "$orca_home/.config/Orca"
)
# 담지 않는 것: workspace 안에서 git remote 가 있는 저장소. GitHub 이 이미 사본이다.
# 워크스페이스의 커밋되지 않은 변경만 따로 기록해 둔다 (아래 dirty 목록).

if [ "$BACKUP_INCLUDE_CREDENTIALS" = 1 ]; then
    paths+=("$orca_home/.codex" "$orca_home/.config/gh")
    warn "자격증명을 함께 담는다 (BACKUP_INCLUDE_CREDENTIALS=1)."
    [ -n "$BACKUP_KMS_KEY_ID" ] \
        || warn "BACKUP_KMS_KEY_ID 가 비어 있다 — SSE-KMS 없이 자격증명을 올리는 것은 권장하지 않는다."
else
    say "자격증명(.codex, gh)은 담지 않는다. 복구는 재로그인으로 한다:"
    say "  sudo -u $ORCA_SERVICE_USER -H /bin/bash -c 'cd \"\$HOME\" && exec codex login --device-auth'"
    say "  sudo -u $ORCA_SERVICE_USER -H /bin/bash -c 'cd \"\$HOME\" && exec gh auth login'"
fi

existing=()
for p in "${paths[@]}"; do
    if sudo test -e "$p"; then existing+=("$p"); else warn "없음 — 건너뜀: $p"; fi
done
[ "${#existing[@]}" -gt 0 ] || die "백업할 경로가 하나도 없다."

# 커밋되지 않은 작업은 백업이 아니라 push 로 지킨다. 목록만 남겨 무엇이 떠 있었는지
# 나중에 알 수 있게 한다.
dirty_list="$(mktemp)"
trap 'rm -f "$dirty_list"' EXIT
if sudo test -d "$orca_home/workspace"; then
    while IFS= read -r gitdir; do
        repo="$(dirname "$gitdir")"
        if [ -n "$(sudo git -C "$repo" status --porcelain 2>/dev/null)" ]; then
            printf '%s\n' "$repo" >> "$dirty_list"
        fi
    done < <(sudo find "$orca_home/workspace" -maxdepth 2 -name .git -type d 2>/dev/null)
fi
if [ -s "$dirty_list" ]; then
    warn "커밋되지 않은 변경이 있는 저장소 (백업 대상 아님 — push 할 것):"
    sed 's/^/       /' "$dirty_list" >&2
fi

say "아카이브 생성: $archive"
if [ "$DRY_RUN" = 1 ]; then
    printf '  [dry-run] tar czf %s %s\n' "$archive" "${existing[*]}"
else
    sudo install -d -o root -g root -m 0700 "$BACKUP_LOCAL_DIR"
    sudo tar czf "$archive" --warning=no-file-changed \
        "${existing[@]}" "$dirty_list" 2>/dev/null \
        || [ "$?" = 1 ]   # tar 는 백업 중 파일이 바뀌면 1 을 돌려준다. 내용은 유효하다.
    sudo chmod 0600 "$archive"
    ok "$(sudo du -h "$archive" | awk '{print $1}') — $archive"
fi

# --- 오프사이트 -------------------------------------------------------------
if [ -z "$BACKUP_S3_URI" ]; then
    warn "BACKUP_S3_URI 가 비어 있다 — 로컬 아카이브만 만들었다."
    warn "리전 장애나 계정 문제에서는 스냅샷도 이 파일도 함께 사라진다 (7.1)."
else
    need aws
    s3_args=(--only-show-errors)
    if [ -n "$BACKUP_KMS_KEY_ID" ]; then
        s3_args+=(--sse aws:kms --sse-kms-key-id "$BACKUP_KMS_KEY_ID")
    else
        s3_args+=(--sse AES256)
    fi
    dest="${BACKUP_S3_URI%/}/$(hostname)/$(basename "$archive")"
    say "업로드: $dest"
    if [ "$DRY_RUN" = 1 ]; then
        printf '  [dry-run] aws s3 cp %s %s %s\n' "$archive" "$dest" "${s3_args[*]}"
    else
        retry 3 sudo aws s3 cp "$archive" "$dest" "${s3_args[@]}" \
            || die "S3 업로드가 3회 모두 실패했다: $dest"
        ok "업로드 완료"
    fi
fi

# 로컬 사본 정리 — 8세대만 남긴다.
if [ "$DRY_RUN" != 1 ] && sudo test -d "$BACKUP_LOCAL_DIR"; then
    sudo bash -c 'ls -1t "$1"/orca-*.tar.gz 2>/dev/null | tail -n +9 | xargs -r rm -f' \
        bash "$BACKUP_LOCAL_DIR"
fi

cat <<'TXT'

버킷 통제 (자격증명을 담는다면 사실상 필수 — docs/stability-plan.md 7.1-3):
  - SSE-KMS 고객 관리 키. 키 정책에서 복호화 주체를 관리자 principal 로 한정한다.
  - 버킷 정책에서 이 인스턴스에는 PutObject 만 허용하고 GetObject 는 제외한다
    (백업은 쓰되 읽지는 못하게 한다).
  - 버저닝 + Object Lock 으로 랜섬웨어에 대비한다.

복구 절차는 docs/lightsail-plan.md 8절에 있다.
TXT

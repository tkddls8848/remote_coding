#!/usr/bin/env bash
# Run on the SOURCE host as root. Archive goes to stdout; diagnostics to stderr.
# Default: online preparation copy. --quiesce: stop writers for the final copy.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run with sudo." >&2; exit 1; }
quiesce=0
case "${1:-}" in
    "") ;;
    --quiesce) quiesce=1 ;;
    *) echo "Usage: sudo $0 [--quiesce] > stock-chatbot.tgz" >&2; exit 1 ;;
esac
app=/srv/stock-chatbot
test -d "$app/.git"
test -s "$app/.env"
umask 077
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/migration"
units=(stock-chatbot.service stock-chatbot-web.service
    stock-chatbot-polymarket-refresh.timer stock-chatbot-polymarket-refresh.service
    stock-chatbot-polymarket-brief.service stock-chatbot-polymarket-trending.service)
active=()
for unit in "${units[@]}"; do
    if systemctl is-active --quiet "$unit"; then active+=("$unit"); fi
    systemctl show "$unit" -p Id -p User -p Group -p ActiveState -p UnitFileState \
        -p WorkingDirectory -p FragmentPath >> "$stage/migration/services.txt"
    systemctl cat "$unit" > "$stage/migration/$unit" 2>/dev/null || true
done
printf '%s\n' "${active[@]}" > "$stage/migration/active-units.txt"
systemctl list-timers --all --no-pager > "$stage/migration/timers.txt"
dpkg-query -W > "$stage/migration/packages.txt"
"$app/venv/bin/python" -m pip freeze > "$stage/migration/requirements.freeze.txt"
owner="$(stat -c %U "$app")"
sudo -u "$owner" git -C "$app" rev-parse HEAD > "$stage/migration/commit.txt"
sudo -u "$owner" git -C "$app" status --porcelain > "$stage/migration/git-status.txt"
hostname > "$stage/migration/source-host.txt"
date -u +%FT%TZ > "$stage/migration/exported-at.txt"
printf '%s\n' "$quiesce" > "$stage/migration/quiesced.txt"
if command -v ollama >/dev/null 2>&1; then
    ollama list > "$stage/migration/ollama-models.txt" 2>/dev/null || true
fi

if [ "$quiesce" = 1 ]; then
    # On failure restore services that this export stopped. Success leaves them
    # stopped until cutover/rollback, including the scheduler and all writers.
    trap 'systemctl start "${active[@]}" >&2 || true' ERR
    systemctl stop stock-chatbot-polymarket-refresh.timer
    systemctl stop stock-chatbot.service stock-chatbot-web.service \
        stock-chatbot-polymarket-refresh.service stock-chatbot-polymarket-brief.service \
        stock-chatbot-polymarket-trending.service
fi
paths=(srv/stock-chatbot)
for path in etc/caddy var/lib/caddy var/backups/stock-chatbot etc/cron.d/stock-chatbot-backup \
    var/lib/systemd/timers/stamp-stock-chatbot-polymarket-refresh.timer \
    'etc/systemd/system/stock-chatbot*' etc/systemd/system/caddy.service.d \
    etc/systemd/system/ollama.service etc/systemd/system/ollama.service.d; do
    # Expand the source host's absolute glob, never the caller's working directory.
    for absolute in /$path; do
        [ ! -e "$absolute" ] || paths+=("${absolute#/}")
    done
done
# Ignore only GNU tar's live-file-change status for the online preparation copy.
# A final --quiesce export must be fully consistent and must exit successfully.
status=0
tar --exclude='srv/stock-chatbot/venv' --exclude='*/__pycache__' \
    --exclude='srv/stock-chatbot/.cache' --exclude='srv/stock-chatbot/.test-tmp' \
    --exclude='srv/stock-chatbot/shorts/.venv' \
    -czf - -C / "${paths[@]}" -C "$stage" migration || status=$?
if [ "$status" -ne 0 ] && { [ "$quiesce" = 1 ] || [ "$status" -ne 1 ]; }; then
    if [ "$quiesce" = 1 ] && [ "${#active[@]}" -gt 0 ]; then systemctl start "${active[@]}" >&2; fi
    exit "$status"
fi
echo "Export complete (quiesced=$quiesce). Archive contains secrets; keep it private." >&2

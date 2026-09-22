#!/usr/bin/env bash
# NEW host only. Restore a private export bundle without starting any app services.
# --refresh replaces the staged app/data with a final, quiesced source export.
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
archive="${1:?Usage: restore-stock-chatbot.sh archive.tgz [--refresh]}"
refresh="${2:-}"
case "$refresh" in ""|--refresh) ;; *) die "Unknown option: $refresh" ;; esac
[ "$ORCA_SERVICE_USER" = ubuntu ] || die "Migration target must use ubuntu."
[ "$TELEGRAM_BOT_DIR" = /srv/stock-chatbot ] || die "Migration preserves /srv/stock-chatbot paths."
[ "$TELEGRAM_BOT_START" = 0 ] && [ "$TELEGRAM_BOT_UPDATE" = 0 ] \
    || die "Set TELEGRAM_BOT_START=0 and TELEGRAM_BOT_UPDATE=0 in host.env."
sudo test -s "$archive" || die "Archive missing."
units=(stock-chatbot.service stock-chatbot-web.service stock-chatbot-polymarket-refresh.timer
    stock-chatbot-polymarket-refresh.service stock-chatbot-polymarket-brief.service
    stock-chatbot-polymarket-trending.service)
for unit in "${units[@]}" caddy.service; do
    if systemctl is-active --quiet "$unit"; then die "$unit is active; this is a staging-only restore."; fi
done
marker=/var/lib/stock-chatbot-migration
if sudo test -e "$TELEGRAM_BOT_DIR"; then
    [ "$refresh" = --refresh ] && sudo test -f "$marker/commit.txt" \
        || die "App path already exists; refusing to overwrite an existing deployment."
fi
stage="$(sudo mktemp -d)"
trap 'sudo rm -rf "$stage"' EXIT
# Python's data filter rejects paths/links escaping the staging directory.
sudo python3 - "$archive" "$stage" <<'PY'
import sys, tarfile
with tarfile.open(sys.argv[1], 'r:gz') as archive:
    archive.extractall(sys.argv[2], filter='data')
PY
source_host="$(sudo cat "$stage/migration/source-host.txt")"
[ "$source_host" != "$(hostname)" ] || die "Refusing to restore onto the source host."
sudo test -s "$stage/srv/stock-chatbot/.env" || die "Archive has no app secrets."
sudo test -s "$stage/migration/commit.txt" || die "Archive has no source revision."
if [ "$refresh" = --refresh ]; then
    [ "$(sudo cat "$stage/migration/quiesced.txt")" = 1 ] \
        || die "Final refresh requires an export made with --quiesce."
fi

sudo systemctl mask --runtime caddy.service
sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync caddy
sudo install -d -o ubuntu -g ubuntu -m 0750 "$TELEGRAM_BOT_DIR"
sudo rsync -a --delete --exclude=venv/ "$stage/srv/stock-chatbot/" "$TELEGRAM_BOT_DIR/"
sudo chown -R ubuntu:ubuntu "$TELEGRAM_BOT_DIR"
sudo chmod 0600 "$TELEGRAM_BOT_DIR/.env"
sudo install -d -m 0700 "$marker"
sudo cp -a "$stage/migration/." "$marker/"
# The source virtualenv's actual package versions, not a newly resolved upgrade.
sudo install -o ubuntu -g ubuntu -m 0600 "$stage/migration/requirements.freeze.txt" \
    "$TELEGRAM_BOT_DIR/requirements.lock.txt"
bash "$SCRIPT_DIR/install/08-telegram-bot.sh"

# Preserve the running service definitions, schedules and overrides from the source.
# systemctl cat flattened the source fragments in precedence order.
for unit in "${units[@]}"; do
    sudo test -s "$stage/migration/$unit" || die "Missing source unit: $unit"
    sudo sed -e 's/^User=.*/User=ubuntu/' -e 's/^Group=.*/Group=ubuntu/' \
        "$stage/migration/$unit" | sudo tee "/etc/systemd/system/$unit" >/dev/null
done
if sudo test -f "$stage/etc/cron.d/stock-chatbot-backup"; then
    # Preserve the schedule/retention; only change the account field.
    sudo sed 's/ stockbot / ubuntu /g' "$stage/etc/cron.d/stock-chatbot-backup" \
        | sudo tee /etc/cron.d/stock-chatbot-backup >/dev/null
    sudo chmod 0644 /etc/cron.d/stock-chatbot-backup
fi
sudo install -d -o ubuntu -g ubuntu -m 0700 /var/backups/stock-chatbot
if sudo test -d "$stage/var/backups/stock-chatbot"; then
    sudo rsync -a "$stage/var/backups/stock-chatbot/" /var/backups/stock-chatbot/
    sudo chown -R ubuntu:ubuntu /var/backups/stock-chatbot
fi
if sudo test -d "$stage/etc/caddy"; then
    sudo cp -a "$stage/etc/caddy/." /etc/caddy/
    sudo chown -R root:caddy /etc/caddy
fi
# Caddy binds to the EC2 private address so it can share :443 with Tailscale.
# That address changes on the new host even when the public static IP is reused.
sudo python3 - <<'PY'
from pathlib import Path
import ipaddress
import re
import subprocess
route = subprocess.check_output(['ip', '-4', 'route', 'get', '1.1.1.1'], text=True).split()
target_ip = route[route.index('src') + 1]
path = Path('/etc/caddy/Caddyfile')
def rebind(match):
    address = ipaddress.ip_address(match[2])
    return match[1] + (target_ip if address.is_private and not address.is_loopback else match[2])
path.write_text(re.sub(r'(?m)^(\s*bind\s+)(\d+\.\d+\.\d+\.\d+)(?=\s|$)', rebind, path.read_text()))
PY
if sudo test -d "$stage/var/lib/caddy"; then
    sudo rsync -a "$stage/var/lib/caddy/" /var/lib/caddy/
    sudo chown -R caddy:caddy /var/lib/caddy
fi
sudo caddy validate --config /etc/caddy/Caddyfile >/dev/null
sudo ufw allow 80/tcp >/dev/null
sudo ufw allow 443/tcp >/dev/null
sudo systemctl unmask --runtime caddy.service
sudo systemctl daemon-reload
sudo systemctl disable "${units[@]}" caddy.service
if sudo test -f "$stage/var/lib/systemd/timers/stamp-stock-chatbot-polymarket-refresh.timer"; then
    sudo install -d -m 0755 /var/lib/systemd/timers
    sudo cp -p "$stage/var/lib/systemd/timers/stamp-stock-chatbot-polymarket-refresh.timer" \
        /var/lib/systemd/timers/
fi
sudo systemd-analyze verify /etc/systemd/system/stock-chatbot*.service \
    /etc/systemd/system/stock-chatbot*.timer
as_orca /bin/bash -c 'cd /srv/stock-chatbot && exec venv/bin/python -c "import telegram_bot.main, web.server"'
ok "Restored source code, data, secrets, web, schedules and backups as ubuntu. All app services remain stopped."
ok "Source commit: $(sudo cat "$marker/commit.txt")"

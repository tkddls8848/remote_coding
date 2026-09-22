#!/usr/bin/env bash
# Telegram bot checkout, Python runtime and systemd service (run on Lightsail).
. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

[ "$TELEGRAM_BOT_ENABLED" = 1 ] || { say "Telegram deployment disabled"; exit 0; }
[[ "$TELEGRAM_BOT_START" =~ ^[01]$ && "$TELEGRAM_BOT_UPDATE" =~ ^[01]$ ]] \
    || die "TELEGRAM_BOT_START / TELEGRAM_BOT_UPDATE must be 0 or 1."
need git
need python3
id "$ORCA_SERVICE_USER" >/dev/null 2>&1 || die "Run install/04-orca-server.sh first."
[[ "$TELEGRAM_BOT_DIR" =~ ^/srv/[a-zA-Z0-9_-]+$ ]] || die "TELEGRAM_BOT_DIR must be /srv/<app-name>."
[[ "$TELEGRAM_BOT_REPO" =~ ^https://github\.com/[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+(\.git)?$ ]] \
    || die "TELEGRAM_BOT_REPO must be a GitHub HTTPS repository URL."
git check-ref-format --branch "$TELEGRAM_BOT_REF" >/dev/null || die "Invalid Telegram branch."
python3 -c 'import sys; sys.exit(sys.version_info < (3, 11))' || die "Python 3.11+ required."
service_group="$(id -gn "$ORCA_SERVICE_USER")"
admin_home="$(getent passwd ubuntu | cut -d: -f6)"
staged_env="$admin_home/remote-lightsail-secrets/telegram.env"

# A shared web/worker deployment must not lose access when stockbot-owned files
# change owners. Stop/migrate those services together before changing accounts.
for other_unit in stock-chatbot-web.service stock-chatbot-polymarket-refresh.service \
    stock-chatbot-polymarket-refresh.timer stock-chatbot-polymarket-brief.service \
    stock-chatbot-polymarket-trending.service polymarket-shorts.service polymarket-shorts.timer; do
    if systemctl is-active --quiet "$other_unit"; then
        case "$other_unit" in
            *.timer) die "Stop $other_unit before migrating this checkout." ;;
        esac
        other_user="$(systemctl show "$other_unit" -p User --value)"
        [ "$other_user" = "$ORCA_SERVICE_USER" ] \
            || die "$other_unit still uses $other_user; migrate the shared app account before deployment."
    fi
done

# Validate before stopping a running service. Secrets/data are never reset by Git.
if sudo test -d "$TELEGRAM_BOT_DIR/.git"; then
    # Existing stockbot deployments need ownership transferred before using Git.
    repo_owner="$(sudo stat -c %U "$TELEGRAM_BOT_DIR")"
    old_git() { sudo -u "$repo_owner" -H git -C "$TELEGRAM_BOT_DIR" "$@"; }
    actual_repo="$(old_git remote get-url origin)"
    [ "${actual_repo%.git}" = "${TELEGRAM_BOT_REPO%.git}" ] || die "Existing checkout has a different origin."
    # Runtime data and the captured dependency lock are intentionally untracked.
    if [ "$TELEGRAM_BOT_UPDATE" = 1 ]; then
        [ -z "$(old_git status --porcelain --untracked-files=no)" ] || die "Existing checkout has tracked changes; preserve them before updating."
    fi
    [ "$(old_git branch --show-current)" = "$TELEGRAM_BOT_REF" ] || die "Existing checkout is on a different branch."
elif sudo test -e "$TELEGRAM_BOT_DIR"; then
    die "$TELEGRAM_BOT_DIR exists without a Git checkout; preserve it and migrate it before deployment."
fi
sudo test -s "$staged_env" || sudo test -s "$TELEGRAM_BOT_DIR/.env" \
    || die "Missing bot .env. Set TELEGRAM_BOT_ENV_FILE in local config.env and run sync-host.sh."

sudo apt-get update -qq
sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3-venv python3-pip
if command -v gh >/dev/null 2>&1 && as_orca gh auth status >/dev/null 2>&1; then
    as_orca gh auth setup-git
fi

# Stop the old service before changing code, ownership or dependencies.
sudo systemctl stop stock-chatbot.service 2>/dev/null || {
    if systemctl cat stock-chatbot.service >/dev/null 2>&1; then
        die "Could not stop existing Telegram service."
    fi
}
trap 'warn "Telegram deployment failed. Fix the error and rerun 08-telegram-bot.sh; the bot may be stopped."' ERR
if sudo test -d "$TELEGRAM_BOT_DIR/.git"; then
    sudo chown -R "$ORCA_SERVICE_USER:$service_group" "$TELEGRAM_BOT_DIR"
    if [ "$TELEGRAM_BOT_UPDATE" = 1 ]; then
        as_orca env GIT_TERMINAL_PROMPT=0 git -C "$TELEGRAM_BOT_DIR" fetch origin "$TELEGRAM_BOT_REF"
        as_orca git -C "$TELEGRAM_BOT_DIR" merge --ff-only FETCH_HEAD
    fi
else
    sudo install -d -o "$ORCA_SERVICE_USER" -g "$service_group" -m 0750 "$TELEGRAM_BOT_DIR"
    as_orca env GIT_TERMINAL_PROMPT=0 git clone --branch "$TELEGRAM_BOT_REF" --single-branch \
        "$TELEGRAM_BOT_REPO" "$TELEGRAM_BOT_DIR"
fi
if sudo test -s "$staged_env"; then
    sudo install -o "$ORCA_SERVICE_USER" -g "$service_group" -m 0600 "$staged_env" "$TELEGRAM_BOT_DIR/.env"
fi
sudo chmod 0600 "$TELEGRAM_BOT_DIR/.env"
as_orca python3 -m venv "$TELEGRAM_BOT_DIR/venv"
requirements="$TELEGRAM_BOT_DIR/requirements.txt"
if [ -f "$TELEGRAM_BOT_DIR/requirements.lock.txt" ]; then
    requirements="$TELEGRAM_BOT_DIR/requirements.lock.txt"
fi
as_orca "$TELEGRAM_BOT_DIR/venv/bin/python" -m pip install -r "$requirements"
as_orca /bin/bash -c 'cd "$1" && exec venv/bin/python -c "import telegram_bot.main"' bash "$TELEGRAM_BOT_DIR"

# Use the app repository's service definition, overriding only account and paths.
unit_tmp="$(mktemp)"
trap 'rm -f "$unit_tmp"' EXIT
sed -e "s|^User=.*|User=$ORCA_SERVICE_USER|" \
    -e "s|^Group=.*|Group=$service_group|" \
    -e "s|/srv/stock-chatbot|$TELEGRAM_BOT_DIR|g" \
    "$TELEGRAM_BOT_DIR/infra/systemd/stock-chatbot.service" > "$unit_tmp"
sudo install -o root -g root -m 0644 "$unit_tmp" /etc/systemd/system/stock-chatbot.service
sudo systemctl daemon-reload
sudo systemctl reset-failed stock-chatbot.service 2>/dev/null || true
if [ "$TELEGRAM_BOT_START" = 0 ]; then
    sudo systemctl disable stock-chatbot.service
    ok "Telegram installed as $ORCA_SERVICE_USER but stopped. Start only after stopping the source bot."
    exit 0
fi
sudo systemctl enable stock-chatbot.service
sudo systemctl restart stock-chatbot.service
sleep 5
sudo systemctl is-active --quiet stock-chatbot.service || die "Telegram failed to start; inspect journalctl -u stock-chatbot.service."
[ "$(systemctl show stock-chatbot.service -p User --value)" = "$ORCA_SERVICE_USER" ] \
    || die "A systemd override changed the Telegram service user."
ok "Telegram active as $ORCA_SERVICE_USER; commit $(as_orca git -C "$TELEGRAM_BOT_DIR" rev-parse --short HEAD)"

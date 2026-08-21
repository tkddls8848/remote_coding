#!/usr/bin/env bash
# Host setup 3/6 — register Orca as a systemd service.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[ -n "$DOMAIN" ] || die "DOMAIN is empty; check ~/orca-host.env"
[ -x "$ORCA_BIN" ] || die "Orca runtime is missing: $ORCA_BIN. Run 02 first."

if [ -f "$HOME/.orca-needs-xvfb" ]; then
    EXEC="/usr/bin/xvfb-run -a $ORCA_BIN serve --port $ORCA_PORT --pairing-address wss://$DOMAIN"
    say "Using xvfb-run based on the 02 probe"
else
    EXEC="$ORCA_BIN serve --port $ORCA_PORT --pairing-address wss://$DOMAIN"
fi

sudo tee /etc/systemd/system/orca-serve.service >/dev/null <<UNIT
[Unit]
Description=Orca headless runtime
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Environment=HOME=/home/ubuntu
Environment=LIBGL_ALWAYS_SOFTWARE=1
ExecStart=$EXEC
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl enable --now orca-serve
sudo systemctl restart orca-serve

say "Waiting for Orca"
for _ in $(seq 1 30); do
    curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$ORCA_PORT/web-index.html" && break
    sleep 1
done

curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$ORCA_PORT/web-index.html" || {
    journalctl -u orca-serve -n 40 --no-pager >&2
    die "Orca is active but did not answer on 127.0.0.1:$ORCA_PORT"
}

systemctl is-active --quiet orca-serve || {
    journalctl -u orca-serve -n 40 --no-pager >&2
    die "orca-serve is not active"
}
ok "orca-serve active (127.0.0.1:$ORCA_PORT)"
say "Next: ./04-caddy.sh"

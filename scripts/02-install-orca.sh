#!/usr/bin/env bash
# Host setup 2/6 — install the official Orca Linux AppImage and verify serve mode.

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

export DEBIAN_FRONTEND=noninteractive
NEEDS_XVFB_FLAG="$HOME/.orca-needs-xvfb"

need curl

# The AppImage bundles Chromium but still uses the host ALSA runtime. Ubuntu
# 24.04 provides it as libasound2t64 (the package supplies libasound.so.2).
say "Installing the Orca runtime dependency"
sudo apt-get update -qq
sudo apt-get install -y -qq libasound2t64

# `orca` on Linux is commonly the GNOME screen reader. Do not use the PATH
# command or the legacy .deb layout: install the official AppImage and extract
# it once so the runtime does not depend on FUSE being present on this server.
if [ ! -x "$ORCA_BIN" ]; then
    say "Downloading the official Orca Linux AppImage"
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' EXIT
    curl -fL --retry 3 \
        -o "$tmpdir/orca-linux.AppImage" \
        https://github.com/stablyai/orca/releases/latest/download/orca-linux.AppImage

    sudo install -d -m 755 /opt/orca
    sudo install -m 755 "$tmpdir/orca-linux.AppImage" "$ORCA_APPIMAGE"
    sudo rm -rf /opt/orca/squashfs-root
    (
        cd /opt/orca
        sudo "$ORCA_APPIMAGE" --appimage-extract >/dev/null
    )
    # sudo can preserve a restrictive umask, leaving the extracted directory
    # unreadable by the ubuntu user that runs the systemd service.
    sudo chmod -R a+rX /opt/orca/squashfs-root
fi

[ -x "$ORCA_BIN" ] || die "Orca extraction failed; expected executable: $ORCA_BIN"
ok "Orca installed: $ORCA_BIN"

say "Verifying headless startup"
rm -f "$NEEDS_XVFB_FLAG"

probe() {
    local mode="$1" log rc=1 pid
    log="$(mktemp)"

    if [ "$mode" = "xvfb" ]; then
        xvfb-run -a env LIBGL_ALWAYS_SOFTWARE=1 "$ORCA_BIN" serve --port "$ORCA_PORT" >"$log" 2>&1 &
    else
        env LIBGL_ALWAYS_SOFTWARE=1 "$ORCA_BIN" serve --port "$ORCA_PORT" >"$log" 2>&1 &
    fi
    pid=$!

    for _ in $(seq 1 30); do
        if curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:$ORCA_PORT/web-index.html"; then
            rc=0
            break
        fi
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
    done

    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    [ "$rc" -eq 0 ] || { warn "Startup failed. Recent log:"; tail -20 "$log" >&2; }
    rm -f "$log"
    return "$rc"
}

if probe direct; then
    ok "Headless startup works without xvfb"
else
    warn "Retrying with xvfb"
    sudo apt-get update -qq
    sudo apt-get install -y -qq xvfb
    if probe xvfb; then
        touch "$NEEDS_XVFB_FLAG"
        ok "Headless startup works through xvfb"
    else
        die "Orca did not start even through xvfb. Review the log above."
    fi
fi

say "Next: ./03-orca-service.sh"

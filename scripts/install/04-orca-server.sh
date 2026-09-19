#!/usr/bin/env bash
# 호스트 설정 4/6 — Orca AppImage, 전용 계정, systemd 상시 서비스.

. "$(dirname "${BASH_SOURCE[0]}")/../util/lib.sh"

need curl
need file
need jq
need tailscale

[[ "$ORCA_PORT" =~ ^[0-9]+$ ]] || die "ORCA_PORT는 숫자여야 한다."
((ORCA_PORT >= 1024 && ORCA_PORT <= 65535)) || die "ORCA_PORT는 1024~65535 범위여야 한다."
[[ "$ORCA_SERVICE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "ORCA_SERVICE_USER 형식이 잘못되었다."

tailscale_ip="$(tailscale ip -4 2>/dev/null | head -1)"
[ -n "$tailscale_ip" ] || die "Tailscale이 연결되지 않았다. 먼저 ./install/03-private-network.sh를 실행할 것."

if [ -n "$TAILSCALE_HOSTNAME" ]; then
    current_hostname="$(tailscale status --json | jq -r '.Self.HostName // empty')"
    [ "${current_hostname,,}" = "${TAILSCALE_HOSTNAME,,}" ] \
        || die "Tailscale 호스트명이 기대값과 다르다 (현재: ${current_hostname:-없음}, 기대: $TAILSCALE_HOSTNAME). ./install/03-private-network.sh를 다시 실행할 것."
fi

# Orca Web은 crypto.randomUUID 등을 사용한다. Tailscale IP의 평문 HTTP로 열면 브라우저가
# Web Crypto를 제한해 root가 렌더링되지 않고 빈 화면만 보인다. 기본 구성은 Tailscale Serve가
# TLS를 종료하고 localhost의 Orca로 WebSocket/HTTP를 프록시하게 한다.
configure_tailscale_serve=0
if [ -z "$ORCA_PAIRING_ADDRESS" ]; then
    tailscale_dns="$(tailscale status --json | jq -r '.Self.DNSName // empty' | sed 's/\.$//')"
    [ -n "$tailscale_dns" ] || die "Tailscale MagicDNS 이름을 찾지 못했다. tailnet에서 MagicDNS를 활성화할 것."
    ORCA_PAIRING_ADDRESS="https://${tailscale_dns}"
    configure_tailscale_serve=1
else
    case "$ORCA_PAIRING_ADDRESS" in
        https://*|wss://*) ;;
        *.ts.net|*.ts.net:*) ORCA_PAIRING_ADDRESS="https://${ORCA_PAIRING_ADDRESS}" ;;
        *) die "ORCA_PAIRING_ADDRESS는 HTTPS/WSS 주소여야 한다. 평문 HTTP/WS는 브라우저에서 빈 화면을 만든다." ;;
    esac
fi

if [ "$configure_tailscale_serve" -eq 1 ]; then
    say "Tailscale Serve HTTPS → Orca localhost:${ORCA_PORT}"
    # 이 호스트의 Serve 구성은 이 IaC가 전담한다. 이전 MagicDNS 이름이 남아 있어도
    # 최초 설치와 재프로비저닝의 결과가 같도록 초기화한 뒤 명시적인 localhost URL로 맞춘다.
    sudo tailscale serve reset >/dev/null
    if ! serve_output="$(sudo tailscale serve --bg "http://127.0.0.1:${ORCA_PORT}" 2>&1)"; then
        printf '%s\n' "$serve_output" >&2
        die "Tailscale Serve 활성화가 필요하다. 출력된 승인 URL은 관리 PC 브라우저에서 연 뒤 이 스크립트를 다시 실행할 것."
    fi
    printf '%s\n' "$serve_output"
    sudo tailscale serve status | grep -Fq "https://${tailscale_dns}" \
        || die "Tailscale Serve가 현재 MagicDNS 이름(${tailscale_dns})으로 구성되지 않았다."
fi

case "$(uname -m)" in
    x86_64)
        asset="orca-linux.AppImage"
        machine_pattern='x86-64'
        ;;
    aarch64|arm64)
        asset="orca-linux-arm64.AppImage"
        machine_pattern='ARM aarch64'
        ;;
    *) die "지원하지 않는 아키텍처: $(uname -m)" ;;
esac

if ! id "$ORCA_SERVICE_USER" >/dev/null 2>&1; then
    say "Orca 전용 계정 생성: $ORCA_SERVICE_USER"
    sudo useradd --system --create-home --shell /usr/sbin/nologin "$ORCA_SERVICE_USER"
fi
ORCA_SERVICE_GROUP="$(id -gn "$ORCA_SERVICE_USER")"

# useradd 로 만든 계정은 비밀번호가 잠겨 있어 `su - orca` 가 막힌다. 다른 설정과 같이
# 매 실행마다 선언적으로 맞춘다 (수동으로 바꾼 비밀번호는 재실행 때 되돌아간다).
# 이 값으로 원격 로그인은 되지 않는다 — 06-vscode-remote.sh 가 이 계정의 SSH 비밀번호
# 인증을 끈다. 다만 호스트를 입주 앱과 공유하므로, 약한 값이면 같은 호스트의 다른 계정이
# `su` 로 넘어올 수 있다는 점은 감수하는 선택이다.
if [ -n "$ORCA_SERVICE_PASSWORD" ]; then
    case "$ORCA_SERVICE_PASSWORD" in
        *$'\n'*|*$'\r'*) die "ORCA_SERVICE_PASSWORD 에 줄바꿈이 들어 있다." ;;
    esac
    # 이 호스트는 입주 앱과 공유한다. 짧은 값은 같은 호스트의 다른 계정에 `su` 경로를
    # 열어 준다 (docs/stability-plan.md 6.9). 생성 예: openssl rand -base64 32
    if [ "${#ORCA_SERVICE_PASSWORD}" -lt "$ORCA_SERVICE_PASSWORD_MIN_LEN" ]; then
        die "ORCA_SERVICE_PASSWORD 가 너무 짧다 (${#ORCA_SERVICE_PASSWORD}자, 최소 ${ORCA_SERVICE_PASSWORD_MIN_LEN}자).
  openssl rand -base64 32 로 만들거나 ORCA_SERVICE_PASSWORD_MIN_LEN 을 낮출 것."
    fi
    say "$ORCA_SERVICE_USER 로컬 비밀번호 설정"
    # 인자가 아니라 stdin 으로만 넘긴다. ps 목록이나 저널에 값이 남지 않는다.
    printf '%s:%s\n' "$ORCA_SERVICE_USER" "$ORCA_SERVICE_PASSWORD" | sudo chpasswd
    ok "비밀번호 설정됨 (06-vscode-remote.sh 로 로그인 셸을 준 뒤 su - $ORCA_SERVICE_USER 가 된다)"

    # 호스트 sshd 가 이 계정의 비밀번호 인증을 받아 준다면 방금 만든 값이 원격 로그인
    # 경로가 된다. 계정별 차단은 06-vscode-remote.sh 의 드롭인이 하므로, 아직 돌지 않았거나
    # 설정이 되돌아간 경우에는 알린다.
    if sudo sshd -T -C "user=$ORCA_SERVICE_USER,host=localhost,addr=127.0.0.1" 2>/dev/null \
        | grep -qix 'passwordauthentication yes'; then
        warn "sshd 가 $ORCA_SERVICE_USER 의 비밀번호 인증을 아직 허용한다."
        warn "./install/06-vscode-remote.sh 를 돌려 이 계정을 키 인증 전용으로 막을 것."
    fi
else
    warn "ORCA_SERVICE_PASSWORD 가 비어 있다 — 계정을 잠긴 상태로 둔다."
fi

# --- sudo 권한 --------------------------------------------------------------
# 이 계정으로 붙은 사람과 에이전트가 호스트를 직접 관리할 수 있게 할지 결정한다.
# 정책은 config.env 의 ORCA_SERVICE_SUDO 하나로 선언하고 매 실행 그 상태로 맞춘다.
# 그룹 변경은 새로 여는 세션부터 적용된다 (이미 붙어 있는 셸은 다시 로그인해야 한다).
sudoers_file="/etc/sudoers.d/60-${ORCA_SERVICE_USER}-sudo"
sudo_log_file="/etc/sudoers.d/55-orca-sudo-log"
in_sudo_group() { id -nG "$ORCA_SERVICE_USER" | tr ' ' '\n' | grep -qx -e sudo -e admin; }

# 임시 파일에서 visudo 검사를 통과한 것만 설치한다. 드롭인의 문법 오류 하나가 호스트의
# sudo 전체를 잠그기 때문이다.
install_sudoers() {
    local dest="$1" tmp
    tmp="$(mktemp)"
    cat > "$tmp"
    if sudo visudo -c -q -f "$tmp"; then
        sudo install -o root -g root -m 0440 "$tmp" "$dest"
        rm -f "$tmp"
    else
        rm -f "$tmp"
        die "sudoers 드롭인 문법 검사에 실패했다 ($dest). 설치하지 않았다."
    fi
}

# --- sudo I/O 로깅 ----------------------------------------------------------
# 누가 무엇을 root 로 실행했는지 남기는 최소선이다. 화이트리스트를 아직 못 좁혔더라도
# 이것만은 먼저 켠다 — 침해 후 "범위를 특정할 수 없는 것"이 복구를 가장 어렵게 만든다.
# 재생: sudoreplay -l / sudoreplay <ID>. docs/stability-plan.md 6.1-3, 6.6-1.
case "$ORCA_SUDO_LOG" in
    on)
        sudo install -d -o root -g root -m 0700 "$ORCA_SUDO_LOG_DIR"
        install_sudoers "$sudo_log_file" <<SUDOLOG
# install/04-orca-server.sh 가 생성 (ORCA_SUDO_LOG=on).
# root 로 실행한 내역을 남긴다. sudoreplay -l 로 목록, sudoreplay <ID> 로 재생한다.
Defaults log_input, log_output
Defaults iolog_dir=$ORCA_SUDO_LOG_DIR
# 재생 자체는 다시 기록하지 않는다 (로그가 로그를 낳는다).
Defaults!/usr/bin/sudoreplay       !log_output
Defaults!/usr/local/bin/sudoreplay !log_output
SUDOLOG
        ok "sudo I/O 로깅 켜짐 ($ORCA_SUDO_LOG_DIR)"
        ;;
    off)
        sudo rm -f "$sudo_log_file"
        warn "sudo I/O 로깅이 꺼져 있다 (ORCA_SUDO_LOG=off) — root 실행 내역이 남지 않는다."
        ;;
    *)
        die "ORCA_SUDO_LOG 는 on | off 중 하나여야 한다 (현재: $ORCA_SUDO_LOG)"
        ;;
esac

# --- sudo 권한 정책 ---------------------------------------------------------
case "$ORCA_SERVICE_SUDO" in
    nopasswd|whitelist|password)
        if in_sudo_group; then
            ok "$ORCA_SERVICE_USER 는 이미 sudo 그룹"
        else
            say "$ORCA_SERVICE_USER 를 sudo 그룹에 넣는다"
            sudo usermod -aG sudo "$ORCA_SERVICE_USER"
            ok "sudo 그룹 추가 (새 로그인부터 적용)"
        fi
        ;;
esac

case "$ORCA_SERVICE_SUDO" in
    nopasswd)
        install_sudoers "$sudoers_file" <<SUDOERS
# install/04-orca-server.sh 가 생성 (ORCA_SERVICE_SUDO=nopasswd).
# headless 에이전트는 비밀번호를 입력할 수 없어 NOPASSWD 로 둔다.
#
# 이 한 줄이 이 호스트의 신뢰경계 전부다 — 이 계정에 도달하는 모든 경로는 그대로
# 호스트 root 다. 좁히려면 ORCA_SERVICE_SUDO=whitelist 로 넘어간다.
# docs/stability-plan.md 6.0~6.1.
$ORCA_SERVICE_USER ALL=(ALL) NOPASSWD:ALL
SUDOERS
        ok "sudo 비밀번호 없이 허용 ($sudoers_file)"
        warn "이 계정은 비밀번호 없이 무엇이든 root 로 실행한다. 에이전트가 읽는 저장소 콘텐츠가"
        warn "곧 root 명령이 될 수 있다 — ORCA_SERVICE_SUDO=whitelist 로 좁히는 것을 검토할 것."
        ;;
    whitelist)
        [ -n "${ORCA_SUDO_WHITELIST//[[:space:]]/}" ] \
            || die "ORCA_SERVICE_SUDO=whitelist 인데 ORCA_SUDO_WHITELIST 가 비었다."
        # 여러 줄을 sudoers 한 줄의 Cmnd_List(쉼표 구분)로 접는다.
        cmnd_list="$(printf '%s\n' "$ORCA_SUDO_WHITELIST" \
            | sed -e 's/[[:space:]]*$//' -e '/^$/d' -e '/^#/d' \
            | paste -sd, -)"
        [ -n "$cmnd_list" ] || die "ORCA_SUDO_WHITELIST 에 유효한 명령이 없다."
        install_sudoers "$sudoers_file" <<SUDOERS
# install/04-orca-server.sh 가 생성 (ORCA_SERVICE_SUDO=whitelist).
# 에이전트에게 실제로 필요한 명령만 NOPASSWD 로 연다. 목록은 config.env 의
# ORCA_SUDO_WHITELIST 하나에서만 바꾼다. docs/stability-plan.md 6.1-2.
$ORCA_SERVICE_USER ALL=(ALL) NOPASSWD: $cmnd_list
SUDOERS
        ok "sudo 화이트리스트 적용 ($sudoers_file)"
        printf '%s\n' "$ORCA_SUDO_WHITELIST" | sed 's/^/       /'
        ;;
    password)
        sudo rm -f "$sudoers_file"
        if [ -n "$ORCA_SERVICE_PASSWORD" ]; then
            ok "sudo 는 $ORCA_SERVICE_USER 의 비밀번호를 물어본다"
        else
            warn "ORCA_SERVICE_PASSWORD 가 비어 있어 sudo 가 물어보는 비밀번호를 댈 수 없다."
            warn "비밀번호를 정하거나 ORCA_SERVICE_SUDO=nopasswd/whitelist 로 둘 것."
        fi
        ;;
    off)
        sudo rm -f "$sudoers_file"
        if in_sudo_group; then
            say "$ORCA_SERVICE_USER 를 sudo 그룹에서 뺀다"
            sudo deluser "$ORCA_SERVICE_USER" sudo >/dev/null 2>&1 || true
            sudo deluser "$ORCA_SERVICE_USER" admin >/dev/null 2>&1 || true
        fi
        ok "$ORCA_SERVICE_USER 에 sudo 권한 없음"
        ;;
    *)
        die "ORCA_SERVICE_SUDO 는 nopasswd | whitelist | password | off 중 하나여야 한다 (현재: $ORCA_SERVICE_SUDO)"
        ;;
esac

sudo install -d -o root -g root -m 0755 /opt/orca
sudo install -d -o "$ORCA_SERVICE_USER" -g "$ORCA_SERVICE_GROUP" -m 0750 \
    "/home/$ORCA_SERVICE_USER/workspace"

release_base="https://github.com/stablyai/orca/releases/download/${ORCA_VERSION}"
download_url="$release_base/$asset"
tmp="$(mktemp)"
sums="$(mktemp)"
trap 'rm -f "$tmp" "$sums"' EXIT

say "Orca ${ORCA_VERSION} 내려받기"
curl -fL --retry 3 "$download_url" -o "$tmp"

# --- 무결성 검증 ------------------------------------------------------------
# ELF 헤더와 아키텍처 문자열만으로는 중간 오염이나 CDN 침해를 걸러내지 못한다.
# 불완전 다운로드도 ELF 헤더는 그대로 가진다. docs/stability-plan.md 4.3.
file_info="$(LC_ALL=C file "$tmp")"
grep -q 'ELF .* executable' <<<"$file_info" || die "다운로드 파일이 ELF 실행 파일이 아니다: $file_info"
grep -Fq "$machine_pattern" <<<"$file_info" || die "다운로드 파일 아키텍처가 호스트와 다르다: $file_info"

downloaded_bytes="$(stat -c %s "$tmp")"
if [ "$downloaded_bytes" -lt "$ORCA_MIN_BYTES" ]; then
    die "내려받은 파일이 너무 작다 (${downloaded_bytes}B < ${ORCA_MIN_BYTES}B) — 불완전 다운로드로 본다.
  값이 실제로 바뀐 릴리스라면 config.env 의 ORCA_MIN_BYTES 를 조정할 것."
fi

actual_sha="$(sha256sum "$tmp" | awk '{print $1}')"
expected_sha="$ORCA_SHA256"

# 기대 체크섬이 설정에 없으면 릴리스가 함께 올리는 체크섬 파일을 찾아본다.
if [ -z "$expected_sha" ]; then
    for name in "${asset}.sha256" "SHA256SUMS" "checksums.txt" "SHA256SUMS.txt"; do
        if curl -fsSL --retry 2 "$release_base/$name" -o "$sums" 2>/dev/null && [ -s "$sums" ]; then
            # `<sha>  <파일명>` 형식과 `<sha>` 한 줄 형식을 모두 받는다.
            expected_sha="$(awk -v a="$asset" '
                NF == 1 && length($1) == 64 { print $1; exit }
                $2 ~ ("(^|/)" a "$") || $2 == "*" a { print $1; exit }' "$sums")"
            [ -n "$expected_sha" ] && { ok "릴리스 체크섬 파일 사용: $name"; break; }
        fi
    done
fi

if [ -n "$expected_sha" ]; then
    [ "${expected_sha,,}" = "${actual_sha,,}" ] \
        || die "SHA256 이 일치하지 않는다 — 설치하지 않았다.
  기대: $expected_sha
  실제: $actual_sha
  네트워크 중간 오염이나 릴리스 자산 변조를 의심한다."
    ok "SHA256 검증 통과 ($actual_sha)"
elif [ "$ORCA_REQUIRE_CHECKSUM" = 1 ]; then
    die "기대 SHA256 을 구하지 못했고 ORCA_REQUIRE_CHECKSUM=1 이다 — 설치하지 않았다.
  config.env 의 ORCA_SHA256 에 값을 적거나 릴리스의 체크섬 파일명을 확인할 것.
  현재 파일의 값: $actual_sha"
else
    warn "이 릴리스에서 기대 SHA256 을 구하지 못했다 (체크섬 파일 없음, ORCA_SHA256 비어 있음)."
    warn "지금 값을 config.env 의 ORCA_SHA256 에 적어 두면 다음 설치부터 검증된다:"
    warn "  ORCA_SHA256=$actual_sha"
fi

# 이전에 설치한 바이너리와 달라졌는지도 본다. 버전을 그대로 둔 채 자산만 바뀌었다면
# 재빌드이거나 변조다 — 어느 쪽이든 조용히 지나갈 일이 아니다.
if sudo test -f /opt/orca/CHECKSUM && [ -z "$ORCA_SHA256" ]; then
    prev_sha="$(sudo awk -v v="$ORCA_VERSION" '$2 == v {print $1}' /opt/orca/CHECKSUM || true)"
    if [ -n "$prev_sha" ] && [ "$prev_sha" != "$actual_sha" ]; then
        die "같은 버전($ORCA_VERSION)인데 이전 설치와 SHA256 이 다르다 — 설치하지 않았다.
  이전: $prev_sha
  지금: $actual_sha
  의도한 재빌드라면 sudo rm /opt/orca/CHECKSUM 후 다시 실행할 것."
    fi
fi

sudo install -o root -g root -m 0755 "$tmp" /opt/orca/orca-linux.AppImage.new

had_previous=0
if sudo test -f /opt/orca/orca-linux.AppImage; then
    if sudo test -f /opt/orca/orca-linux.AppImage.previous; then
        die "이전 실패 시도의 보존 바이너리가 있다: /opt/orca/orca-linux.AppImage.previous
  재시도 전에 저널과 프로필 백업을 확인하고 수동 복구 또는 정리할 것."
    fi
    had_previous=1
    sudo cp -a /opt/orca/orca-linux.AppImage /opt/orca/orca-linux.AppImage.previous
    if sudo test -f /opt/orca/VERSION; then
        sudo cp -a /opt/orca/VERSION /opt/orca/VERSION.previous
    fi
    sudo systemctl stop orca-serve.service 2>/dev/null || true
fi
sudo mv -f /opt/orca/orca-linux.AppImage.new /opt/orca/orca-linux.AppImage
printf '%s\n' "$ORCA_VERSION" | sudo tee /opt/orca/VERSION >/dev/null
sudo chown root:root /opt/orca/VERSION
sudo chmod 0644 /opt/orca/VERSION
# 검증한 체크섬을 VERSION 옆에 남긴다. verify-host.sh 의 드리프트 검사가 이 값을
# 다시 쓴다 (docs/stability-plan.md 4.3-4, 6.6-4).
printf '%s  %s\n' "$actual_sha" "$ORCA_VERSION" | sudo tee /opt/orca/CHECKSUM >/dev/null
sudo chown root:root /opt/orca/CHECKSUM
sudo chmod 0644 /opt/orca/CHECKSUM

say "Orca 서비스 설정"
sudo install -d -o root -g "$ORCA_SERVICE_GROUP" -m 0750 /etc/orca
{
    printf 'ORCA_PORT=%q\n' "$ORCA_PORT"
    printf 'ORCA_PAIRING_ADDRESS=%q\n' "$ORCA_PAIRING_ADDRESS"
} | sudo tee /etc/orca/orca.env >/dev/null
sudo chown root:"$ORCA_SERVICE_GROUP" /etc/orca/orca.env
sudo chmod 0640 /etc/orca/orca.env

say "호스트 방화벽: SSH만 허용 (Orca는 Tailscale Serve가 localhost로 프록시)"
sudo ufw default deny incoming >/dev/null
# 아웃바운드는 전면 개방으로 둔다 — npm, GitHub, nodesource, Tailscale, AWS 가 모두
# 아웃바운드다. 대신 로깅을 켜 반출 흔적이라도 남게 한다. 인바운드 통제는 침입을 막고,
# 반출은 아웃바운드에서만 막힌다. docs/stability-plan.md 6.5.
sudo ufw default allow outgoing >/dev/null
sudo ufw logging low >/dev/null
sudo ufw allow 22/tcp comment 'SSH; outer Lightsail firewall restricts source' >/dev/null
# 이전 평문 HTTP 구성의 direct rule이 있으면 제거한다. HTTPS Serve는 이 규칙이 필요 없다.
sudo ufw delete allow in on tailscale0 to any port "$ORCA_PORT" proto tcp >/dev/null 2>&1 || true
sudo ufw --force enable >/dev/null

# --- 유닛 샌드박스 ----------------------------------------------------------
# 어디까지 조일 수 있는지는 이 계정의 sudo 정책이 정한다 (docs/stability-plan.md 6.4).
#   NoNewPrivileges 는 setuid 를 전면 차단하므로 sudo 경로 자체를 막는다. sudo 를 쓰는
#   구성에서 켜면 서비스가 아니라 운영이 막힌다 — ORCA_SERVICE_SUDO=off 일 때만 켠다.
#   ProtectSystem/ProtectHome/ProtectKernelTunables 는 유닛의 마운트 네임스페이스에
#   걸리므로 여기서 sudo 로 띄운 자식까지 함께 묶인다. 에이전트가 apt 나 /etc 를
#   건드려야 하는 nopasswd·whitelist·password 구성에서는 켜지 않는다.
hardening=""
case "$ORCA_SERVICE_SUDO" in
    off)
        hardening="NoNewPrivileges=true
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=/home/$ORCA_SERVICE_USER /opt/orca
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true"
        ok "유닛 하드닝: 전체 (ORCA_SERVICE_SUDO=off)"
        ;;
    *)
        hardening="# NoNewPrivileges / ProtectSystem / ProtectHome 는 ORCA_SERVICE_SUDO=off 일 때만 켠다.
# sudo 를 쓰는 현행 구성에서 켜면 에이전트의 호스트 관리 경로가 막힌다 (6.4)."
        ok "유닛 하드닝: 기본 (ORCA_SERVICE_SUDO=$ORCA_SERVICE_SUDO — sudo 경로와 충돌하는 항목은 제외)"
        ;;
esac

sudo tee /etc/systemd/system/orca-serve.service >/dev/null <<UNIT
[Unit]
Description=Orca headless coding agent runtime
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service
StartLimitIntervalSec=300
StartLimitBurst=5
# 재시작 한도를 소진해 failed 로 떨어지면 알린다 — 침묵 장애를 막는 지점이다.
# 유닛은 install/07-monitoring.sh 가 만든다. 없으면 systemd 가 조용히 무시한다.
OnFailure=orca-alert@%N.service

[Service]
Type=simple
User=$ORCA_SERVICE_USER
Group=$ORCA_SERVICE_GROUP
WorkingDirectory=/home/$ORCA_SERVICE_USER
EnvironmentFile=/etc/orca/orca.env
Environment=HOME=/home/$ORCA_SERVICE_USER
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LIBGL_ALWAYS_SOFTWARE=1
ExecStart=/opt/orca/orca-linux.AppImage serve --port \${ORCA_PORT} --pairing-address \${ORCA_PAIRING_ADDRESS} --json
StandardOutput=journal
StandardError=journal
KillMode=mixed
Restart=on-failure
RestartPreventExitStatus=3
RestartSec=5
PrivateTmp=true
RestrictSUIDSGID=true
RestrictRealtime=true
ProtectControlGroups=true
$hardening

# 메모리는 감시가 아니라 제어다. 커널 OOM killer 가 호스트에서 아무 프로세스나
# 고르게 두는 대신, 한도를 넘은 이 서비스만 예측 가능하게 멈추게 한다 (5.3 / 6.4).
MemoryHigh=$ORCA_MEMORY_HIGH
MemoryMax=$ORCA_MEMORY_MAX
OOMPolicy=stop

[Install]
WantedBy=multi-user.target
UNIT

sudo systemctl daemon-reload
sudo systemctl reset-failed orca-serve.service 2>/dev/null || true
start_marker="$(date --iso-8601=seconds)"
sudo systemctl enable --now orca-serve.service

ready=0
for _ in $(seq 1 60); do
    if sudo journalctl -u orca-serve.service --since "$start_marker" -o cat --no-pager \
        | jq -Re 'fromjson? | select(
            .type == "orca_server_ready" and
            .schemaVersion == 1 and
            .pairing.available == true and
            (.pairing.webClientUrl | type == "string" and length > 0)
        )' >/dev/null; then
        ready=1
        break
    fi
    systemctl is-active --quiet orca-serve.service || break
    sleep 1
done

if [ "$ready" -ne 1 ]; then
    sudo systemctl stop orca-serve.service 2>/dev/null || true
    if [ "$had_previous" -eq 1 ]; then
        warn "이전 바이너리는 /opt/orca/orca-linux.AppImage.previous에 보존했다."
        warn "상태 스키마가 바뀔 수 있으므로 바이너리만 되돌리지 말고 업그레이드 전 프로필 백업도 함께 복구한다."
    fi
    die "Orca 브라우저 준비 이벤트를 60초 안에 확인하지 못했다. 저널을 확인할 것."
fi

sudo rm -f /opt/orca/orca-linux.AppImage.previous /opt/orca/VERSION.previous

# --- 드리프트 기준값 --------------------------------------------------------
# 설치 직후의 sudoers 드롭인과 유닛 파일 해시를 남긴다. verify-host.sh 가 이 값과
# 대조해 누군가 바꿨는지 본다 (docs/stability-plan.md 6.6-4).
sudo install -d -o root -g root -m 0700 "$BASELINE_DIR"
record_baseline() {
    local name="$1" path="$2"
    if sudo test -e "$path"; then
        sudo sha256sum "$path" | awk '{print $1}' \
            | sudo tee "$BASELINE_DIR/$name.sha256" >/dev/null
    else
        sudo rm -f "$BASELINE_DIR/$name.sha256"
    fi
}
record_baseline sudoers-orca   "$sudoers_file"
record_baseline sudoers-log    "$sudo_log_file"
record_baseline orca-serve     /etc/systemd/system/orca-serve.service
sudo chmod 0600 "$BASELINE_DIR"/*.sha256 2>/dev/null || true
ok "드리프트 기준값 기록 ($BASELINE_DIR)"

ok "Orca 서비스 실행 중"
echo
echo "에이전트 계정 등록 (최초 1회):"
echo "  sudo -u $ORCA_SERVICE_USER -H /bin/bash -c 'cd \"\$HOME\" && exec codex login --device-auth'"
echo "  sudo -u $ORCA_SERVICE_USER -H /bin/bash -c 'cd \"\$HOME\" && exec gh auth login'"
echo
echo "브라우저 URL: sudo $SCRIPT_DIR/util/show-orca-access.sh"
echo "다음: ./install/05-repos.sh"

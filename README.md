# remote_coding

기존 서버 보존과 새 서버 전환 절차는 [서버 이관 문서](docs/server-migration.md)를 따른다.

AWS Lightsail에 Orca를 24시간 실행하고, 관리 PC의 **웹 브라우저**에서 코딩 에이전트와
워크트리·터미널·파일을 제어하는 개인용 원격 개발 시스템이다.

```text
관리 PC 브라우저
  └─ Tailscale 사설망 ──> Lightsail (Ubuntu 24.04, 4GB+)
                           ├─ orca-serve.service
                           ├─ Codex / Claude Code
                           ├─ /home/ubuntu/workspace/*
                           └─ stock-chatbot.service (ubuntu, /srv/stock-chatbot)

관리 PC VS Code ─ Tailscale SSH ──> ubuntu 계정 (같은 workspace 편집)

관리 PC SSH ── 공인 IP /32 ──> 설치·복구용 ubuntu 계정
```

기본 공인 방화벽은 SSH 22만 현재 관리자 IP `/32`로 연다. Orca의 TCP 6768은 Lightsail
공인 방화벽에 열지 않으며, 같은 Tailscale tailnet의 브라우저만 접근한다. Orca Remote
Server/Web Client는 Beta이므로 서버를 공개 인터넷에 직접 노출하지 않는다.

Orca와 Telegram 봇은 Lightsail 기본 계정 `ubuntu`로 실행한다. `ubuntu`에는
sudo 권한(`NOPASSWD:ALL`)과 로컬 비밀번호 `ubuntu`를 설정한다. SSH는 기존 Lightsail
공개키를 사용한다. 봇은 `08-telegram-bot.sh`가 저장소 전체를 `/srv/stock-chatbot`에
클론하고 Python 가상환경과 `stock-chatbot.service`를 설치한다. 기본값은 전환 전 정지이며,
기존 봇을 멈춘 뒤 `TELEGRAM_BOT_START=1`로 시작한다.
공개 웹·쇼츠 등 나머지 앱 서비스는 `stock_chatbot/infra/`에서 관리한다.

**AWS 자원을 만드는 Terraform은 이 저장소 하나뿐이다.** 입주 앱 저장소는 같은 자원을
선언하지 않고(Lightsail 공개 포트 API는 규칙 전체를 교체하므로 나중에 apply한 쪽이 상대의
규칙을 지운다), 대신 호스트가 제공하는 계약 값 — 리전·AZ·자동 스냅샷 시각·공개 웹 여부·
호스트 타임존(UTC) — 을 읽어 자기 유닛과 cron을 맞춘다. 표와 읽는 법은
[`terraform/README.md`](terraform/README.md)의 "입주 앱과의 계약"에 있다.

## 빠른 시작

Windows PowerShell에서 설정 예시를 복사한 뒤 값을 확인한다.

```powershell
Copy-Item .\terraform\terraform.tfvars.example .\terraform\terraform.tfvars
Copy-Item .\scripts\config.example.env .\scripts\config.env

& "C:\Program Files\Git\bin\bash.exe" ./scripts/util/provision-host.sh
```

그 다음 출력된 SSH 주소로 접속해 실행한다.

```bash
cd ~/remote-lightsail-scripts
./install/01-host-base.sh
./install/02-agent-cli.sh
./install/03-private-network.sh  # 최초 실행 시 인증 URL을 출력하고 완료될 때까지 대기

# Tailscale 인증이 완료되면
./install/04-orca-server.sh

# 자격증명은 반드시 Orca 서비스 계정에 등록한다. headless 서버는 device code를 쓴다.
sudo -u ubuntu -H /bin/bash -c 'cd "$HOME" && exec codex login --device-auth'
sudo -u ubuntu -H /bin/bash -c 'cd "$HOME" && exec gh auth login'

# 작업 대상 저장소를 /home/ubuntu/workspace 로 가져온다 (포크·보관은 기본 제외)
./install/05-repos.sh
./install/06-vscode-remote.sh

# 장애 알림, 자원 감시, 보안 이벤트 감사
./install/07-monitoring.sh
./install/08-telegram-bot.sh

./util/verify-host.sh
sudo ./util/show-orca-access.sh
```

마지막 명령이 출력한 URL을 같은 tailnet에 연결된 관리 PC의 브라우저에서 연다. URL에는
접근 capability가 포함되므로 비밀번호처럼 취급한다. 최초 페어링 뒤 브라우저는 발급된
클라이언트 자격증명을 보관하며, 서버 재부팅 후에도 다시 연결된다.

`sync-host.sh`는 Terraform의 `instance_name`을 `TAILSCALE_HOSTNAME`으로 전달한다.
`03-private-network.sh`는 최초 인증 때부터 이 이름을 적용하고 제어면 반영을 기다린 뒤 종료하므로,
Orca pairing URL과 Tailscale Serve 주소가 임시 EC2 호스트명(`ip-172-...`)으로 굳지 않는다.

## Telegram 배포

`scripts/config.env`에서 로컬 비밀 설정 파일을 지정하고 `sync-host.sh`를 실행한다:

```bash
TELEGRAM_BOT_ENV_FILE=C:/Users/PSI/orca/stock_chatbot/.env
```

이 파일은 SSH로 `~/remote-lightsail-secrets/telegram.env`에 전송한다(디렉터리 0700,
파일 0600). 08 단계가 앱 루트 `.env`로 설치한다. 기존 서버 `.env`가 있으면 새 파일
전송 없이도 설치할 수 있다. 토큰과 chat ID는 필수다.

GitHub에 push된 `TELEGRAM_BOT_REF`(기본 `main`)를 배포하므로 로컬 미커밋 변경은
포함되지 않는다. `telegram_bot/`만 복사하면 의존 파일이 빠지므로 저장소 전체를 받는다.
재배포도 `./install/08-telegram-bot.sh`로 실행한다. 작업 트리에 변경이 있거나 브랜치가
다르면 중단하고, 정상 체크아웃은 fast-forward로만 갱신한다. `.env`와 `data/`는 유지한다.
로컬에서 사용 중인 봇은 서버 시작 전에 종료해야 같은 토큰의 polling 충돌을 피할 수 있다.
관심종목·발송 이력 등 기존 `data/`는 Git에 없으므로 필요하면 별도로 옮긴다.

`provision-host.sh`는 인프라 생성과 파일 전송까지 한다. 출력된 서버 설치 순서의
08 단계는 기본적으로 설치만 수행한다. `TELEGRAM_BOT_START=1`일 때만 봇을 시작한다. `TELEGRAM_BOT_ENABLED=0`은 설치를 건너뛸 뿐
이미 실행 중인 봇을 중지하지 않는다.

새 서버의 `config.env`는 아래 값으로 설정한다. 기존 운영 서버는 이관 완료 전까지 유지한다:

```bash
ORCA_SERVICE_USER=ubuntu
ORCA_SERVICE_PASSWORD=ubuntu
ORCA_SERVICE_PASSWORD_MIN_LEN=5
ORCA_SERVICE_SUDO=nopasswd
```

기존 `/home/orca`의 프로필과 인증은 기본 설치가 자동으로 옮기지 않는다.
새 서버의 `ubuntu`에서 CLI 인증과 Orca 페어링을 확인한다.

## VS Code Remote-SSH

`06-vscode-remote.sh`는 `ubuntu`의 기존 `authorized_keys`를 유지하고 SSH 키 인증을
설정한다. `ORCA_SSH_PUBLIC_KEY`로 키를 추가할 수도 있다. `verify-host.sh`는
두 서비스의 실행 계정과 자동 시작 여부를 함께 확인한다.

```sshconfig
Host orca
    HostName <호스트>.<tailnet>.ts.net
    User ubuntu
    IdentityFile ~/.ssh/orca-lightsail-tokyo
    ServerAliveInterval 30
    ServerAliveCountMax 6
```

VS Code에서 `orca`에 접속하고 `/home/ubuntu/workspace`를 연다.

## 구성

| 위치 | 역할 |
|---|---|
| [`terraform/`](terraform/) | 4GB Lightsail, 고정 IP, 키페어, 자동 스냅샷, 공인 방화벽 |
| [`scripts/install/`](scripts/install/) | 호스트, Tailscale, 에이전트 CLI, Orca systemd, 저장소 설치, 감시·감사 |
| [`scripts/util/`](scripts/util/) | 생성·동기화·접근 URL 조회·검증·백업·업데이트 확인 |
| [`docs/lightsail-plan.md`](docs/lightsail-plan.md) | 상세 구축, 운영, 백업, 복구 절차 |
| [`docs/stability-plan.md`](docs/stability-plan.md) | 안정성·보안 갭 분석과 개선 계획 |

기본 `medium_3_0`은 Orca와 에이전트 하나를 위한 시작점이다. 병렬 에이전트, 큰 빌드,
여러 내장 브라우저 탭을 자주 쓰면 `large_3_0`(8GB) 이상을 권장한다.

## 일상 운영

```bash
sudo systemctl status orca-serve --no-pager
sudo journalctl -u orca-serve -f
sudo ./util/show-orca-access.sh
free -h

systemctl list-timers 'orca-*' --no-pager   # 감시 타이머
tail -20 /var/log/orca-alert.log            # 알림 내역
sudo sudoreplay -l                          # root 로 실행한 내역
./util/check-orca-update.sh                 # 새 버전 확인
sudo ./util/backup-orca.sh                  # 프로필 백업
```

`07-monitoring.sh`가 설치하는 감시 계층이 다음을 본다 — `orca-serve` 다운(5분), 디스크·스왑·
OOM(1시간), 자격증명 유효성(주 1회), Orca 새 버전(주 1회), `verify-host.sh` 전체 점검(일 1회).
알림은 `ALERT_WEBHOOK`으로 나가고, 비어 있으면 `/var/log/orca-alert.log`에만 쌓인다.

Orca 버전은 `scripts/config.env`의 `ORCA_VERSION`으로 고정한다. 버전을 바꾼 뒤
`04-orca-server.sh`를 다시 실행하면 바이너리를 교체하고 서비스를 재시작한다. 운영 데이터와
페어링 키는 `/home/ubuntu/.config/orca` 및 `/home/ubuntu/.config/Orca`에 있으므로 스냅샷/백업에
반드시 포함한다.

비밀정보(`config.env`, Terraform state/tfvars, Codex·GitHub 자격증명, 알림 웹훅, 브라우저
페어링 URL)는 Git에 커밋하지 않는다.

## 신뢰경계

에이전트가 읽는 저장소 콘텐츠는 그대로 에이전트의 입력이 되고, `orca` 계정의 sudo 를 거쳐
호스트 전체에 닿는다. 그래서 이 호스트에서 가장 중요한 설정은 두 개다.

- `REPOS` — 여기 등록한 저장소가 신뢰경계다. 실제 작업 대상만 명시적으로 적는다.
  `REPOS=all` 은 GitHub 계정 상태에 따라 목록이 자동으로 바뀌므로 경계를 사람이 선언한 것이
  아니다. `all` 을 쓰더라도 포크와 보관 저장소는 기본으로 빠진다.
- `ORCA_SERVICE_SUDO` — `nopasswd` 는 이 계정을 root 의 별칭으로 만든다. `whitelist` 로
  좁히거나, 최소한 `ORCA_SUDO_LOG=on`(기본)으로 실행 내역을 남긴다.

에이전트 각각의 **명령 자동 승인 정책**도 함께 확인한다. 이 값은 이 저장소의 코드가 아니라
Orca·Claude Code·Codex 의 런타임 설정에 있다.

전체 분석과 남은 항목은 [`docs/stability-plan.md`](docs/stability-plan.md) 6절에 있다.

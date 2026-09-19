# scripts/

Lightsail 호스트를 Tailscale 전용 Orca 서버로 만드는 멱등형 설치 스크립트 모음이다.

## 실행 순서

```bash
./install/01-host-base.sh
./install/02-agent-cli.sh
./install/03-private-network.sh  # 최초 실행 시 브라우저 인증 포함
./install/04-orca-server.sh

sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec codex login --device-auth'
sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec gh auth login'

./install/05-repos.sh
./install/06-vscode-remote.sh
./install/07-monitoring.sh
./util/verify-host.sh
sudo ./util/show-orca-access.sh
```

- `01-host-base.sh`: 타임존(`HOST_TIMEZONE`, 기본 UTC), Node.js 22, 빌드 도구, Xvfb, AppImage 의존성, 4GB swap
- `02-agent-cli.sh`: Codex CLI와 Claude Code 전역 설치
- `03-private-network.sh`: Tailscale 공식 APT 저장소, 안정적인 MagicDNS 이름, 최초 브라우저 인증
- `04-orca-server.sh`: 고정 버전 AppImage, `orca` 전용 계정, `orca-serve.service`, Tailscale Serve HTTPS.
  내려받은 바이너리는 ELF/아키텍처 확인에 더해 **SHA256 과 최소 크기를 검증**한다
  (`ORCA_SHA256`, 릴리스 체크섬 파일, `ORCA_MIN_BYTES`). 검증한 값은 `/opt/orca/CHECKSUM` 에
  남아 `verify-host.sh` 의 드리프트 검사가 다시 쓴다.
  계정 비밀번호는 `config.env`의 `ORCA_SERVICE_PASSWORD`로 매 실행 맞추고, 비어 있으면 계정을
  잠긴 채 둔다(최소 길이는 `ORCA_SERVICE_PASSWORD_MIN_LEN`). `su - orca` 전용이고 SSH는 06
  단계가 이 계정의 비밀번호 인증을 끄므로 원격 로그인은 키로만 한다.
  sudo 권한도 이 단계가 `ORCA_SERVICE_SUDO`(`nopasswd` 기본 / `whitelist` / `password` / `off`)
  대로 맞춘다 — 입주 앱과 공유하는 호스트이므로 sudo는 `/srv/<앱>`의 비밀까지 여는 선택이라는
  점을 알고 정한다. `ORCA_SUDO_LOG=on`(기본)이면 sudo I/O 로깅을 켜서 root 실행 내역을
  `sudoreplay` 로 재생할 수 있게 남긴다.
  유닛에는 `MemoryHigh`/`MemoryMax`/`OOMPolicy=stop` 이 걸린다 — 커널 OOM killer 가 임의의
  프로세스를 고르게 두는 대신 한도를 넘은 이 서비스만 멈추게 한다. `NoNewPrivileges` 와
  `ProtectSystem` 계열은 sudo 경로를 막으므로 `ORCA_SERVICE_SUDO=off` 일 때만 켜진다.
- `05-repos.sh`: `/home/orca/workspace`에 Orca 계정으로 저장소 클론.
  **여기 등록되는 저장소가 이 호스트의 신뢰경계다** — 에이전트는 그 코드의 README·설정·빌드
  스크립트를 읽고 명령을 실행하며, 의존성 설치 한 번이 곧 임의 코드 실행이다. 그래서 실제
  작업 대상만 `REPOS`에 공백으로 나열하는 것을 권장한다(`REPOS="gong-go homepage"`).
  `REPOS=all`이면 `GITHUB_OWNER`의 저장소를 `gh`로 열거하되 **포크와 보관됨은 기본으로 뺀다**
  (`REPOS_INCLUDE_FORKS=1` / `REPOS_INCLUDE_ARCHIVED=1`로 다시 넣을 수 있다). 포크는 제3자가
  쓴 코드다. 토큰에 `repo` 스코프가 필요하며 없으면 중단한다. 몇 개만 빼려면 `REPOS_EXCLUDE`를
  쓴다. 이미 클론된 저장소는 다시 클론하지 않고 `git fetch`만 한다.
- `06-vscode-remote.sh`: `orca` 계정 SSH 로그인(키 전용), sshd 드롭인, inotify 한도 — VS Code Remote-SSH.
  공개키는 **`orca` 전용 키**(`ORCA_SSH_PUBLIC_KEY`)를 쓴다. `ubuntu`의 키를 복사하면 키 하나가
  두 계정을 동시에 열고 `orca`는 sudo를 가지므로 키 탈취가 곧 호스트 root다. 옛 동작이 필요하면
  `ORCA_SSH_REUSE_ADMIN_KEY=1`로 명시한다. 스크립트는 두 계정의 키가 겹치는지도 확인한다.
- `07-monitoring.sh`: 장애 알림(systemd `OnFailure` + 5분 주기 확인), 디스크·스왑·OOM 감시,
  `auditd` 최소 규칙, SSH 로그인 알림, 토큰 유효성 주간 점검, Orca 새 버전 주간 확인,
  `verify-host.sh` 일일 실행. 알림은 `ALERT_WEBHOOK`으로 나가고 비어 있으면
  `/var/log/orca-alert.log`에만 남는다.

`config.env`는 로컬 전용이며 `sync-host.sh`가 필요한 값만 서버의 `host.env`(`0600`)로
복사한다. Tailscale·Codex·GitHub 토큰은 이 파일에 넣지 않는다. 여기 들어가는 자격증명은
`ORCA_SERVICE_PASSWORD`와 `ALERT_WEBHOOK`뿐이며, 예시 파일에는 값을 두지 않는다 —
비밀번호는 원격 로그인이 아니라 호스트 안 `su` 전용이고, 웹훅은 서버에서
`/etc/orca/alert.env`(0600 root)로 들어간다.

`ORCA_SSH_PUBLIC_KEY`에 파일 경로를 적으면 `sync-host.sh`가 내용으로 풀어 보낸다(서버는
관리 PC의 파일을 볼 수 없다).

`HOST_TIMEZONE`은 입주 앱과의 계약 값이다. 입주 앱의 `cron.d`는 타임존을 선언할 수 없어
호스트 설정을 그대로 따르고, Lightsail 자동 스냅샷 시각은 UTC 정시다. 두 시각을 같은
기준으로 읽기 위해 UTC로 고정하며, 바꾸면 입주 앱 저장소의 백업 시각도 함께 옮긴다.
`verify-host.sh`가 이 값을 확인한다.

`TAILSCALE_HOSTNAME`을 비우면 `sync-host.sh`가 Terraform의 `instance_name`을 사용한다.
최초 설치부터 같은 MagicDNS 이름을 유지하려면 특별한 이유가 없는 한 비워 둔다.

## 로컬 유틸리티

`util/provision-host.sh`는 Terraform apply, SSH 대기, 스크립트 동기화를 수행한다. 실제 계정
로그인은 사람의 브라우저 승인이 필요하므로 서버에서 마무리한다.

| 스크립트 | 실행 위치 | 하는 일 |
|---|---|---|
| `provision-host.sh` | 로컬 | Terraform apply → SSH 대기 → 스크립트 복사 |
| `sync-host.sh` | 로컬 | `install/`·`util/`·`host.env`(0600)를 서버로 복사 |
| `update-admin-ip.sh` | 로컬 | 현재 공인 IP 감지 → `terraform.tfvars` 의 `my_ip` 갱신 → `apply` |
| `verify-host.sh` | 서버 | 서비스·사설망·CLI·보안 통제·드리프트 전체 점검 |
| `backup-orca.sh` | 서버 | Orca 프로필 아카이브 → (선택) S3 업로드 |
| `check-orca-update.sh` | 양쪽 | 설치된 버전과 최신 릴리스 비교 |
| `show-orca-access.sh` | 서버 | 브라우저 페어링 URL 조회 |
| `diagnose-web-client.sh` | 서버 | 빈 화면 진단 |

`backup-orca.sh` 는 기본적으로 **자격증명을 담지 않는다**. `/home/orca/.codex` 와 gh 토큰을
S3 로 복사하면 자격증명의 사본이 하나 더 생기고 그 버킷이 새로운 침해 대상이 된다.
담으려면 `BACKUP_INCLUDE_CREDENTIALS=1` 과 함께 `BACKUP_KMS_KEY_ID`(SSE-KMS)·버킷 정책
(PutObject 만 허용)·Object Lock 을 같이 건다. 대안은 백업하지 않고 재발급하는 것이다 —
`codex login` 과 `gh auth login` 은 몇 분이면 끝난다.

```powershell
& "C:\Program Files\Git\bin\bash.exe" ./scripts/util/provision-host.sh
```

`util/show-orca-access.sh`는 systemd 저널의 최신 `orca_server_ready` JSON에서
`pairing.webClientUrl`만 출력한다. 출력 URL은 접근 권한 자체이므로 터미널 로그나 이슈에 붙이지
않는다.

긴 URL이 터미널에서 잘리는 것을 피하려면 관리 PC PowerShell에서 URL만 클립보드로 복사한다.

```powershell
$serverIp = terraform -chdir=terraform output -raw static_ip
ssh "ubuntu@$serverIp" "sudo ~/remote-lightsail-scripts/util/show-orca-access.sh --url-only" | Set-Clipboard
```

Web Client가 빈 화면이면 서버에서 `sudo ./util/diagnose-web-client.sh`를 실행한다. 이 진단은
페어링 URL을 출력하지 않고 HTML·JavaScript 번들·Tailscale 주소만 확인한다.

Orca Web은 브라우저의 보안 컨텍스트가 필요하므로 최종 URL은 반드시
`https://<호스트>.<tailnet>.ts.net/web-index.html#pairing=...` 형태여야 한다. Tailscale IP의
`http://100.x.x.x:6768/...` 주소는 HTML이 열려도 Web Crypto 초기화가 중단되어 빈 화면이 된다.

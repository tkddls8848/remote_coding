# Lightsail 상시 Orca 서버 구축·운영 기준

> 기준일: 2026-08-24  
> 목표: AWS Lightsail에서 Orca와 코딩 에이전트를 상시 실행하고, 같은 Tailscale tailnet의 관리 PC 브라우저로 제어한다.

## 1. 현행 기준

| 항목 | 현행 값 |
|---|---|
| 저장소 | `remote_coding` (루트) |
| AWS 리전 / OS | `ap-northeast-1` (도쿄) / Ubuntu 24.04 |
| 기본 번들 | `medium_3_0` — 4GB RAM, 2 vCPU |
| swap | `/swapfile` 4GB |
| Orca | `v1.4.188`, `/opt/orca/orca-linux.AppImage` |
| 서비스 계정 | `orca` (`/home/orca`) |
| 서비스 | `orca-serve.service`, `tailscaled.service` |
| 내부 포트 | Orca `6768`; Lightsail 공인 방화벽에는 미개방 |
| 브라우저 경로 | Tailscale Serve가 HTTPS/WSS를 종료하고 `127.0.0.1:6768`로 프록시 |
| 에이전트 인증 | `orca` 계정에서 `codex login --device-auth` |
| 기본 개발 저장소 | `gong-go`, `homepage`, `naraapi`, `pathfinder`, `devlog` |

리포지터리에는 인프라와 설치 절차가 들어 있다. 실제 서버의 존재·실행 상태는 Git 파일만으로
판단하지 않고 Terraform/AWS와 서버 점검 명령으로 별도 확인한다.

## 2. 아키텍처

```text
관리 PC
├─ Tailscale
├─ 최신 Chrome/Edge
└─ https://<server>.<tailnet>.ts.net/web-index.html#pairing=...
                │ HTTPS + WSS (tailnet 전용)
                ▼
Lightsail Ubuntu 24.04 / medium_3_0
├─ tailscaled
│  └─ Tailscale Serve :443 → http://127.0.0.1:6768
├─ orca-serve.service
│  ├─ Web Client / WebSocket runtime
│  ├─ terminals / worktrees / browser tabs
│  └─ Codex 또는 Claude Code
├─ UFW: 인바운드 SSH만 허용
└─ /home/orca
   ├─ .config/orca, .config/Orca   # 런타임 상태·페어링
   ├─ .codex                       # Codex 자격증명·설정
   └─ workspace/                   # 개발 저장소
```

관리면과 작업면은 다음처럼 분리한다.

- SSH 22: `ubuntu` 관리자 계정용이며 Lightsail 공인 방화벽에서 현재 관리자 공인 IP `/32`만 허용한다.
- Orca 6768: 공인 방화벽에 열지 않는다. UFW에서도 직접 tailnet 공개하지 않고 Tailscale Serve가
  localhost로 프록시한다.
- 브라우저: Tailscale MagicDNS 이름과 자동 발급 HTTPS 인증서를 사용한다.
- 에이전트와 저장소: 로그인 셸이 없는 `orca` system user가 소유한다.

평문 `http://100.x.x.x:6768`은 사용하지 않는다. Orca Web이 사용하는 Web Crypto API가 비보안
컨텍스트에서 제한되어 HTML·JS가 모두 HTTP 200이어도 빈 화면이 될 수 있다.

## 3. 디렉터리와 책임

```text
.
├─ terraform/             # 인스턴스, 고정 IP, 키페어, 공인 방화벽, 자동 스냅샷
│  └─ iam-policy.json     # 위 자원에 필요한 Lightsail 권한 (도쿄 리전으로 제한)
├─ scripts/
│  ├─ config.example.env  # 호스트 타임존, Orca 버전과 클론 대상 예시
│  ├─ install/            # 서버 설치 01~07
│  └─ util/               # 프로비저닝, 동기화, URL 조회, 진단, 검증
└─ docs/                  # 운영 기준과 별도 통합 계획
```

- Terraform은 Lightsail 자원만 관리하며, 이 계정의 Lightsail 자원을 만드는 코드는
  이 디렉터리 하나뿐이다. 입주 앱 저장소는 AWS 자원을 선언하지 않고, 호스트에 요구하는
  값(공개 웹·스냅샷 시각·타임존)은 `terraform/README.md`의 계약 표를 따른다.
- 호스트 패키지, Tailscale, Orca, 개발 CLI와 개발 클론은 `scripts/`가 관리한다.
- Codex·GitHub·Tailscale 자격증명과 Orca pairing URL은 Terraform 변수나 Git 파일에 넣지 않는다.
- `terraform.tfvars`, Terraform state, `scripts/config.env`는 로컬 실행 상태이므로 커밋하지 않는다.

## 4. 신규 구축

### 4.1 관리 PC

저장소 루트에서 실행한다.

```powershell
Copy-Item terraform\terraform.tfvars.example terraform\terraform.tfvars
Copy-Item scripts\config.example.env scripts\config.env

& "C:\Program Files\Git\bin\bash.exe" ./scripts/util/provision-host.sh
```

`provision-host.sh`는 다음 작업까지만 자동화한다.

1. Terraform/AWS/SSH 전제 확인
2. `terraform init/apply`
3. 새 호스트의 SSH 대기
4. `install/`, `util/`, 비밀이 아닌 `host.env`를 서버로 복사

계정 로그인과 `install/*.sh` 실행은 서버에서 사람이 완료한다.

### 4.2 서버

```bash
cd ~/remote-lightsail-scripts
./install/01-host-base.sh
./install/02-agent-cli.sh
./install/03-private-network.sh  # 최초 실행 시 인증 URL을 출력하고 완료될 때까지 대기
```

스크립트가 출력한 Tailscale 인증 URL은 원격 서버 안의 브라우저가 아니라 관리 PC 브라우저에서 연다. 관리
PC도 같은 tailnet에 로그인해야 한다.

`sync-host.sh`가 Terraform `instance_name`을 `TAILSCALE_HOSTNAME`으로 넘기고, 03 단계가
`tailscale up --hostname`에 적용한 뒤 이름 반영까지 기다린다. 따라서 다음 단계가 생성하는
MagicDNS·Serve·Orca pairing 주소는 처음부터 같은 안정적인 이름을 사용한다.

```bash
./install/04-orca-server.sh
```

처음 실행할 때 Tailscale Serve/HTTPS 승인이 필요하면 스크립트가 승인 URL과 함께 중단된다. 해당
URL을 관리 PC 브라우저에서 승인한 뒤 `04-orca-server.sh`를 다시 실행한다.

```bash
sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec codex login --device-auth'
sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec gh auth login'

./install/05-repos.sh
./install/06-vscode-remote.sh
./install/07-monitoring.sh
./util/verify-host.sh
sudo ./util/show-orca-access.sh
```

`05-repos.sh`는 `REPOS`에 적은 저장소를 `/home/orca/workspace` 아래에 클론하고 각각을 Orca에
등록한다. **여기 등록되는 저장소가 이 호스트의 신뢰경계다** — 에이전트는 그 코드의 README·
설정·빌드 스크립트를 읽고 명령을 실행하고, 그 명령은 `orca` 계정의 sudo 를 거쳐 호스트 전체에
닿는다. 그래서 실제 작업 대상만 명시적으로 나열하는 것을 권장한다.

`REPOS=all` 이면 `GITHUB_OWNER` 소유 저장소를 `gh` 로 열거하되 **포크와 보관됨은 기본으로
뺀다**(`gh repo list --source --no-archived`). 포크는 제3자가 쓴 코드다. 필요하면
`REPOS_INCLUDE_FORKS=1` / `REPOS_INCLUDE_ARCHIVED=1` 로 다시 넣는다. 프라이빗을 받으려면
토큰에 `repo` 스코프가 있어야 하고, 없으면 중단한다.

`gh auth login`에서 git 자격증명 연동을 건너뛴 경우를 대비해 `gh auth setup-git`을 먼저 맞추고,
클론은 `GIT_TERMINAL_PROMPT=0`으로 돌려 인증이 없으면 멈추지 않고 실패한다. 네트워크 실패는
3회까지 재시도한다. 이미 클론된 저장소는 다시 클론하지 않고 `git fetch` 만 한다 — 작업 트리는
건드리지 않는다.

`07-monitoring.sh`는 장애 알림과 보안 감사 계층을 설치한다. 자세한 내용은 6절 "감시와 알림".

Codex device URL과 GitHub device URL도 관리 PC 브라우저에서 연다. AppImage의
`account add --agent codex`는 headless 환경에서 X11 초기화 또는 Orca single-instance lock에
걸릴 수 있으므로 현행 절차에서 사용하지 않는다.

### 4.3 VS Code Remote-SSH

`06-vscode-remote.sh`는 `orca`에 `/bin/bash`와 **전용 공개키**를 주고,
`/etc/ssh/sshd_config.d/60-orca-vscode.conf`로 그 계정을 키 인증 전용으로 묶는다.

- VS Code를 `orca`로 붙이는 이유는 파일 소유권이다. `ubuntu`로 편집하면
  `/home/orca/workspace` 안에 Orca가 쓰지 못하는 파일이 섞인다.
- 드롭인은 반드시 `Match all`로 끝난다. `sshd_config`의 `Include`가 파일 맨 위에 있어
  `Match` 블록으로 끝내면 메인 설정의 나머지가 전부 그 블록 안으로 들어간다.
- 스크립트는 드롭인을 쓴 뒤 `sshd -t`로 검증하고, 실패하면 드롭인을 지우고 중단한다.
  기존 SSH 세션은 유지되므로 잠기지 않는다.
- **공개키는 `orca` 전용 키다**(`config.env` 의 `ORCA_SSH_PUBLIC_KEY`). `ubuntu` 의
  `authorized_keys` 를 복사하면 키 하나가 두 계정을 동시에 열고, `orca` 는 sudo 를 가지므로
  `ubuntu` 키 탈취 한 번이 그대로 호스트 root 와 `/srv/<앱>/.env` 까지 간다. 키를 적지 않으면
  스크립트는 진행하지 않고 중단한다. 옛 동작이 필요하면 `ORCA_SSH_REUSE_ADMIN_KEY=1` 로
  의식적으로 켠다. 스크립트와 `verify-host.sh` 모두 두 계정의 키가 겹치는지 확인한다.
- `orca`의 sudo는 `config.env`의 `ORCA_SERVICE_SUDO`로 선언한다 — `nopasswd`(기본, 그룹 +
  `NOPASSWD:ALL` 드롭인), `whitelist`(열거한 명령만 NOPASSWD), `password`(그룹만),
  `off`(그룹에서 제외). `04-orca-server.sh`가 매 실행 그 상태로 맞추고, 드롭인은 임시 파일에서
  `visudo -c`를 통과한 것만 설치한다(문법 오류 하나로 호스트의 sudo 전체가 잠기기 때문이다).
  `verify-host.sh`가 선언과 실제를 대조한다.
  이 호스트는 입주 앱과 공유하므로 sudo는 `/srv/<앱>`의 비밀까지 여는 선택이다.
- `ORCA_SUDO_LOG=on`(기본)이면 sudo I/O 로깅을 켠다. 누가 무엇을 root로 실행했는지가
  `/var/log/sudo-io` 에 남고 `sudoreplay -l` / `sudoreplay <ID>` 로 재생된다. 화이트리스트로
  좁히기 전에 실제 쓰이는 명령을 관찰하는 수단이기도 하다.
- 유닛에는 `MemoryHigh` / `MemoryMax` / `OOMPolicy=stop` 이 걸린다. 커널 OOM killer 가 호스트에서
  임의의 프로세스를 고르게 두는 대신 한도를 넘은 이 서비스만 예측 가능하게 멈추게 한다.
  `NoNewPrivileges` 와 `ProtectSystem`·`ProtectHome` 계열은 sudo 경로 자체를 막으므로
  `ORCA_SERVICE_SUDO=off` 일 때만 켜진다 — 순서를 지키지 않으면 서비스가 아니라 운영이 막힌다.
- `04-orca-server.sh`가 `config.env`(서버에서는 `host.env`)의 `ORCA_SERVICE_PASSWORD`로 계정
  비밀번호를 맞춘다. 값은 커밋하지 않으며 비어 있으면 계정을 잠긴 채 둔다. 쓰임새는
  `su - orca` 하나뿐이다. 드롭인이 이 계정의 SSH 비밀번호 인증을 끄므로 원격 로그인 경로는
  공개키뿐이며, `verify-host.sh`가 둘(비밀번호 설정됨 / SSH 비밀번호 인증 차단)을 함께
  점검한다. 호스트를 입주 앱과 공유하는 만큼 짧은 값은 `su` 경로를 여는 선택이다.
- `fs.inotify.max_user_watches`를 524288로 올린다. 기본값에서는 저장소 몇 개만 열어도
  VS Code 파일 감시가 중단된다.

접속 주소는 Tailscale MagicDNS 이름을 쓴다. 공인 IP로 붙으면 관리자 IP가 바뀔 때마다
`terraform apply`로 `/32` 규칙을 다시 반영해야 한다(`scripts/util/update-admin-ip.sh` 가
감지부터 apply 까지 한다).

### SSH 키 교체

`ubuntu` 와 `orca` 는 **서로 다른 키**를 쓴다. 한쪽만 바꾸면 다른 쪽이 옛 키로 열린 채 남으므로
둘을 구분해 교체한다.

**`orca` 키 (VS Code Remote-SSH)** — 이 저장소가 선언적으로 관리한다.

```bash
# 관리 PC
ssh-keygen -t ed25519 -f ~/.ssh/orca_vscode_new -C "vscode->orca"
# scripts/config.env: ORCA_SSH_PUBLIC_KEY=~/.ssh/orca_vscode_new.pub
./scripts/util/sync-host.sh

# 서버 (ubuntu)
./install/06-vscode-remote.sh        # 새 키를 추가한다 (기존 키는 남는다)
```

새 키로 접속되는 것을 확인한 뒤 옛 키 줄을 지운다. 스크립트는 멱등하게 **더하기만** 하므로
삭제는 사람이 한다.

```bash
sudo -u orca sed -i '/<옛 키의 comment 또는 본문 일부>/d' /home/orca/.ssh/authorized_keys
./install/06-vscode-remote.sh        # 기준 해시를 다시 기록한다
./util/verify-host.sh                # authorized_keys 드리프트 검사 통과 확인
```

**`ubuntu` 키 (Lightsail 키페어)** — Terraform 이 만든 키페어다. 새 공개키로
`ssh_public_key_path` 를 바꾸면 키페어 리소스가 교체되며 인스턴스 재생성이 따라올 수 있으므로,
운영 중인 호스트에서는 `authorized_keys` 를 직접 갱신하고 다음 재구축 때 tfvars 를 맞춘다.

```bash
# 기존 세션을 열어 둔 채로 (잠기면 복구 경로가 없다)
ssh-copy-id -i ~/.ssh/new_admin.pub ubuntu@<static_ip>
ssh -i ~/.ssh/new_admin ubuntu@<static_ip> true     # 새 키 확인
ssh ubuntu@<static_ip> "sed -i '/<옛 키>/d' ~/.ssh/authorized_keys"
```

교체 후 `verify-host.sh` 의 "두 계정 authorized_keys 가 겹치지 않음" 항목을 다시 본다.

## 5. 브라우저 접속

관리 PC PowerShell에서 긴 URL을 줄바꿈 없이 클립보드로 받을 수 있다.

```powershell
$serverIp = terraform -chdir=terraform output -raw static_ip
ssh "ubuntu@$serverIp" "sudo ~/remote-lightsail-scripts/util/show-orca-access.sh --url-only" | Set-Clipboard
```

정상 URL은 다음 형태다.

```text
https://<server>.<tailnet>.ts.net/web-index.html#pairing=...
```

- `https://`와 `#pairing=`이 모두 있어야 한다.
- pairing fragment는 런타임 접근 권한이므로 비밀번호처럼 취급한다.
- 채팅, 이슈, 화면 공유, 셸 히스토리 파일에 남기지 않는다.
- 공용 브라우저나 매번 저장소가 사라지는 시크릿 모드를 일상 클라이언트로 쓰지 않는다.
- 서버가 새 pairing URL을 발급한 경우 이전 주소 대신 최신 주소를 사용한다.

### 페어링 URL 보관

URL 은 런타임 접근 capability 다. "비밀번호처럼 취급"은 보관 위치가 정해져 있을 때만 지켜진다.

- **보관 위치는 비밀번호 관리자 하나로 고정한다.** 1Password / Bitwarden 에 Secure Note 로
  넣고 항목 이름은 `orca-host-tokyo pairing URL` 처럼 호스트 이름을 쓴다. 클립보드, 채팅,
  스크린샷, 셸 히스토리 파일에는 남기지 않는다.
- 필요할 때마다 다시 꺼내는 편이 안전하다. 서버에서 한 줄로 얻는다:

  ```powershell
  $serverIp = terraform -chdir=terraform output -raw static_ip
  ssh "ubuntu@$serverIp" "sudo ~/remote-lightsail-scripts/util/show-orca-access.sh --url-only" | Set-Clipboard
  ```

- **재발급**은 서비스 재시작이다. 유출이 의심되면 즉시 돌린다 — 이전 URL 은 무효가 된다.

  ```bash
  sudo systemctl restart orca-serve
  sleep 10
  sudo ./util/show-orca-access.sh
  ```

- 브라우저 캐시/사이트 데이터를 지우면 저장된 클라이언트 자격증명도 함께 사라진다.
  그때는 위 절차로 URL 을 다시 받아 페어링한다. 시크릿 모드를 일상 클라이언트로 쓰지 않는
  이유도 같다.

## 6. 검증과 일상 운영

### 서버 전체 점검

```bash
cd ~/remote-lightsail-scripts
./util/verify-host.sh
sudo ./util/diagnose-web-client.sh
```

`verify-host.sh`의 통과 기준은 다음과 같다.

- Orca가 active/enabled이고 HTTPS/WSS 준비 이벤트가 존재한다.
- Web Client HTML이 localhost에서 응답한다.
- Tailscale과 Tailscale Serve HTTPS 프록시가 active다.
- UFW가 active다.
- Codex, Claude Code, GitHub CLI가 설치되어 있다.
- `orca` 계정의 Codex 인증이 유효하고, GitHub 토큰은 **실제 API 호출**(`gh api user`)로 확인한다
  — 존재 확인이 아니라 유효성 확인이다.
- `/swapfile`이 활성화되어 있다.
- `orca` 와 `ubuntu` 의 `authorized_keys` 가 **겹치지 않는다**.
- Orca 바이너리의 SHA256 이 `/opt/orca/CHECKSUM` 과 같다.
- sudoers 드롭인·`orca-serve` 유닛·`authorized_keys` 가 설치 시점 해시와 같다(드리프트 검사).
- `orca-serve` 유닛에 `MemoryMax` 가 걸려 있다.
- sudo I/O 로깅이 켜져 있고(`ORCA_SUDO_LOG=on`), `auditd` 가 돌고 있다.
- 감시 타이머(`orca-watch`, `orca-resource-watch`, `orca-token-check`, `orca-verify`)가 active다.

드리프트 검사의 기준값은 `/var/lib/orca-host/baseline/` 에 있고 `04-orca-server.sh` 와
`06-vscode-remote.sh` 가 기록한다. 의도한 변경 뒤에는 해당 스크립트를 다시 돌려 기준을
갱신한다 — 그러지 않으면 검사가 계속 실패한다.

### 감시와 알림

`07-monitoring.sh` 가 설치한다. 알림은 모두 `/usr/local/sbin/orca-notify` 한 곳을 지나며,
`ALERT_WEBHOOK` 이 있으면 POST 하고 없으면 `/var/log/orca-alert.log` 에만 남는다.

| 감시 | 주기 | 조건 |
|---|---|---|
| `orca-serve` 상태 | 5분 | 비활성이면 알림 (상태가 바뀔 때만 — 5분마다 반복하지 않는다) |
| systemd `OnFailure` | 즉시 | 재시작 한도(5회/5분) 소진으로 `failed` 진입 |
| 디스크 | 1시간 | 루트 `DISK_WARN_PERCENT`(기본 80%) 초과 — 상위 용량 디렉터리를 함께 보낸다 |
| 스왑 | 1시간 | `SWAP_WARN_PERCENT`(기본 70%) 초과 |
| OOM kill | 1시간 | 커널 로그에 `killed process` / `out of memory` |
| 자격증명 | 주 1회 | `gh api user` / `codex login status` 실패 |
| Orca 새 버전 | 주 1회 | 설치 버전 ≠ 최신 릴리스 |
| 전체 점검 | 일 1회 | `verify-host.sh` 실패 항목 |

같은 조건의 알림은 6시간 동안 다시 보내지 않는다. 보안 이벤트는 별도 경로로도 남는다 —
`auditd` 가 `/etc/sudoers.d/`, 두 계정의 `authorized_keys`, Orca 바이너리, `/etc/systemd/system/`,
`/etc/ssh/sshd_config.d/` 변경을 기록하고(`ausearch -k orca_privesc`), PAM 훅이 SSH 로그인
성공을 알린다. 저널은 `SystemMaxUse=500M` 로 묶여 있다(`JOURNAL_MAX_USE`).

```bash
systemctl list-timers 'orca-*' --no-pager
sudo /usr/local/sbin/orca-notify info "테스트 알림"
tail -20 /var/log/orca-alert.log
sudo sudoreplay -l
sudo ausearch -k orca_privesc
```

### 일상 명령

```bash
sudo systemctl status orca-serve --no-pager
sudo journalctl -u orca-serve -f
sudo tailscale serve status
sudo ./util/show-orca-access.sh
free -h
df -h /home /opt/orca

systemctl list-timers 'orca-*' --no-pager   # 감시 타이머
tail -20 /var/log/orca-alert.log            # 알림 내역
sudo sudoreplay -l                          # root 로 실행한 내역
sudo ausearch -k orca_privesc               # sudoers/키 변경 시도
./util/check-orca-update.sh                 # 새 버전 확인
sudo ./util/backup-orca.sh                  # 프로필 백업
```

4GB는 동시 에이전트 하나의 시작점이다. 병렬 에이전트, 큰 빌드, 여러 내장 브라우저 탭을 자주
사용하면 `large_3_0`(8GB) 이상으로 전환한다.

## 7. 업그레이드와 백업

헤드리스 `orca serve`는 이 구성에서 자동으로 버전을 올리지 않는다. 새 버전이 나왔는지는
`util/check-orca-update.sh`(주 1회 타이머로도 돈다)가 알려 준다.

1. Lightsail 수동 스냅샷을 만든다 — 이름은 `orca-host-YYYYMMDD-preupgrade`.
2. `sudo ./util/backup-orca.sh` 로 Orca 프로필을 백업한다.
3. `scripts/config.env`의 `ORCA_VERSION`을 변경하고 `ORCA_SHA256`은 비운다.
4. `util/sync-host.sh`로 서버 스크립트를 갱신한다.
5. `04-orca-server.sh`를 재실행한다. 새 바이너리의 SHA256을 출력하므로 `config.env`의
   `ORCA_SHA256`에 옮겨 적는다 — 다음 설치부터 그 값으로 검증한다.
6. `verify-host.sh`, HTTPS 브라우저 렌더링, 기존 프로젝트 재연결을 확인한다.

다운그레이드는 바이너리만 되돌리지 않는다. 상태 스키마가 바뀔 수 있으므로 같은 시점의 Orca
프로필 백업을 함께 복구한다.

### 오프사이트 백업

Lightsail 자동 스냅샷은 7일치만 남고, 리전 장애나 계정 문제에서는 스냅샷 자체에 접근하지
못한다. `util/backup-orca.sh` 가 Orca 프로필을 아카이브하고 `BACKUP_S3_URI` 가 있으면
암호화해 업로드한다.

```bash
sudo ./util/backup-orca.sh --dry-run   # 무엇이 담기는지 먼저 본다
sudo ./util/backup-orca.sh
```

담는 것은 `/home/orca/.config/orca` 와 `/home/orca/.config/Orca` 다. `workspace` 는 담지 않는다 —
git remote 가 이미 사본이고, 커밋되지 않은 변경이 있는 저장소는 목록으로만 남긴다(그건 백업이
아니라 push 로 지킨다).

**자격증명은 기본적으로 담지 않는다.** `/home/orca/.codex` 와 gh 토큰을 S3 로 복사하면
자격증명의 사본이 하나 더 생기고, 그 버킷이 새로운 침해 대상이 된다. 복구 가능성을 얻는 대신
공격면을 사는 거래다. 담기로 했다면 `BACKUP_INCLUDE_CREDENTIALS=1` 과 함께 통제를 같이 건다.

- SSE-KMS 고객 관리 키(`BACKUP_KMS_KEY_ID`). 키 정책에서 복호화 주체를 관리자 principal 로 한정
- 버킷 정책에서 인스턴스에는 `PutObject` 만 허용하고 `GetObject` 는 제외 (쓰되 읽지 못하게)
- 버저닝 + Object Lock (랜섬웨어 대비)

**대안이 더 단순할 수 있다.** 자격증명은 백업하지 않고 재발급한다 — `codex login --device-auth`
와 `gh auth login` 은 몇 분이면 끝난다. 복구 시간과 노출면을 저울질해 정한다.

주 1회 자동 실행이 필요하면 타이머를 둔다.

```bash
sudo systemd-run --on-calendar=weekly --unit=orca-backup \
    /home/ubuntu/remote-lightsail-scripts/util/backup-orca.sh
```

## 8. 장애 복구

```bash
sudo systemctl status orca-serve --no-pager
sudo journalctl -u orca-serve -n 200 --no-pager
sudo tailscale serve status
tailscale status
tailscale ip -4
free -h
df -h
```

| 증상 | 확인·조치 |
|---|---|
| 공인 SSH 타임아웃 | 관리자 공인 IP가 바뀌었는지 확인하고 `terraform apply`로 SSH `/32` 갱신 |
| Tailscale 인증 URL 출력 | 관리 PC 브라우저에서 로그인 후 원래 스크립트 재실행 |
| Tailscale Serve 승인 URL 출력 | 관리 PC 브라우저에서 HTTPS 기능 승인 후 `04-orca-server.sh` 재실행 |
| 브라우저가 완전히 빈 화면 | URL이 `https://...ts.net`인지 확인; `http://100.x:6768` 금지; `diagnose-web-client.sh` 실행 |
| `orca_server_ready` 없음 | AppImage/FUSE/Electron 의존성과 현재 서비스 로그 확인 |
| Codex 실행 실패 | `sudo -u orca -H env -C /home/orca codex login status`; 필요 시 `codex login --device-auth` |
| Git 작업 실패 | `sudo -u orca -H env -C /home/orca gh auth status`와 저장소 소유권 확인 |
| exit 3/single-instance | 별도 `orca` 사용자 프로세스를 확인하고 서비스 외 프로세스만 종료한 뒤 서비스 재시작 |
| OOM 또는 swap 지속 증가 | 작업 동시성을 낮추고 스냅샷 후 8GB 이상 번들로 검증 전환 |
| `orca-serve` 가 `MemoryMax` 로 멈춤 | `journalctl -u orca-serve` 에서 memory 확인; `ORCA_MEMORY_MAX` 상향 또는 번들 업그레이드 |
| SHA256 불일치로 설치 중단 | 릴리스 자산이 실제로 바뀌었는지 확인. 의도한 재빌드면 `sudo rm /opt/orca/CHECKSUM` 후 재실행 |
| 드리프트 검사 실패 | 의도한 변경이면 `04`/`06` 재실행으로 기준 갱신; 아니면 `ausearch -k orca_privesc` 로 누가 바꿨는지 본다 |
| 알림이 오지 않음 | `sudo /usr/local/sbin/orca-notify info 테스트`; `/etc/orca/alert.env` 와 `systemctl list-timers 'orca-*'` 확인 |

D-Bus `NameHasOwner` 경고는 headless Electron에서 발생할 수 있다. 서비스가 active이고 준비 이벤트,
HTML/JS 응답과 HTTPS 렌더링이 정상이라면 그 경고만으로 장애로 판정하지 않는다.

### 8.1 복구 체크리스트

서비스 복구는 다음 순서를 따른다. 상세는 `docs/stability-plan.md` 10절에 있다.

**`orca-serve` 장애**

```bash
sudo systemctl status orca-serve --no-pager
sudo journalctl -u orca-serve -n 100 --no-pager
sudo systemctl restart orca-serve
sleep 10
sudo journalctl -u orca-serve -n 30 --no-pager | grep orca_server_ready
sudo tailscale serve status
./util/verify-host.sh
sudo ./util/diagnose-web-client.sh
```

**인스턴스 복구 (스냅샷에서 재생성)**

1. Lightsail 콘솔에서 사용할 스냅샷을 고른다(자동은 7일치, 수동은 `-manual` 접미사)
2. 같은 번들로 새 인스턴스를 만든다
3. 고정 IP를 새 인스턴스에 재연결한다 (기존 IP 재사용 가능)
4. `ssh ubuntu@<static_ip>` 로 접속을 확인한다 — 같은 IP 면 `ssh-keygen -R <ip>` 가 필요할 수 있다
5. `tailscale status` 로 재인증 필요 여부를 확인한다 (필요하면 `sudo tailscale up` 후 브라우저 승인)
6. `orca-serve.service` 상태를 확인한다
7. `./util/verify-host.sh` 를 돌린다
8. Codex/GitHub 자격증명 유효성을 확인한다 (백업에 담지 않았다면 재로그인)
9. 페어링 URL 을 재발급한다: `sudo ./util/show-orca-access.sh`

**OOM 반복**

```bash
sudo dmesg | grep -i 'killed process'
sudo journalctl -k | grep -i oom
# 즉시: 동시 에이전트 세션 수 축소
# 근본: 스냅샷 → terraform.tfvars 의 bundle_id 를 large_3_0 으로 → apply → 고정 IP 재연결
```

### 8.2 복구 드릴 (분기 1회)

**절차서는 실행해 보기 전까지 검증된 것이 아니다.** 실제 장애에서 처음 복구를 시도하면
예상치 못한 단계에서 막힌다. 분기마다 한 번, 테스트 인스턴스로 다음을 확인한다.

1. 최신 스냅샷으로 **새 인스턴스**를 만든다 (운영 인스턴스는 건드리지 않는다)
2. 임시 고정 IP 를 붙이고 `ssh ubuntu@<ip>` 로 접속되는지 본다
3. `tailscale status` — 스냅샷 복원 후 재인증이 필요한지 기록한다
4. `./util/verify-host.sh` 를 돌리고 **실패 항목을 그대로 적어 둔다**
5. 페어링 URL 재발급 → 브라우저에서 실제로 렌더링되는지 본다
6. 끝나면 테스트 인스턴스와 임시 고정 IP 를 삭제한다 (고정 IP 는 미연결 상태로 두면 과금된다)

4번에서 나온 실패 항목이 곧 복구 절차의 빈틈이다. 이 문서의 8.1 에 반영한 뒤 드릴을 닫는다.
드릴 결과(일자, 실패 항목, 반영 여부)는 커밋 메시지나 이슈로 남긴다.

## 9. 폐기

다음 순서를 모두 완료한 뒤에만 폐기한다.

1. 필요한 저장소 변경 push 및 작업 데이터 백업
2. Orca/Codex/GitHub 자격증명 revoke
3. 알림 웹훅 revoke (`ALERT_WEBHOOK`) 및 백업 버킷 정리 (`BACKUP_S3_URI` — 자격증명 사본이
   남아 있을 수 있다)
4. Tailscale 장치와 Serve 설정 제거
5. Lightsail 최종 스냅샷 확인 — 수동 스냅샷은 지울 때까지 과금된다
6. Terraform destroy (remote backend 를 쓴다면 state 버킷도 함께 정리)

```powershell
terraform -chdir=terraform destroy
```

## 참고

- [Orca Headless Linux Server](https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md)
- [Orca Remote Servers](https://www.onorca.dev/docs/remote-servers)
- [OpenAI Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
- [Amazon Lightsail instance bundles](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-bundles.html)

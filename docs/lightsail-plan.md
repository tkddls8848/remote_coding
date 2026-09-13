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
├─ terraform/             # 인스턴스, 고정 IP, 키페어, 공인 SSH 방화벽
├─ scripts/
│  ├─ config.example.env  # Orca 버전과 클론 대상 예시
│  ├─ install/            # 서버 설치 01~06
│  └─ util/               # 프로비저닝, 동기화, URL 조회, 진단, 검증
└─ docs/                  # 운영 기준과 별도 통합 계획
```

- Terraform은 Lightsail 자원만 관리한다.
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
./install/03-private-network.sh
sudo tailscale up
```

`tailscale up`이 출력한 URL은 원격 서버 안의 브라우저가 아니라 관리 PC 브라우저에서 연다. 관리
PC도 같은 tailnet에 로그인해야 한다.

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
./util/verify-host.sh
sudo ./util/show-orca-access.sh
```

Codex device URL과 GitHub device URL도 관리 PC 브라우저에서 연다. AppImage의
`account add --agent codex`는 headless 환경에서 X11 초기화 또는 Orca single-instance lock에
걸릴 수 있으므로 현행 절차에서 사용하지 않는다.

### 4.3 VS Code Remote-SSH

`06-vscode-remote.sh`는 `orca`에 `/bin/bash`와 `ubuntu`의 `authorized_keys`를 주고,
`/etc/ssh/sshd_config.d/60-orca-vscode.conf`로 그 계정을 키 인증 전용으로 묶는다.

- VS Code를 `orca`로 붙이는 이유는 파일 소유권이다. `ubuntu`로 편집하면
  `/home/orca/workspace` 안에 Orca가 쓰지 못하는 파일이 섞인다.
- 드롭인은 반드시 `Match all`로 끝난다. `sshd_config`의 `Include`가 파일 맨 위에 있어
  `Match` 블록으로 끝내면 메인 설정의 나머지가 전부 그 블록 안으로 들어간다.
- 스크립트는 드롭인을 쓴 뒤 `sshd -t`로 검증하고, 실패하면 드롭인을 지우고 중단한다.
  기존 SSH 세션은 유지되므로 잠기지 않는다.
- `orca`는 sudo 그룹에 넣지 않는다. 스크립트가 확인하고 들어 있으면 경고한다.
- `fs.inotify.max_user_watches`를 524288로 올린다. 기본값에서는 저장소 몇 개만 열어도
  VS Code 파일 감시가 중단된다.

접속 주소는 Tailscale MagicDNS 이름을 쓴다. 공인 IP로 붙으면 관리자 IP가 바뀔 때마다
`terraform apply`로 `/32` 규칙을 다시 반영해야 한다.

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
- `orca` 계정의 Codex와 GitHub 인증이 유효하다.
- `/swapfile`이 활성화되어 있다.

### 일상 명령

```bash
sudo systemctl status orca-serve --no-pager
sudo journalctl -u orca-serve -f
sudo tailscale serve status
sudo ./util/show-orca-access.sh
free -h
df -h /home /opt/orca
```

4GB는 동시 에이전트 하나의 시작점이다. 병렬 에이전트, 큰 빌드, 여러 내장 브라우저 탭을 자주
사용하면 `large_3_0`(8GB) 이상으로 전환한다.

## 7. 업그레이드와 백업

헤드리스 `orca serve`는 이 구성에서 자동으로 버전을 올리지 않는다.

1. Lightsail 스냅샷을 만든다.
2. `/home/orca/.config/orca`, `/home/orca/.config/Orca`, `/home/orca/.codex`,
   `/home/orca/workspace`를 백업한다.
3. `scripts/config.env`의 `ORCA_VERSION`을 변경한다.
4. `util/sync-host.sh`로 서버 스크립트를 갱신한다.
5. `04-orca-server.sh`를 재실행한다.
6. `verify-host.sh`, HTTPS 브라우저 렌더링, 기존 프로젝트 재연결을 확인한다.

다운그레이드는 바이너리만 되돌리지 않는다. 상태 스키마가 바뀔 수 있으므로 같은 시점의 Orca
프로필 백업을 함께 복구한다.

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

D-Bus `NameHasOwner` 경고는 headless Electron에서 발생할 수 있다. 서비스가 active이고 준비 이벤트,
HTML/JS 응답과 HTTPS 렌더링이 정상이라면 그 경고만으로 장애로 판정하지 않는다.

## 9. 폐기

다음 순서를 모두 완료한 뒤에만 폐기한다.

1. 필요한 저장소 변경 push 및 작업 데이터 백업
2. Orca/Codex/GitHub 자격증명 revoke
3. Tailscale 장치와 Serve 설정 제거
4. Lightsail 최종 스냅샷 확인
5. Terraform destroy

```powershell
terraform -chdir=terraform destroy
```

## 참고

- [Orca Headless Linux Server](https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md)
- [Orca Remote Servers](https://www.onorca.dev/docs/remote-servers)
- [OpenAI Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Tailscale Serve](https://tailscale.com/docs/features/tailscale-serve)
- [Amazon Lightsail instance bundles](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-bundles.html)

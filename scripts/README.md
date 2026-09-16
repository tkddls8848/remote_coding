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
./util/verify-host.sh
sudo ./util/show-orca-access.sh
```

- `01-host-base.sh`: 타임존(`HOST_TIMEZONE`, 기본 UTC), Node.js 22, 빌드 도구, Xvfb, AppImage 의존성, 4GB swap
- `02-agent-cli.sh`: Codex CLI와 Claude Code 전역 설치
- `03-private-network.sh`: Tailscale 공식 APT 저장소, 안정적인 MagicDNS 이름, 최초 브라우저 인증
- `04-orca-server.sh`: 고정 버전 AppImage, `orca` 전용 계정, `orca-serve.service`, Tailscale Serve HTTPS.
  계정 비밀번호는 `config.env`의 `ORCA_SERVICE_PASSWORD`로 매 실행 맞추고, 비어 있으면 계정을
  잠긴 채 둔다. `su - orca` 전용이고 SSH는 06 단계가 이 계정의 비밀번호 인증을 끄므로 원격
  로그인은 키로만 한다.
- `05-repos.sh`: `/home/orca/workspace`에 Orca 계정으로 저장소 클론.
  `REPOS=all`(기본)이면 `GITHUB_OWNER`의 저장소를 `gh`로 열거해 **전부** 가져온다 —
  GitHub 프로필의 Repositories 탭과 같은 범위로 프라이빗·포크·보관됨을 모두 포함한다.
  토큰에 `repo` 스코프가 필요하며 없으면 중단한다. 일부만 원하면 `REPOS`에 이름을 공백으로
  나열하고, 전체에서 몇 개만 빼려면 `REPOS_EXCLUDE`를 쓴다. 새 저장소를 만든 뒤 다시 돌리면
  그것만 추가된다.
- `06-vscode-remote.sh`: `orca` 계정 SSH 로그인(키 전용), sshd 드롭인, inotify 한도 — VS Code Remote-SSH

`config.env`는 로컬 전용이며 `sync-host.sh`가 필요한 값만 서버의 `host.env`(`0600`)로
복사한다. Tailscale·Codex·GitHub 토큰은 이 파일에 넣지 않는다. 여기 들어가는 유일한
자격증명은 `ORCA_SERVICE_PASSWORD`이며, 예시 파일에는 값을 두지 않는다 — 원격 로그인이
아니라 호스트 안 `su` 전용이다.

`HOST_TIMEZONE`은 입주 앱과의 계약 값이다. 입주 앱의 `cron.d`는 타임존을 선언할 수 없어
호스트 설정을 그대로 따르고, Lightsail 자동 스냅샷 시각은 UTC 정시다. 두 시각을 같은
기준으로 읽기 위해 UTC로 고정하며, 바꾸면 입주 앱 저장소의 백업 시각도 함께 옮긴다.
`verify-host.sh`가 이 값을 확인한다.

`TAILSCALE_HOSTNAME`을 비우면 `sync-host.sh`가 Terraform의 `instance_name`을 사용한다.
최초 설치부터 같은 MagicDNS 이름을 유지하려면 특별한 이유가 없는 한 비워 둔다.

## 로컬 유틸리티

`util/provision-host.sh`는 Terraform apply, SSH 대기, 스크립트 동기화를 수행한다. 실제 계정
로그인은 사람의 브라우저 승인이 필요하므로 서버에서 마무리한다.

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

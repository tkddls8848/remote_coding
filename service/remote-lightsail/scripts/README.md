# scripts/

Lightsail 호스트를 Tailscale 전용 Orca 서버로 만드는 멱등형 설치 스크립트 모음이다.

## 실행 순서

```bash
./install/01-host-base.sh
./install/02-agent-cli.sh
./install/03-private-network.sh
sudo tailscale up
./install/04-orca-server.sh

sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec codex login --device-auth'
sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec gh auth login'

./install/05-repos.sh
./util/verify-host.sh
sudo ./util/show-orca-access.sh
```

- `01-host-base.sh`: Node.js 22, 빌드 도구, Xvfb, AppImage 의존성, 4GB swap
- `02-agent-cli.sh`: Codex CLI와 Claude Code 전역 설치
- `03-private-network.sh`: Tailscale 공식 APT 저장소와 데몬
- `04-orca-server.sh`: 고정 버전 AppImage, `orca` 전용 계정, `orca-serve.service`, Tailscale Serve HTTPS
- `05-repos.sh`: `/home/orca/workspace`에 Orca 계정으로 저장소 클론

`config.env`는 로컬 전용이며 `sync-host.sh`가 필요한 비밀 아닌 값만 서버의 `host.env`로
복사한다. Tailscale·Codex·GitHub 토큰은 이 파일에 넣지 않는다.

## 로컬 유틸리티

`util/provision-host.sh`는 Terraform apply, SSH 대기, 스크립트 동기화를 수행한다. 실제 계정
로그인은 사람의 브라우저 승인이 필요하므로 서버에서 마무리한다.

```powershell
& "C:\Program Files\Git\bin\bash.exe" ./service/remote-lightsail/scripts/util/provision-host.sh
```

`util/show-orca-access.sh`는 systemd 저널의 최신 `orca_server_ready` JSON에서
`pairing.webClientUrl`만 출력한다. 출력 URL은 접근 권한 자체이므로 터미널 로그나 이슈에 붙이지
않는다.

긴 URL이 터미널에서 잘리는 것을 피하려면 관리 PC PowerShell에서 URL만 클립보드로 복사한다.

```powershell
ssh ubuntu@43.202.14.119 "sudo ~/remote-lightsail-scripts/util/show-orca-access.sh --url-only" | Set-Clipboard
```

Web Client가 빈 화면이면 서버에서 `sudo ./util/diagnose-web-client.sh`를 실행한다. 이 진단은
페어링 URL을 출력하지 않고 HTML·JavaScript 번들·Tailscale 주소만 확인한다.

Orca Web은 브라우저의 보안 컨텍스트가 필요하므로 최종 URL은 반드시
`https://<호스트>.<tailnet>.ts.net/web-index.html#pairing=...` 형태여야 한다. Tailscale IP의
`http://100.x.x.x:6768/...` 주소는 HTML이 열려도 Web Crypto 초기화가 중단되어 빈 화면이 된다.

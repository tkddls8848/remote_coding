# remote-lightsail

AWS Lightsail에 Orca를 24시간 실행하고, 관리 PC의 **웹 브라우저**에서 코딩 에이전트와
워크트리·터미널·파일을 제어하는 개인용 원격 개발 시스템이다.

```text
관리 PC 브라우저
  └─ Tailscale 사설망 ──> Lightsail (Ubuntu 24.04, 4GB+)
                           ├─ orca-serve.service
                           ├─ Codex / Claude Code
                           └─ /home/orca/workspace/*

관리 PC SSH ── 공인 IP /32 ──> 설치·복구용 ubuntu 계정
```

공개 인터넷에는 SSH 22만 현재 관리자 IP `/32`로 연다. Orca의 TCP 6768은 Lightsail
공인 방화벽에 열지 않으며, 같은 Tailscale tailnet의 브라우저만 접근한다. Orca Remote
Server/Web Client는 Beta이므로 서버를 공개 인터넷에 직접 노출하지 않는다.

## 빠른 시작

Windows PowerShell에서 설정 예시를 복사한 뒤 값을 확인한다.

```powershell
Copy-Item service\remote-lightsail\terraform\terraform.tfvars.example service\remote-lightsail\terraform\terraform.tfvars
Copy-Item service\remote-lightsail\scripts\config.example.env service\remote-lightsail\scripts\config.env

& "C:\Program Files\Git\bin\bash.exe" ./service/remote-lightsail/scripts/util/provision-host.sh
```

그 다음 출력된 SSH 주소로 접속해 실행한다.

```bash
cd ~/remote-lightsail-scripts
./install/01-host-base.sh
./install/02-agent-cli.sh
./install/03-private-network.sh
sudo tailscale up

# 출력된 URL로 Tailscale 인증을 끝낸 뒤
./install/04-orca-server.sh

# 자격증명은 반드시 Orca 서비스 계정에 등록한다. headless 서버는 device code를 쓴다.
sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec codex login --device-auth'
sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec gh auth login'

./install/05-repos.sh
./util/verify-host.sh
sudo ./util/show-orca-access.sh
```

마지막 명령이 출력한 URL을 같은 tailnet에 연결된 관리 PC의 브라우저에서 연다. URL에는
접근 capability가 포함되므로 비밀번호처럼 취급한다. 최초 페어링 뒤 브라우저는 발급된
클라이언트 자격증명을 보관하며, 서버 재부팅 후에도 다시 연결된다.

## 구성

| 위치 | 역할 |
|---|---|
| [`terraform/`](terraform/) | 4GB Lightsail, 고정 IP, 키페어, SSH 전용 공인 방화벽 |
| [`scripts/install/`](scripts/install/) | 호스트, Tailscale, 에이전트 CLI, Orca systemd, 저장소 설치 |
| [`scripts/util/`](scripts/util/) | 생성·동기화·접근 URL 조회·검증 |
| [`docs/lightsail-plan.md`](docs/lightsail-plan.md) | 상세 구축, 운영, 백업, 복구 절차 |

기본 `medium_3_0`은 Orca와 에이전트 하나를 위한 시작점이다. 병렬 에이전트, 큰 빌드,
여러 내장 브라우저 탭을 자주 쓰면 `large_3_0`(8GB) 이상을 권장한다.

## 일상 운영

```bash
sudo systemctl status orca-serve --no-pager
sudo journalctl -u orca-serve -f
sudo ./util/show-orca-access.sh
free -h
```

Orca 버전은 `scripts/config.env`의 `ORCA_VERSION`으로 고정한다. 버전을 바꾼 뒤
`04-orca-server.sh`를 다시 실행하면 바이너리를 교체하고 서비스를 재시작한다. 운영 데이터와
페어링 키는 `/home/orca/.config/orca` 및 `/home/orca/.config/Orca`에 있으므로 스냅샷/백업에
반드시 포함한다.

비밀정보(`config.env`, Terraform state/tfvars, Codex·GitHub 자격증명, 브라우저 페어링 URL)는
Git에 커밋하지 않는다.

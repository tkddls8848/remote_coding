# remote_coding

AWS Lightsail에 Orca를 24시간 실행하고, 관리 PC의 **웹 브라우저**에서 코딩 에이전트와
워크트리·터미널·파일을 제어하는 개인용 원격 개발 시스템이다.

```text
관리 PC 브라우저
  └─ Tailscale 사설망 ──> Lightsail (Ubuntu 24.04, 4GB+)
                           ├─ orca-serve.service
                           ├─ Codex / Claude Code
                           ├─ /home/orca/workspace/*
                           └─ (입주 앱: 자기 계정 / 자기 저장소가 소유)

관리 PC VS Code ─ Tailscale SSH ──> orca 계정 (같은 workspace 편집)

관리 PC SSH ── 공인 IP /32 ──> 설치·복구용 ubuntu 계정
```

기본 공인 방화벽은 SSH 22만 현재 관리자 IP `/32`로 연다. Orca의 TCP 6768은 Lightsail
공인 방화벽에 열지 않으며, 같은 Tailscale tailnet의 브라우저만 접근한다. Orca Remote
Server/Web Client는 Beta이므로 서버를 공개 인터넷에 직접 노출하지 않는다.

**이 호스트는 인프라 비용 때문에 다른 프로젝트와 공유한다.** 입주 앱은 각자 전용 계정과
`/srv/<앱>` 아래에서 돌고, 설치·유닛·점검·운영 문서는 **그 앱의 저장소가 소유한다.**
이 저장소는 인스턴스·고정 IP·공인 방화벽·스냅샷·Orca·Tailscale·OS 계정까지만 책임진다.

경계에서 만나는 지점은 둘뿐이다. 공개 웹이 필요한 입주 앱이 있으면 `enable_public_web=true`로
80/443을 열고(앱 내부 포트는 열지 않는다), 앱의 영속 데이터는 일일 자동 스냅샷이 함께 담는다.
현재 입주 앱은 `stock_chatbot` 하나이며 그 운영 기준은 해당 저장소의 `infra/`에 있다.

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
./install/03-private-network.sh
sudo tailscale up

# 출력된 URL로 Tailscale 인증을 끝낸 뒤
./install/04-orca-server.sh

# 자격증명은 반드시 Orca 서비스 계정에 등록한다. headless 서버는 device code를 쓴다.
sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec codex login --device-auth'
sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec gh auth login'

./install/05-repos.sh
./install/06-vscode-remote.sh
./util/verify-host.sh
sudo ./util/show-orca-access.sh
```

마지막 명령이 출력한 URL을 같은 tailnet에 연결된 관리 PC의 브라우저에서 연다. URL에는
접근 capability가 포함되므로 비밀번호처럼 취급한다. 최초 페어링 뒤 브라우저는 발급된
클라이언트 자격증명을 보관하며, 서버 재부팅 후에도 다시 연결된다.

## VS Code Remote-SSH

`06-vscode-remote.sh`는 `orca` 계정에 로그인 셸과 관리 PC 공개키를 부여해 VS Code가
에이전트와 **같은 계정**으로 붙게 한다. `ubuntu`로 붙어 `/home/orca/workspace`를 편집하면
새 파일 소유자가 갈라져 Orca가 쓰지 못하는 경로가 생기기 때문이다. `orca`는 sudo 그룹에
넣지 않고 비밀번호 인증도 막는다.

관리 PC의 `~/.ssh/config`:

```sshconfig
Host orca
    HostName <호스트>.<tailnet>.ts.net
    User orca
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 30
    ServerAliveCountMax 6
```

`Remote-SSH: Connect to Host...` → `orca` → `/home/orca/workspace`를 연다. 스크립트가
출력하는 MagicDNS 이름을 쓰면 관리자 공인 IP가 바뀌어도 `terraform apply`로 `/32` 규칙을
갱신할 필요가 없다.

브라우저 Orca와 VS Code를 동시에 켜면 4GB에서는 여유가 거의 없다. 원격 언어 서버나 인덱서
확장을 상시 켤 계획이면 `large_3_0`(8GB) 이상으로 올린다.

## 구성

| 위치 | 역할 |
|---|---|
| [`terraform/`](terraform/) | 4GB Lightsail, 고정 IP, 키페어, 자동 스냅샷, 공인 방화벽 |
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

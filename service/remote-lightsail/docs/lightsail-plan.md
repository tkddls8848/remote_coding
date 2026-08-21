# Lightsail CLI 개발 + stock_chatbot 호스트 구축 및 운영

> 기준일: 2026-08-22
> 상태: Terraform과 호스트 설정 스크립트는 준비되어 있다. 실제 AWS 자원 상태는
> `terraform -chdir=service/remote-lightsail/terraform plan`과 Lightsail 콘솔에서 확인한다.

## 1. 목표와 구성

한 대의 서울 리전 Lightsail `small_3_0`(2GB RAM, 2 vCPU, Ubuntu 24.04)에서 다음을 실행한다.

- `stock-chatbot.service`: 24시간 운영 봇
- Claude Code 또는 Codex CLI: 한 번에 하나의 개발 에이전트
- `tmux`: SSH 연결이 끊겨도 개발 세션을 유지

```text
개발 PC ── SSH :22 (현재 공인 IP /32만) ──> Lightsail
                                                ├─ tmux + Claude Code 또는 Codex
                                                └─ stock-chatbot.service
```

Orca, Caddy, 4224, HTTP/HTTPS 공개 포트는 사용하지 않는다. CLI 전용 구성에서 SSH는 유일한
개발·관리 경로이므로 `phase=final`에도 TCP 22를 현재 공인 IP에만 남긴다.

## 2. 소유권

| 범위 | 위치 | 내용 |
|---|---|---|
| AWS 자원 | [`../terraform/`](../terraform/) | 인스턴스, 키페어, 고정 IP, TCP 22 방화벽 |
| 호스트 공통 설정 | [`../scripts/`](../scripts/) | swap, Node.js, tmux, CLI, 개발용 레포 |
| stock_chatbot 운영 설치 | `stock_chatbot` 저장소 | `/srv/stock-chatbot`, `.env`, systemd 유닛, 백업 cron |

운영 체크아웃은 `/srv/stock-chatbot`, 개발 체크아웃은 `~/workspace/stock_chatbot`으로 분리한다.
개발용 체크아웃에는 운영 토큰을 두지 않는다.

## 3. 구축

### 3.1 로컬 준비

Windows PowerShell에서 AWS CLI, Terraform, OpenSSH, Git Bash를 준비하고 AWS 인증을 확인한다.

```powershell
aws sts get-caller-identity
terraform -version
ssh -V
& "C:\Program Files\Git\bin\bash.exe" --version
```

공개키가 없으면 만든다.

```powershell
if (-not (Test-Path "$env:USERPROFILE\.ssh\id_ed25519.pub")) {
    ssh-keygen -t ed25519 -C "orca-host"
}
```

### 3.2 Terraform

```powershell
Copy-Item service\remote-lightsail\terraform\terraform.tfvars.example service\remote-lightsail\terraform\terraform.tfvars
terraform -chdir=service/remote-lightsail/terraform init
terraform -chdir=service/remote-lightsail/terraform plan
terraform -chdir=service/remote-lightsail/terraform apply
```

`small_3_0`이 2GB 기본값이다. `my_ip`를 비우면 현재 공인 IP를 감지해 TCP 22를 `/32`로 연다.
외부 네트워크가 바뀌면 같은 apply를 다시 실행한다.

### 3.3 호스트 설정

```powershell
Copy-Item service\remote-lightsail\scripts\config.example.env service\remote-lightsail\scripts\config.env
& "C:\Program Files\Git\bin\bash.exe" ./service/remote-lightsail/scripts/util/sync-host.sh
```

서버에서 실행한다.

```bash
cd ~/remote-lightsail-scripts
./install/01-host-base.sh
./install/02-agent-cli.sh
claude
codex
gh auth login
./install/03-repos.sh
```

그다음 `stock_chatbot` 저장소의 호스트 설치 절차로 `stock-chatbot.service`를 만들고, 운영 체크아웃과
개발 체크아웃이 겹치지 않는지 확인한다. 이 서비스의 `.env`와 백업 설정은 이 저장소에 복사하지 않는다.

### 3.4 검증

```bash
cd ~/remote-lightsail-scripts
./util/verify-host.sh
```

다음도 수동으로 확인한다.

```powershell
terraform -chdir=service/remote-lightsail/terraform output -raw tmux_command
```

출력 명령으로 접속해 `~/workspace`에서 Claude Code 또는 Codex를 실행한다. SSH를 끊고 같은 명령으로
다시 접속해 tmux 세션이 이어지는지, `sudo reboot` 뒤 `stock-chatbot.service`가 자동 복구되는지 확인한다.

## 4. 2GB 운영 기준

- 봇은 실측 후 `MemoryMax=512M~768M`으로 제한하고 `OOMScoreAdjust=-500`을 사용한다.
- 에이전트는 한 번에 하나만 실행한다. 대형 빌드·테스트와 봇의 바쁜 시간대를 겹치지 않는다.
- 2GB swap은 활성화하지만 지속적인 swap 사용, OOM, 높은 load는 4GB 전환 신호다.
- 4GB 전환은 현재 인스턴스의 스냅샷으로 더 큰 새 인스턴스를 만든 뒤 고정 IP를 옮기는 방식으로 한다.
  Terraform의 `bundle_id`만 바꿔 기존 인스턴스를 교체하면 데이터 이전 절차를 건너뛰게 되므로 사용하지 않는다.

## 5. 운영과 복구

| 목적 | 명령 |
|---|---|
| 개발 세션 접속 | `terraform output -raw tmux_command` |
| 봇 상태 | `systemctl status stock-chatbot --no-pager` |
| 봇 로그 | `journalctl -u stock-chatbot -f` |
| 방화벽 drift | `terraform -chdir=service/remote-lightsail/terraform plan` |
| 현재 허용 포트 | `aws lightsail get-instance-port-states --region ap-northeast-2 --instance-name orca-host` |
| 수동 스냅샷 | `aws lightsail create-instance-snapshot --region ap-northeast-2 --instance-name orca-host --instance-snapshot-name <NAME>` |

삭제 전에는 운영 데이터, 자격증명, 미푸시 커밋을 백업한다. 완전 삭제는 다음 명령으로만 수행한다.

```powershell
terraform -chdir=service/remote-lightsail/terraform destroy
```

## 6. 보안 원칙

- TCP 22는 현재 공인 IP `/32`만 허용한다.
- 키·Terraform state·`.env`·토큰은 Git에 커밋하지 않는다.
- `stockbot` 전용 계정과 `0600` `.env`를 사용한다.
- 개발용 `~/workspace/stock_chatbot`에는 운영 토큰을 두지 않는다.

# remote_coding

개인 인프라 코드 저장소다. 최상위는 서비스 운영 구성과 인프라 학습 랩으로 나뉜다.

| 영역 | 위치 | 내용 |
|---|---|---|
| 원격 개발·운영 서비스 | [`service/remote-lightsail/`](service/remote-lightsail/) | 2GB Lightsail, SSH + tmux, Claude Code/Codex CLI, `stock_chatbot.service` |
| 인프라 학습 랩 | [`infra-labs/`](infra-labs/) | Kubernetes·Ceph·BeeGFS·Hadoop 등 로컬/AWS 실습 |

## remote-lightsail

이 서비스는 서울 리전 Lightsail `small_3_0`(2GB RAM, 2 vCPU) 한 대에서 운영 봇과 단일 CLI 개발
에이전트를 함께 실행한다. 접속 경로는 SSH뿐이며 공개 포트는 현재 공인 IP `/32`로 제한된 TCP 22다.

```text
개발 PC ── SSH + tmux ──> Lightsail
                              ├─ Claude Code 또는 Codex (동시 1개)
                              └─ stock-chatbot.service
```

Orca, Caddy, HTTPS/WSS 프록시는 현재 구성에 포함하지 않는다. 큰 빌드, 지속적인 swap 사용, OOM 또는
에이전트 동시 실행이 필요해지면 스냅샷 기반으로 4GB 인스턴스로 전환한다.

| 문서·코드 | 역할 |
|---|---|
| [`service/remote-lightsail/README.md`](service/remote-lightsail/README.md) | 서비스 구성과 책임 경계 |
| [`service/remote-lightsail/docs/lightsail-plan.md`](service/remote-lightsail/docs/lightsail-plan.md) | 구축·운영·복구 절차 |
| [`service/remote-lightsail/docs/stock-chatbot-merge-plan.md`](service/remote-lightsail/docs/stock-chatbot-merge-plan.md) | 1GB 봇 인스턴스 통합 절차 |
| [`service/remote-lightsail/terraform/`](service/remote-lightsail/terraform/) | 인스턴스, 고정 IP, 키페어, SSH 방화벽 |
| [`service/remote-lightsail/scripts/`](service/remote-lightsail/scripts/) | swap, tmux, Claude/Codex, 개발용 레포 설정 |

### 빠른 시작

Windows PowerShell에서 실행한다.

```powershell
Copy-Item service\remote-lightsail\terraform\terraform.tfvars.example service\remote-lightsail\terraform\terraform.tfvars
Copy-Item service\remote-lightsail\scripts\config.example.env service\remote-lightsail\scripts\config.env

terraform -chdir=service/remote-lightsail/terraform init
terraform -chdir=service/remote-lightsail/terraform apply
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

`stock-chatbot.service`의 운영 설치, `.env`, 백업 cron은 `stock_chatbot` 저장소가 소유한다.
그 설치를 끝낸 뒤 다음으로 함께 점검한다.

```bash
./util/verify-host.sh
```

개발 세션 명령은 Terraform output으로 얻는다.

```powershell
terraform -chdir=service/remote-lightsail/terraform output -raw tmux_command
```

## infra-labs

각 랩은 독립된 폴더와 README를 가진다. 실행 방법과 전제 조건은 각 랩의 README를 따른다.

- [`infra-labs/systems/`](infra-labs/systems/): 실행 가능한 랩
- [`infra-labs/docs/`](infra-labs/docs/): 랩 검토·호환성·마이그레이션 문서

## 비밀정보와 상태 파일

`service/remote-lightsail/scripts/config.env`, Terraform state, `terraform.tfvars`, `.env`, SSH 키와
토큰은 커밋하지 않는다. 경로 변경에 맞춰 루트 [`.gitignore`](.gitignore)도
`service/remote-lightsail/` 기준으로 관리한다.

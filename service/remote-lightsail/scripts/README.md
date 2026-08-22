# scripts/

2GB Lightsail에서 SSH CLI 개발과 `stock_chatbot`을 함께 운영하기 위한 호스트 설정이다.
Orca, Caddy, 웹 프록시는 이 구성에 포함하지 않는다.

## 구조

```text
scripts/
├── config.example.env       # 로컬에서 복사해 쓰는 설정 예시
├── install/
│   ├── 01-host-base.sh      # 공통 패키지, 2GB swap, Node.js, tmux
│   ├── 02-agent-cli.sh      # Claude Code / Codex CLI
│   └── 03-repos.sh          # ~/workspace 개발용 클론
└── util/
    ├── lib.sh               # 공통 설정과 Terraform output 함수
    ├── provision-host.sh    # terraform apply → SSH 대기 → sync-host.sh 까지 한 번에
    ├── sync-host.sh         # 위 스크립트를 서버에 전송
    └── verify-host.sh       # CLI, swap, stock-chatbot 서비스 점검
```

`stock-chatbot.service`, 운영 체크아웃(`/srv/stock-chatbot`), 백업 cron, `.env`의 정의와 설치는
[`stock_chatbot`](https://github.com/tkddls8848/stock_chatbot) 저장소가 소유한다. 이 저장소는
호스트·방화벽·개발 CLI와 해당 서비스의 상태 검증만 담당한다.

## 준비와 실행

저장소 루트에서 실행한다. 인프라 생성부터 스크립트 복사까지는 `util/provision-host.sh`
하나로 끝난다.

```powershell
& "C:\Program Files\Git\bin\bash.exe" ./service/remote-lightsail/scripts/util/provision-host.sh
```

하는 일은 다음과 같다.

1. `terraform`, `ssh`, `scp`, AWS 자격증명, 공개키(`ssh_public_key_path`) 확인
2. `terraform.tfvars` / `config.env` 가 없으면 예시에서 복사 (이미 있으면 그대로 둔다)
3. `terraform init` + `terraform apply` — 인스턴스, 고정 IP, 방화벽 생성
4. 새 인스턴스에 SSH 가 열릴 때까지 대기 (고정 IP 를 재사용했다면 옛 host key 정리)
5. `util/sync-host.sh` 로 `install/`, `util/`, `host.env` 전송

여기까지가 자동 구간이고, `install/*.sh` 실행과 CLI 로그인은 아래처럼 서버에서 사람이 한다.

옵션은 다음과 같다.

```powershell
provision-host.sh -y             # terraform apply 를 확인 없이 실행
provision-host.sh --phase build  # 방화벽 단계 지정
provision-host.sh --skip-apply   # 이미 떠 있는 호스트에 복사만
provision-host.sh --ssh-wait 60  # SSH 대기 횟수 (5초 간격, 기본 40)
provision-host.sh --help
```

레포 목록이나 인스턴스 이름을 미리 손보려면 먼저 복사해 둔다.

```powershell
Copy-Item service\remote-lightsail\scripts\config.example.env service\remote-lightsail\scripts\config.env
Copy-Item service\remote-lightsail\terraform\terraform.tfvars.example service\remote-lightsail\terraform\terraform.tfvars
notepad service\remote-lightsail\scripts\config.env
```

단계별로 직접 실행해도 결과는 같다.

```powershell
terraform -chdir=service/remote-lightsail/terraform init
terraform -chdir=service/remote-lightsail/terraform apply
& "C:\Program Files\Git\bin\bash.exe" ./service/remote-lightsail/scripts/util/sync-host.sh
```

서버에서는 다음 순서로 실행한다.

```bash
cd ~/remote-lightsail-scripts
./install/01-host-base.sh
./install/02-agent-cli.sh

# 사람이 직접 완료한다.
claude
codex
gh auth login

./install/03-repos.sh

# stock_chatbot 저장소의 설치 절차로 stock-chatbot.service를 만든 뒤 실행한다.
./util/verify-host.sh
```

개발 세션은 SSH와 tmux로 유지한다.

```powershell
terraform -chdir=service/remote-lightsail/terraform output -raw tmux_command
```

출력된 명령을 실행하면 `dev` tmux 세션을 새로 만들거나 기존 세션에 재접속한다.

## 2GB 운영 원칙

- `stock-chatbot.service`는 실측 뒤 `MemoryMax=512M~768M`으로 제한한다.
- Claude Code 또는 Codex는 한 번에 하나만 실행한다. 큰 빌드·테스트와 에이전트 작업을 겹치지 않는다.
- 2GB swap은 완충 장치이며 RAM의 대체재가 아니다. swap 사용량이나 load가 지속적으로 높으면 4GB로 올린다.
- 최종 방화벽도 TCP 22를 현재 공인 IP `/32`에만 유지한다. SSH CLI가 유일한 관리 경로다.

전체 절차와 stock_chatbot 전환은 [`../docs/`](../docs/) 문서를 따른다.

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
    ├── sync-host.sh         # 위 스크립트를 서버에 전송
    └── verify-host.sh       # CLI, swap, stock-chatbot 서비스 점검
```

`stock-chatbot.service`, 운영 체크아웃(`/srv/stock-chatbot`), 백업 cron, `.env`의 정의와 설치는
[`stock_chatbot`](https://github.com/tkddls8848/stock_chatbot) 저장소가 소유한다. 이 저장소는
호스트·방화벽·개발 CLI와 해당 서비스의 상태 검증만 담당한다.

## 준비와 실행

저장소 루트에서 실행한다.

```powershell
Copy-Item service\remote-lightsail\scripts\config.example.env service\remote-lightsail\scripts\config.env
notepad service\remote-lightsail\scripts\config.env

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

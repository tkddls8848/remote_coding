# remote-lightsail

AWS Lightsail에서 Claude Code 또는 Codex CLI 하나와 `stock_chatbot.service`를 함께 운영하는
2GB Ubuntu 24.04 호스트다. 접속은 SSH + tmux만 사용한다.

| 영역 | 위치 | 책임 |
|---|---|---|
| AWS 인스턴스·고정 IP·방화벽 | [`terraform/`](terraform/) | `small_3_0`, TCP 22를 현재 공인 IP `/32`에만 허용 |
| 호스트 공통 설정·개발 CLI | [`scripts/`](scripts/) | swap, Node.js, tmux, Claude Code, Codex, 개발용 레포 |
| 서비스 통합 절차 | [`docs/stock-chatbot-merge-plan.md`](docs/stock-chatbot-merge-plan.md) | `stock_chatbot` 운영 체크아웃과 systemd 서비스 |
| 운영 절차 | [`docs/lightsail-plan.md`](docs/lightsail-plan.md) | 구축, 검증, 복구, 4GB 확장 기준 |

인프라 생성부터 호스트 스크립트 복사까지는
[`scripts/util/provision-host.sh`](scripts/util/provision-host.sh) 하나로 수행한다. 그 뒤
`install/*.sh` 실행과 CLI 로그인은 서버에서 사람이 직접 한다.

Orca와 Caddy는 설치하지 않는다. 이후 필요해지면 스냅샷 기반으로 4GB 호스트를 만들고 별도 Orca
전환 절차를 수행한다.

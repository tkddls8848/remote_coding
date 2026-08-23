# stock_chatbot을 CLI 개발 호스트로 통합하는 계획

> **보관 문서:** 이 문서는 과거 2GB SSH+tmux 설계를 기록한다. 현재 Orca 브라우저 서버 구축에는
> [`lightsail-plan.md`](lightsail-plan.md)를 사용한다.

> 기준일: 2026-08-22
> 목표: 1GB `stock_chatbot` 인스턴스를 폐기하고, 2GB Lightsail 한 대에서 운영 봇과 단일 CLI 개발
> 에이전트를 함께 실행한다. Orca와 Caddy는 사용하지 않는다.

## 1. 목표 배치

```text
Lightsail orca-host (ap-northeast-2, small_3_0, 2GB / 2 vCPU)
├─ SSH :22 — 현재 공인 IP /32만 허용
├─ ubuntu
│  ├─ tmux dev
│  └─ ~/workspace/stock_chatbot     # 개발용; 운영 토큰 없음
└─ stockbot
   └─ /srv/stock-chatbot            # 운영용
      ├─ .env (stockbot:stockbot, 0600)
      ├─ data/
      └─ stock-chatbot.service
```

2GB는 비용 우선 구성이다. 봇과 Claude Code 또는 Codex 하나를 순차적으로 사용하는 것을 전제로 하며,
동시 에이전트·대형 빌드가 빈번하면 4GB로 전환한다.

## 2. 책임 경계

| 대상 | 소유 저장소 | 위치 |
|---|---|---|
| 인스턴스·고정 IP·SSH 방화벽 | `remote_coding` | `service/remote-lightsail/terraform/` |
| swap·tmux·Node·Claude/Codex·개발 클론 | `remote_coding` | `service/remote-lightsail/scripts/` |
| 운영 체크아웃·venv·`.env`·systemd·백업 cron | `stock_chatbot` | `iac/host/` 및 운영 문서 |

`remote_coding`은 stock_chatbot의 비밀값을 받거나 서비스 유닛을 중복 정의하지 않는다.

## 3. 사전 조건

- 기존 1GB 인스턴스에서 `free -h`, `systemctl status stock-chatbot`, 최근 봇 로그를 기록한다.
- `data/`와 `.env`의 백업을 만든다.
- 개발 클론과 운영 체크아웃을 반드시 분리한다.
- 새 호스트에 `stock-chatbot.service`를 시작하기 전에는 이전 호스트의 봇을 중지한다. 같은 Telegram
  토큰의 롱폴링 프로세스가 둘이면 둘 다 불안정해진다.

## 4. 전환 절차

1. 새 2GB 호스트를 [`lightsail-plan.md`](lightsail-plan.md) 절차로 생성한다.
2. 새 호스트에서 공통 스크립트와 Claude/Codex, GitHub 인증을 완료한다.
3. `stock_chatbot` 저장소의 설치 절차로 `stockbot` 사용자, `/srv/stock-chatbot`, venv,
   `stock-chatbot.service`, 백업 cron을 준비한다. 이 단계에서는 서비스를 시작하지 않는다.
4. 전환 창에 이전 호스트의 `stock-chatbot.service`를 stop/disable하고 `data/`와 `.env`를 안전하게
   옮긴다.
5. 새 호스트에서 `.env` 권한을 `0600`으로 설정하고 `stock-chatbot.service`를 enable/start한다.
6. Telegram 명령, 차트 생성, 스케줄, 재부팅 자동 복구를 확인한다.
7. 24~72시간 관망 후 이전 인스턴스와 고정 IP를 폐기한다.

## 5. 리소스와 안전장치

| 대상 | 설정 | 이유 |
|---|---|---|
| `stock-chatbot.service` | `MemoryMax=512M~768M` (실측 후) | 봇의 메모리를 제한하고 2GB 호스트를 보호 |
| `stock-chatbot.service` | `OOMScoreAdjust=-500` | 메모리 압박 때 개발 작업보다 봇을 우선 보호 |
| 개발 에이전트 | 동시 1개 | CLI·빌드의 메모리/CPU 급증 제한 |
| 호스트 | 2GB swap | 짧은 메모리 피크 완충; 지속 사용 시 4GB 전환 |

`free -h`, `vmstat 1`, `uptime`, `journalctl -k`에서 swap 증가·OOM·지속적 고부하가 보이면
4GB로 전환한다. 전환 전 수동 스냅샷을 만들고 새 4GB 인스턴스를 검증한 뒤 고정 IP를 옮긴다.

## 6. 인수 기준

- `stock-chatbot.service`가 `enabled`와 `active`다.
- `ssh -t ubuntu@<IP> tmux new -As dev`로 개발 세션이 재접속된다.
- 개발용 `~/workspace/stock_chatbot`에 운영 `.env`가 없다.
- 재부팅 후 봇이 자동 복구된다.
- Lightsail 공개 포트는 TCP 22 하나이며 현재 공인 IP `/32`만 허용한다.

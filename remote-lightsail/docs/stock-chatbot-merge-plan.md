# stock_chatbot 통합 현황과 전환 계획

> 기준일: 2026-08-24  
> 상태: **미통합·보류**. 현재 `remote-lightsail`은 Orca 상시 개발 서버만 구축하며
> `stock-chatbot.service`의 설치·데이터 이전·운영 전환을 수행하지 않는다.

## 1. 이전 문서에서 달라진 점

과거의 “2GB Lightsail + SSH/tmux + 운영 봇” 설계는 폐기한다. 현행 기반은
[`lightsail-plan.md`](lightsail-plan.md)의 브라우저 제어형 Orca 서버다.

| 항목 | 과거 문서 | 현행 기준 |
|---|---|---|
| 호스트 | `small_3_0`, 2GB | `medium_3_0`, 4GB RAM / 2 vCPU |
| swap | 2GB | 4GB |
| 개발 제어 | SSH + tmux | Tailscale Serve HTTPS + Orca Web, SSH는 복구용 |
| Orca/Caddy | 사용 안 함 | Orca 사용; Caddy 대신 Tailscale Serve 사용 |
| 저장소 경로 | `service/remote-lightsail/` | `remote-lightsail/` |
| stock_chatbot 통합 | 실행 예정 | 현재 구현 없음; 별도 승인 후 수행 |

현재 기본 `REPOS`는 `gong-go homepage naraapi pathfinder devlog`이며 `stock_chatbot`은 포함되지
않는다. `install/05-repos.sh`는 개발 클론과 Orca 등록만 담당하고 운영 서비스는 배포하지 않는다.

## 2. 현재 책임 경계

| 대상 | 현재 소유 위치 | 상태 |
|---|---|---|
| Lightsail 인스턴스·고정 IP·SSH 공인 방화벽 | `remote-lightsail/terraform/` | 정의됨 |
| 호스트 패키지·4GB swap·Tailscale·Orca·개발 CLI | `remote-lightsail/scripts/` | 정의됨 |
| Orca 개발 저장소 클론 | `remote-lightsail/scripts/install/05-repos.sh` | `REPOS` 기반 |
| `stockbot` 사용자와 `/srv/stock-chatbot` | 없음 | 미구현 |
| Python venv·운영 `.env`·데이터 마이그레이션 | 없음 | 미구현 |
| `stock-chatbot.service`·백업·복구 | 없음 | 미구현 |

`remote-lightsail`은 stock_chatbot의 운영 비밀값을 소유하지 않는다. 향후 통합하더라도 앱 설치,
서비스 유닛, 데이터 형식, 백업·복구 절차는 `stock_chatbot` 저장소가 소유해야 한다.

## 3. 승인 후 목표 배치

```text
Lightsail orca-host (Ubuntu 24.04, 4GB 이상)
├─ tailscaled + Tailscale Serve HTTPS
├─ orca-serve.service
│  └─ /home/orca/workspace/stock_chatbot   # 선택적 개발 클론, 운영 비밀 없음
├─ ubuntu                                  # 설치·복구 관리자
└─ stockbot                                # 운영 전용 사용자
   └─ /srv/stock-chatbot
      ├─ app/ 또는 checkout/
      ├─ .venv/
      ├─ .env                 # 0600, Git/Orca workspace 밖
      ├─ data/
      └─ stock-chatbot.service
```

개발 클론과 운영 체크아웃을 반드시 분리한다. `/home/orca/workspace/stock_chatbot`은 개발용이며
Telegram 토큰, 운영 `.env`, 운영 데이터의 원본을 두지 않는다.

## 4. 통합 전 결정 사항

실행 전에 다음을 확정해야 한다.

1. `stock_chatbot` 저장소와 실제 배포 문서/스크립트의 위치
2. 기존 운영 인스턴스와 `stock-chatbot.service`의 현재 상태
3. 영속 데이터 경로, 데이터베이스 종류, 백업·복구 방법
4. Telegram/API 토큰 등 비밀값의 전달·보관 방식
5. 다운타임 허용 시간과 롤백 판단 시점
6. 4GB 호스트에서 Orca 작업과 봇의 동시 메모리 실측치

이 정보가 없는 상태에서는 기존 인스턴스 중지, 데이터 복사, 서비스 시작 또는 폐기를 수행하지
않는다.

## 5. 전환 절차

### 단계 A — 현황과 백업

1. 기존 호스트에서 서비스 상태, 버전, 최근 로그, 메모리와 디스크 사용량을 기록한다.
2. 운영 `.env`와 데이터의 일관된 백업을 만든다.
3. 별도 위치에 복원 시험을 수행하고 체크섬 또는 애플리케이션 검증으로 확인한다.
4. 새 Orca 호스트의 스냅샷을 만든다.

### 단계 B — 새 호스트 준비

1. `stockbot` 전용 system user와 `/srv/stock-chatbot`을 만든다.
2. `stock_chatbot` 저장소가 소유한 설치 절차로 운영 체크아웃과 venv를 준비한다.
3. `.env`는 `stockbot:stockbot`, `0600`으로 두고 Git과 Orca workspace에서 제외한다.
4. `stock-chatbot.service`와 백업 작업을 설치하되 아직 서비스를 시작하지 않는다.
5. 개발 클론이 필요할 때만 `REPOS`에 `stock_chatbot`을 추가하고 `05-repos.sh`를 실행한다.

### 단계 C — 전환

1. 변경 동결과 전환 시작을 선언한다.
2. 기존 호스트의 `stock-chatbot.service`를 stop/disable한다.
3. 최종 데이터와 `.env`를 새 호스트로 안전하게 전송한다.
4. 소유권·권한·설정값을 검증한다.
5. 새 호스트에서 서비스를 enable/start한다.
6. Telegram 명령, 차트/파일 생성, 예약 작업, 외부 API와 재부팅 자동 복구를 검증한다.

같은 Telegram bot token으로 두 롱폴링 프로세스를 동시에 실행하지 않는다.

### 단계 D — 관망과 폐기

1. 최소 24~72시간 로그, 오류율, 응답, 메모리, swap, 디스크 증가를 관찰한다.
2. 백업 작업과 실제 복원 절차를 다시 확인한다.
3. 인수 기준을 모두 만족한 뒤에만 기존 인스턴스와 고정 IP의 폐기를 별도로 승인한다.

## 6. 리소스 안전장치

4GB 호스트에서도 Orca/Electron, Codex, 빌드와 운영 봇이 동시에 메모리를 사용한다. 다음 값은
확정값이 아니라 실측 후 적용할 시작 범위다.

| 대상 | 시작 기준 | 목적 |
|---|---|---|
| `stock-chatbot.service` | `MemoryHigh=512M` 검토 | 지속 압박 전에 완만한 제한 |
| `stock-chatbot.service` | `MemoryMax=768M` 검토 | 비정상 증가가 호스트 전체를 소진하지 않도록 제한 |
| `stock-chatbot.service` | `Restart=on-failure`와 restart rate limit | 장애 복구와 재시작 루프 방지 |
| 운영 봇 | `OOMScoreAdjust`는 실측·우선순위 합의 후 결정 | 무조건적인 우선 보호로 Orca까지 불안정해지는 상황 방지 |
| Orca 작업 | 에이전트 1개부터 시작 | 동시 피크 제한 |
| 호스트 | 기존 4GB swap 유지 | 짧은 피크 완충; RAM 대체 용도 금지 |

swap이 지속 증가하거나 OOM, 높은 load, 디스크 I/O 지연이 보이면 동시 작업을 줄인다. 반복되면
Lightsail 스냅샷과 앱 백업을 만든 뒤 `large_3_0`(8GB) 이상에서 검증한다.

## 7. 인수 기준

- `orca-serve.service`, `tailscaled.service`, `stock-chatbot.service`가 모두 enabled/active다.
- Orca Web은 `https://<host>.<tailnet>.ts.net`에서 정상 렌더링되고 Codex 작업을 시작할 수 있다.
- Lightsail 공인 포트는 TCP 22 하나이고 현재 관리자 공인 IP `/32`만 허용한다.
- 운영 `.env`는 `/srv/stock-chatbot`의 운영 영역에만 있고 권한은 `0600`이다.
- 개발 workspace에는 운영 비밀과 운영 데이터 원본이 없다.
- Telegram 주요 기능과 예약 작업이 성공한다.
- 재부팅 후 두 서비스가 자동 복구된다.
- 백업에서 데이터를 복원하는 절차가 실제로 검증됐다.
- 24~72시간 관망 동안 OOM, 지속적인 swap 증가, 재시작 루프가 없다.

## 8. 롤백

새 호스트 검증이 실패하면 다음 순서로 롤백한다.

1. 새 `stock-chatbot.service`를 stop/disable한다.
2. 전환 이후 새 데이터가 생성됐다면 충돌 없이 되돌릴 방법을 먼저 결정한다.
3. 기존 호스트의 데이터와 설정이 유효한지 확인한다.
4. 기존 서비스 하나만 enable/start한다.
5. Telegram/API 기능을 확인하고 실패 원인과 데이터 차이를 기록한다.

롤백 중에도 동일 토큰을 사용하는 두 프로세스를 동시에 실행하지 않는다. Orca 호스트 자체는
stock_chatbot 전환 실패와 분리하여 유지한다.

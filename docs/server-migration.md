# 기존 Lightsail → ubuntu 통합 서버 이관

2026-09-23 KST 전환 완료: `orca-host-tokyo-v2`가 기존 운영 고정 IP를 사용한다.
`https://nunchi.live`와 새 Orca 주소
`https://orca-host-tokyo-v2.<tailnet>.ts.net/web-index.html`의 HTTP 200을 확인했다.
봇·웹·Orca는 `ubuntu`, Caddy는 패키지 전용 계정 `caddy`로 실행한다.
기존 서버의 봇·웹·refresh timer·Caddy는 정지하고 자동 시작을 해제했다. 기존 서버는
롤백용으로 보존하며, 새 서버의 스냅샷과 데이터 백업도 설정돼 있다.

기존 서버는 `orca-host-tokyo`, 새 서버는 `orca-host-tokyo-v2`다. 새 서버도 도쿄
Ubuntu 24.04 / 4GB로 구성한다. 기존 인스턴스와 IP는 새 인스턴스 생성 시 변경하지 않는다.
`terraform/`는 기존 서버와 운영 고정 IP 상태, `terraform/migration/`는 새 서버 상태를 소유한다.
기존 상태의 `instance_name`을 바꿔 replacement를 실행하면 안 된다.

## 2026-09-22 기존 서버에서 확인한 서비스

| 대상 | 현재 상태 | 새 서버에서 보존할 내용 |
|---|---|---|
| `stock-chatbot.service` | stockbot, enabled/active | Telegram 봇, `.env`, data, 실행 코드 |
| `stock-chatbot-web.service` | stockbot, enabled/active | 공개 웹, localhost 8788 |
| `stock-chatbot-polymarket-refresh.timer` | enabled/active | Asia/Seoul 00·03·06·09·12·15·18·21시 |
| `stock-chatbot-polymarket-refresh.service` | oneshot | 순회 및 OnSuccess 후속 작업 |
| `stock-chatbot-polymarket-brief.service` | oneshot | 줄글 생성 |
| `stock-chatbot-polymarket-trending.service` | oneshot | 트렌드 선정 |
| Caddy | enabled/active | 실제 Caddyfile, 인증 설정, 인증서 저장소 |
| `/etc/cron.d/stock-chatbot-backup` | 매일 18:00 UTC | 데이터 백업, 14일 보관, 기존 백업 파일 |
| `orca-serve.service` | orca, enabled/active | 새 호스트 설치 스크립트로 ubuntu에서 구성 |
| Ollama | 기존 서버에 보존 | 목록 기록; 봇·웹 Python 코드에 참조가 없어 새 서버에는 설치하지 않음 |

확인한 앱 커밋: `0e2e0f10ccabe1010386d061238bc4942cc0dc61`.
실제 가상환경의 패키지 88개 버전을 export한다. GitHub 최신 코드로 이관과 업그레이드를
동시에 하지 않는다. 기존 서버의 미추적 `data/`와 `requirements.lock.txt`도 보존한다.

## 보존 자료

`scripts/util/export-stock-chatbot.sh`를 **기존 서버**에서 root로 실행한다.
기본 실행은 서비스를 멈추지 않는 준비용 백업이다. 압축 파일에는 비밀값이 있으므로
stdout을 비공개 파일로 직접 저장하고 터미널에 출력하지 않는다.

```bash
sudo ./export-stock-chatbot.sh > stock-chatbot-online.tgz
sha256sum stock-chatbot-online.tgz > SHA256SUMS
```

코드와 `.git`, `.env`, `data/`, 실제 systemd 유닛/타이머, 패키지 버전, cron,
Caddy 설정/인증서, 이전 데이터 백업을 포함한다. 재생성 가능한 venv와 캐시는 제외한다.
실행 중인 데이터를 복사한 준비용 백업은 최종 전환용 일관된 스냅샷이 아니다.

이번 작업의 로컬 준비 백업은 `.gitignore`에 포함된
`backup/migration-20260922/stock-chatbot-online.tgz`에 보관한다. Windows ACL을 현재
사용자와 SYSTEM으로 제한했고, `SHA256SUMS`와 필수 아카이브 항목 검사를 완료했다.
최종 정지 백업은 같은 디렉터리의 `stock-chatbot-final.tgz`와 `FINAL-SHA256SUMS`다.

## 새 서버 구성

```bash
cp terraform/migration/terraform.tfvars.example terraform/migration/terraform.tfvars
TF_DIR="$PWD/terraform/migration" ./scripts/util/provision-host.sh
```

새 서버용 `host.env`:

```bash
ORCA_SERVICE_USER=ubuntu
ORCA_SERVICE_PASSWORD=ubuntu
ORCA_SERVICE_PASSWORD_MIN_LEN=5
ORCA_SERVICE_SUDO=nopasswd
TELEGRAM_BOT_START=0
TELEGRAM_BOT_UPDATE=0
TELEGRAM_BOT_ENV_FILE=
```

01·02·03·04·06·07 설치 단계를 진행한다. Tailscale 새 노드는 고유한 `orca-host-tokyo-v2`
이름으로 가입한다. 기존 Tailscale 머신 ID를 복사하지 않는다. Orca도 새 서버에서 페어링한다.

비공개 채널로 백업을 새 서버에 복사하고 체크섬을 대조한 뒤 실행한다:

```bash
./util/restore-stock-chatbot.sh /home/ubuntu/stock-chatbot-online.tgz
./util/verify-host.sh
```

복원 스크립트는 원본 호스트와 실행 중인 대상 서비스가 있는 호스트를 거부한다.
원본의 코드/실제 패키지 버전과 서비스 정의를 사용하고 실행 계정만 ubuntu로 맞춘다.
봇·웹·타이머·Caddy는 정지/자동 시작 해제 상태로 둔다. 백업 cron의 시간과 보관 기간은
유지하며 사용자 필드만 ubuntu로 변경한다. 원본 `.env`를 로컬 개발 `.env`로 덮어쓰지 않는다.
Caddy의 `bind`에 고정된 기존 사설 IPv4는 새 서버의 사설 IPv4로 치환한다.
공인 고정 IP가 같아도 사설 IP는 다르므로 이 변환이 필요하다. 타이머의 마지막 실행 시각도
보존해 `Persistent=true`의 전환 중 누락 작업 처리가 유지되게 한다.

## 전환 순서와 롤백

1. 새 서버에서 import, systemd 구성, Caddy 구성, 파일 권한, sudo와 Orca 준비 상태를 검증한다.
2. 기존 서버에서 `export-stock-chatbot.sh --quiesce`로 봇·웹·예약 작업을 멈추고 최종 백업한다.
   성공하면 기존 서비스는 정지 상태로 남는다. 실패하면 정지 전 실행 목록을 복구한다.
3. 체크섬을 검증하고 새 서버에서 `restore-stock-chatbot.sh final.tgz --refresh`를 실행한다.
   준비용 백업(`quiesced=0`)으로 최종 덮어쓰기를 시도하면 거부한다.
4. 선택된 방식은 **기존 고정 IP 이전**이다. 새 서버 상태에서 `allocate_static_ip=false`를
   적용해 임시 IP 연결과 할당을 해제한다. 기존 상태의
   `static_ip_target_instance_name="orca-host-tokyo-v2"`를 적용해 운영 IP를 새 서버에 연결한다.
   이 구간의 SSH는 새 서버의 Tailscale 주소를 사용한다. 기존 상태의 운영 IP 리소스는
   계속 유지한다. 기존 서버를 나중에 삭제할 때도 기존 상태 전체를 destroy하면 안 된다.
   새 서버 상태를 refresh한 뒤 `static_ip` output이 운영 IP인지 확인한다.
5. 새 서버에서 봇·웹·Caddy·refresh timer를 enable/start한다. 후속 oneshot은 타이머가 호출한다.
   `host.env`의 `TELEGRAM_BOT_START=1`로 바꾸고 점검한다.
6. 기존 서버의 봇/웹/타이머 자동 시작을 해제해 재부팅 후 이중 polling을 막는다.
   기존 서버와 백업은 새 서버의 정상 운영을 확인할 때까지 보존한다.

전환 실패 시 **새 서버의 봇과 예약 작업부터 정지**하고 트래픽을 기존 서버로 되돌린 뒤
기존 active/enabled 목록을 복구한다. 신규 서버에서 이미 처리한 발송 이력과 상태가 있다면
원본으로 되돌리기 전에 데이터 차이를 확인해야 중복 발송을 피할 수 있다.

`08-telegram-bot.sh` 단독 설치는 GitHub 클론을 지원하지만, 이관에서는 export/restore로
원본 코드와 운영 데이터를 함께 보존한다. 이관 후 코드 업그레이드는 별도 작업으로 진행한다.
이 구성의 설치·복원은 이 저장소의 스크립트로 수행한다. 앱 저장소의 기존
`infra/scripts/install-shared-host.sh`는 stockbot 기본값을 사용하므로 직접 재실행하지 않는다.
공유 체크아웃을 갱신할 때는 웹·예약 작업도 중지한 뒤 설치하고 다시 시작한다.

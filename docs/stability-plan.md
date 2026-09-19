# 안정적 서비스 운영을 위한 개선 계획

> 초판: 2026-08-24 · 개정: 2026-09-19 (2판) · **적용: 2026-09-19 (13절)**  
> 대상: `remote_coding` 저장소 기반 AWS Lightsail + Orca 원격 개발 환경  
> 범위: 현행 코드 분석을 통해 발견된 안정성·보안·운영 갭과 개선 방향

> **2판 변경 요약** — 6절(보안)을 신뢰경계 기준으로 다시 썼다. 초판이 다루지 않은
> 무암호 root 권한(6.1)과 에이전트 런타임 신뢰경계(6.2)를 Critical 로 추가하고,
> 유닛 하드닝(6.4)·아웃바운드 통제(6.5)·탐지 감사 계층(6.6)을 새로 넣었다.
> 4.3 의 잘못된 라인 참조를 바로잡고 9절 우선순위표를 갱신했다. 상세는 12절 참조.

---

## 1. 현행 구조 요약

| 구분 | 내용 |
|---|---|
| 인프라 | AWS Lightsail `medium_3_0` (4GB RAM, 2 vCPU), 도쿄 리전 |
| OS | Ubuntu 24.04 |
| 네트워크 접근 | Tailscale tailnet 전용 (Orca Web), SSH 22 관리자 IP /32 |
| 주요 서비스 | `orca-serve.service`, `tailscaled.service` |
| 스크립트 | `scripts/install/01~06`, `scripts/util/*` |
| 인프라 코드 | Terraform (`terraform/`) |
| 상태 파일 | 로컬 `terraform.tfstate` |

---

## 2. 위험 영역 분류

아래 각 항목은 **현재 코드에서 직접 확인된 갭**이다. 단순 문서 부재가 아니라 장애·보안 사고·운영 불능으로 이어질 수 있는 실질적 위험이다.

---

## 3. 인프라 안정성

### 3.1 Terraform 상태 파일 로컬 보관 (Critical)

**위치:** `terraform/versions.tf` — backend 미설정  
**현상:** `terraform.tfstate`가 로컬 파일로만 존재한다. 파일에는 SSH 키·IP·리소스 ID 등 민감 정보가 포함된다.

**위험:**
- 관리 PC 분실·초기화 시 인프라 상태 복구 불가
- 여러 사람이 동시 `apply` 시 state 충돌·리소스 중복 생성
- Git에 실수로 커밋되면 민감 정보 노출

**개선 방향:**
1. S3 버킷으로 remote backend 구성 (`terraform/versions.tf` 에 `backend "s3"` 블록 추가)
2. 잠금은 S3 네이티브 `use_lockfile = true` 를 쓴다. `versions.tf` 가 이미
   `required_version >= 1.5.0` 이므로 실행 환경만 1.10 이상이면 **DynamoDB 테이블은 불필요하다**
   (테이블 비용과 관리 대상이 하나 줄어든다). 1.10 미만을 써야 하면 기존대로 DynamoDB
   `LockTable` 을 둔다
3. S3 버킷 암호화 및 버저닝 활성화
4. `terraform.tfstate*` `.gitignore` 확인 (현행 `.gitignore`에 이미 포함되어 있으나 remote 이전 후 로컬 파일 삭제 확인)

---

### 3.2 관리자 IP 고정 /32 단일 규칙 (High)

**위치:** `terraform/firewall.tf`, `terraform/variables.tf` — `my_ip` 단일 CIDR  
**현상:** SSH 포트 22가 현재 관리자 공인 IP 하나만 허용한다. IP가 바뀌면 `terraform apply`를 다시 해야 접속된다.

**위험:**
- 장애 발생 시 IP가 바뀐 상태라면 긴급 접속 불가
- ISP DHCP, VPN 전환, 출장 등 상황에서 잠금

**개선 방향:**
1. `variables.tf`에 `admin_cidrs` 목록 변수 추가 (현재 `my_ip` 대신 `list(string)` 타입)
2. 긴급용 Tailscale SSH 경로 확보: `tailscale ssh` 허용 시 공인 방화벽 없이 tailnet에서 SSH 가능
3. `my_ip` 자동 감지 실패 시(checkip.amazonaws.com 장애) fallback 방어 코드 추가

---

### 3.3 스냅샷 비용 누적 및 보존 정책 미정의 (Medium)

**위치:** `terraform/main.tf` — `auto_snapshot` 블록  
**현상:** 매일 자동 스냅샷이 활성화되어 있으나 보존 기간 정책과 비용 확인 절차가 없다.

**위험:**
- 스냅샷이 무기한 누적되어 AWS 비용 증가
- 복구 필요 시 어느 스냅샷을 사용해야 하는지 불분명

**개선 방향:**
1. Lightsail 자동 스냅샷 보존 기간 확인 및 문서화 (현행 Lightsail 기본 7일 보존)
2. 월 1회 수동 스냅샷 정책 및 명명 규칙 수립 (예: `orca-host-YYYYMMDD-manual`)
3. AWS Cost Explorer 알림 설정 ($N/월 초과 시 이메일 알림)

---

## 4. 배포 자동화 안정성

### 4.1 외부 서비스 호출에 재시도 로직 없음 (High)

**위치:**
- `scripts/install/01-host-base.sh` — nodesource APT 추가, Node.js apt-get
- `scripts/install/02-agent-cli.sh` — npm install (claude-code, codex)
- `scripts/install/05-repos.sh` — GitHub API (`gh repo list`), git clone
- `terraform/firewall.tf` — checkip.amazonaws.com IP 자동 감지

**현상:** 네트워크 일시 장애 시 스크립트가 즉시 실패한다. retry 없이 `set -euo pipefail`로 전체 중단된다.

**위험:**
- npm registry, GitHub API, nodesource 중 하나라도 일시 장애 시 설치 전체 재시작 필요
- AWS checkip 장애 시 `terraform apply` 자체가 실패

**개선 방향:**
1. `lib.sh`에 `retry N CMD` 헬퍼 함수 추가 (예: 3회 재시도, 지수 백오프)
2. npm install에 `--prefer-offline` 또는 `--retry 5` 옵션 적용
3. `gh repo list`와 `git clone` 실패 시 재시도 루프 적용
4. `terraform/variables.tf` `my_ip` 검출 실패 시 명시적 에러 메시지와 수동 입력 안내

---

### 4.2 설치 스크립트 멱등성 부족 (Medium)

**위치:** 설치 스크립트 전반  
**현상:** 일부 단계가 이미 완료된 경우를 충분히 감지하지 못한다.

**세부 갭:**
- `01-host-base.sh`: swap 재생성 방지는 있으나 apt 패키지 재설치 시 버전 확인 없음
- `02-agent-cli.sh`: claude-code, codex 이미 설치 시 재설치 발생 (버전 고정 없음)
- `05-repos.sh`: 이미 클론된 저장소는 건너뛰지만 Orca 등록 중복 처리 불분명

**개선 방향:**
1. 각 스크립트 첫머리에 "이미 완료 여부" 확인 및 skip 로직 추가
2. npm global 패키지 버전 고정 (`npm install -g @openai/codex@X.Y.Z`)
3. `05-repos.sh`: 클론 전 디렉터리 존재 확인 후 `git fetch`로 대체

---

### 4.3 Orca 바이너리 무결성 검증 없음 (High)

**위치:** `scripts/install/04-orca-server.sh:164-188` — 바이너리 다운로드 및 검증 부분  
> 초판은 이 위치를 `lines 107-130` 으로 적었으나 그 구간은 sudo 권한 설정 블록이다.
> 실제 다운로드·검증은 `:164-188`, 검증문은 `:171-172` 다. 바로잡는다.

**현상:** 다운로드 후 ELF 포맷(`:171`)과 아키텍처 문자열(`:172`) 존재만 확인하며 체크섬·서명
검증이 없다. 다운로드 자체에는 `curl -fL --retry 3`(`:169`)이 걸려 있어 4.1 의 재시도 갭에는
해당하지 않는다.

**위험:**
- 다운로드 중간 오염 또는 CDN 침해 시 변조된 바이너리 실행 가능
- 불완전 다운로드가 ELF 헤더를 보유하는 경우 통과

**개선 방향:**
1. Orca GitHub Releases에서 함께 제공되는 SHA256 체크섬 파일 다운로드 및 검증 (`sha256sum -c`)
2. 파일 크기 최소값 검증 (예: 50MB 미만이면 불완전 다운로드로 간주 거부)
3. 롤백 경로는 이미 있다 — `:175-188` 이 기존 바이너리를 `.previous` 로 보존하고
   `:263-264` 가 기동 실패 시 이를 안내한다. 추가할 것은 **체크섬 불일치를 실패로 판정하는
   분기**이지 롤백 메커니즘 자체가 아니다
4. 검증된 체크섬을 `/opt/orca/VERSION` 옆에 기록해 두면 6.6 의 드리프트 검사에서 재사용할 수 있다

---

## 5. 운영 모니터링

### 5.1 서비스 장애 알림 없음 (Critical)

**위치:** `terraform/main.tf`, `scripts/install/04-orca-server.sh`  
**현상:** `orca-serve.service`가 재시작 한도(5회/5분) 초과 후 `failed` 상태가 되어도 아무 알림이 없다. 관리자가 직접 접속해 확인하기 전까지 장애를 알 수 없다.

**위험:**
- 서비스가 며칠간 다운된 상태로 유지될 수 있음
- OOM에 의한 kill 이후 재시작 한도 소진 시 침묵

**개선 방향 (단기, 최소 비용):**
1. **systemd OnFailure 훅**: `orca-serve.service`에 `OnFailure=notify-orca-fail.service` 추가, 실패 시 이메일/Slack 웹훅 전송 스크립트 실행
2. **AWS CloudWatch**: Lightsail 인스턴스 상태 확인 알람 → SNS → 이메일 (무료 티어 범위)
3. **간단한 외부 핑**: 무료 UptimeRobot 등으로 Tailscale Serve HTTPS 엔드포인트 정기 확인 (단, tailnet 외부 접근 불가이므로 내부 핑 스크립트 + cron 조합)

**cron 기반 내부 감시 예시 (즉시 적용 가능):**
```bash
# /etc/cron.d/orca-watch
*/5 * * * * root systemctl is-active --quiet orca-serve || \
  curl -s -X POST "$ALERT_WEBHOOK" -d '{"text":"orca-serve FAILED on '"$(hostname)"'"}'
```

---

### 5.2 디스크 공간 모니터링 없음 (High)

**위치:** `scripts/util/verify-host.sh` — 일회성 80% 경고만 있음  
**현상:** Orca 워크스페이스, 저장소 클론, 빌드 아티팩트가 쌓이면 디스크가 조용히 가득 찬다. Orca AppImage 로그도 별도 로테이션 없이 저장된다.

**위험:**
- 디스크 꽉 참 → Orca 서비스 크래시 → 데이터 손상 가능성

**개선 방향:**
1. cron 또는 systemd timer로 디스크 80% 초과 시 알림 발송
2. `journalctl` 보존 크기 제한: `/etc/systemd/journald.conf`에 `SystemMaxUse=500M` 설정
3. `/home/orca/workspace` 용량 증가 추적 스크립트

---

### 5.3 메모리 부족(OOM) 전조 감지 없음 (High)

**위치:** README.md, `docs/lightsail-plan.md` — 4GB 한계 언급만 있음  
**현상:** `free -h` 수동 확인 외에 메모리 압박 자동 감지 수단이 없다.

**위험:**
- OOM killer가 orca 프로세스를 종료하는 반복 패턴이 로그에만 남고 알림 없음
- swap 지속 사용은 성능 저하와 데이터 장애의 전조

**개선 방향:**
1. **먼저 제어를 건다** — `orca-serve.service` 에 `MemoryHigh=` / `MemoryMax=` / `OOMPolicy=stop`
   을 설정한다 (6.4 참조). 커널 OOM killer 가 임의의 프로세스를 고르게 두는 대신, 한도를
   초과한 서비스만 예측 가능하게 멈추게 하는 것이 먼저다. 아래 2~4 는 그 다음이다
2. `sar` (sysstat 패키지) 설치 및 15분 단위 메모리·swap 통계 수집
3. swap 사용률 70% 초과 시 알림 발송 스크립트 (cron)
4. OOM kill 발생 시 즉시 감지: `dmesg` + `journalctl -k` 패턴 감시

---

## 6. 보안

### 6.0 신뢰경계와 공격 경로

개별 항목에 앞서 이 호스트의 신뢰경계를 고정한다. 아래 항목들의 심각도는 이 경계를 기준으로
매긴 것이다.

```text
[외부 입력]
 └─ GitHub 저장소 콘텐츠 (포크 포함 — 제3자가 작성한 코드)
      │ 05-repos.sh 가 /home/orca/workspace 로 클론하고 Orca 에 등록한다
      ▼
[orca 계정]  ← 에이전트(Orca·Claude Code·Codex)가 이 콘텐츠를 읽고 명령을 실행한다
      │ ORCA_SERVICE_SUDO=nopasswd (기본값) → 비밀번호 없이 root
      ▼
[호스트 전체 / root]
      ├─ /srv/<입주앱>/.env         — 입주 앱 시크릿
      ├─ /home/orca/.codex, gh 토큰 — 에이전트 자격증명
      └─ Tailscale 노드 키, sudoers, systemd 유닛
```

핵심은 **경계가 실질적으로 하나뿐**이라는 점이다. `orca` 계정은 격리 계층이 아니라 root 의
별칭에 가깝다. 따라서 `orca` 계정에 도달하는 모든 경로는 그대로 호스트 전체 침해 경로다.

| # | 공격 경로 | 진입점 | 귀결 |
|---|---|---|---|
| A | 포크·외부 저장소 콘텐츠 → 에이전트가 읽고 명령 실행 → 무암호 sudo | `05-repos.sh:21-22`, `:63` | 호스트 root, 입주 앱 시크릿 |
| B | `ubuntu` SSH 키 탈취 → 같은 키로 `orca` 로그인 → 무암호 sudo | `06-vscode-remote.sh:51-77` | 호스트 root |
| C | Orca 페어링 URL 유출 → tailnet 안에서 Web Client 장악 | `util/show-orca-access.sh` | 에이전트 세션 탈취 |
| D | 공급망 — 변조된 Orca 바이너리 (체크섬 미검증) | `04-orca-server.sh:164-188` | 호스트 root |

A 와 B 는 모두 6.1 때문에 "계정 침해"에서 멈추지 않고 "호스트 침해"로 끝난다. 6.1 을 먼저
읽는다.

---

### 6.1 서비스 계정의 무암호 root 권한 (Critical)

**위치:** `scripts/util/lib.sh:35` — `ORCA_SERVICE_SUDO="${ORCA_SERVICE_SUDO:-nopasswd}"`
`scripts/install/04-orca-server.sh:99-156` — 특히 `:126` `$ORCA_SERVICE_USER ALL=(ALL) NOPASSWD:ALL`

**현상:** 기본값이 `nopasswd` 다. `orca` 계정은 비밀번호 없이 임의 명령을 root 로 실행한다.
이 계정은 동시에 (a) 자율 코딩 에이전트의 실행 계정이고, (b) VS Code Remote-SSH 접속
계정이며, (c) 입주 앱과 호스트를 공유한다.

**이것은 사고가 아니라 의식적 선택이다.** `config.example.env` 와 `lib.sh` 주석이 트레이드오프를
이미 명시하고 있다 — headless 에이전트는 sudo 비밀번호를 입력할 방법이 없다. 이 항목의 목적은
그 결정을 뒤집는 것이 아니라 **수용한 잔여 위험을 문서로 고정하고 보완 통제를 두는 것**이다.

**위험:**
- 6.0 의 경로 A·B 가 계정 침해에서 호스트 전면 침해로 격상된다
- `/srv/<앱>/.env` 를 포함한 입주 앱 시크릿 전체가 에이전트의 사정거리에 들어온다
- 침해가 아니어도 문제다 — 에이전트의 오작동(잘못된 `rm`, 잘못된 `systemctl`)이 root 로 실행된다
- 사후 추적 수단이 없다. 누가·무엇을 root 로 실행했는지 남지 않는다 (6.6 참조)

**개선 방향:**
1. **안전한 기본값으로 전환** — `lib.sh:35` 의 기본을 `off` 로 두고 필요한 쪽이 `config.env` 에서
   명시적으로 켜게 한다. 현행은 모르고 설치하면 무암호 root 다.
2. **전면 허용 대신 명령 화이트리스트** — 에이전트에게 실제로 필요한 것은 자기 유닛 재시작과
   패키지 설치 정도다. `NOPASSWD:ALL` 대신 sudoers 에 명령을 열거한다.
   ```
   # /etc/sudoers.d/60-orca-sudo (예시 — 실제 필요 명령으로 조정)
   orca ALL=(ALL) NOPASSWD: /usr/bin/systemctl restart orca-serve, \
                            /usr/bin/systemctl status orca-serve, \
                            /usr/bin/apt-get install *
   ```
3. **sudo I/O 로깅** — `Defaults log_output` 을 켜 root 실행 내역을 남긴다. `sudoreplay` 로
   재생 가능하다. 화이트리스트를 당장 못 하더라도 이것만은 먼저 켠다.
4. **입주 앱 시크릿 격리** — `/srv/<앱>/.env` 를 `0640 root:<앱그룹>` 으로 두더라도 sudo 가
   전면 허용인 한 무의미하다. 2번과 함께 가야 실효가 생긴다.

---

### 6.2 에이전트 런타임의 신뢰경계 미설정 (Critical)

**위치:** `scripts/install/05-repos.sh:21-22`, `:30`, `:63`

**현상:** `REPOS=all` 이 기본이고, 스크립트 주석이 밝히듯 열거 범위에 **포크와 보관된 저장소가
포함된다.** 포크는 제3자가 작성한 코드다. 이것들이 `/home/orca/workspace` 로 클론되고
`orca repo add` 로 Orca 에 등록되어 에이전트의 작업 대상이 된다.

**위험:**
- 저장소 안의 `README.md`, 이슈 템플릿, 설정 파일, 빌드 스크립트에 심긴 지시문이 그대로
  에이전트의 입력이 된다 (간접 프롬프트 인젝션)
- 에이전트가 그 지시를 따라 명령을 실행하면 6.1 에 의해 root 다
- 콘텐츠를 읽지 않아도 경로는 열려 있다 — 의존성 설치(`npm install`) 한 번이 임의 코드 실행이다
- 신뢰경계를 "저장소 목록"으로 정의할 수 없다. 목록이 GitHub 계정 상태에 따라 자동으로 바뀐다

**개선 방향:**
1. **`REPOS=all` 을 기본에서 뺀다.** 실제 작업 대상만 명시적으로 열거한다
   (`REPOS="gong-go homepage"`). 신뢰경계를 사람이 선언하게 만드는 것이 요점이다.
2. `all` 을 유지해야 하면 열거 단계에서 포크를 배제한다 — `gh repo list` 에 `--source`
   (포크가 아닌 것만) 와 `--no-archived` 를 붙인다.
3. **에이전트의 명령 자동 승인 정책을 확인한다.** 자동 승인이 켜져 있으면 1·2 를 해도 방어선이
   하나 줄어든다. 이 값은 코드가 아니라 Orca·Claude Code·Codex 각각의 설정에 있다.
4. 신뢰할 수 없는 저장소를 반드시 다뤄야 하면 별도 비특권 계정이나 컨테이너로 분리한다.

---

### 6.3 VS Code Remote-SSH 와 ubuntu 계정 동일 SSH 키 (Critical)

> 초판에서 High 로 분류했으나 6.1 을 반영해 Critical 로 상향한다. 영향 범위가
> "워크스페이스와 에이전트 자격증명"이 아니라 "호스트 전체 root" 이기 때문이다.

**위치:** `scripts/install/06-vscode-remote.sh:51-77` — `ubuntu` 의 `authorized_keys` 를 `orca` 에 복사

**현상:** 관리 PC 가 이미 `ubuntu` 로 접속하므로 같은 Lightsail 키페어를 그대로 쓴다.
`ubuntu` 계정이 침해되면 `orca` 도 자동으로 열리고, `orca` 는 무암호 root 다.

**위험:**
- 키 하나가 두 계정을 동시에 연다. 계정 분리가 형식적으로만 존재한다
- 6.0 의 경로 B — 키 탈취 한 번으로 호스트 root, 입주 앱 시크릿까지 간다
- 키 교체 시 두 계정을 모두 갱신해야 하는데 절차가 없어 한쪽만 바뀔 수 있다

**개선 방향:**
1. VS Code 전용 ED25519 키페어를 새로 만들어 `orca` 에만 등록한다
2. `06-vscode-remote.sh` 의 복사 로직을 제거하고 두 계정의 `authorized_keys` 를 분리 유지한다
3. `verify-host.sh` 에 두 계정의 `authorized_keys` 가 **겹치지 않는지** 검사하는 항목을 추가한다
   (현행은 `orca` 쪽이 비어 있지 않은지만 본다)
4. 키 교체 절차를 `docs/lightsail-plan.md` 에 명문화한다

---

### 6.4 orca-serve 유닛 하드닝 부재 (High)

**위치:** `scripts/install/04-orca-server.sh:210-238` — `orca-serve.service` 유닛 정의

**현상:** 유닛에 `PrivateTmp=true` 하나만 있다. systemd 가 제공하는 나머지 샌드박스 지시어가
전부 비어 있다.

**위험:**
- 서비스가 침해되면 호스트 파일시스템 전체가 그대로 보인다
- 권한 상승을 막는 `NoNewPrivileges` 가 없어, 서비스에서 출발한 공격이 6.1 의 sudo 로 이어진다
- 메모리 상한이 없어 OOM 으로 이어진다 (5.3 과 같은 뿌리다)

**개선 방향:** `[Service]` 섹션에 아래를 추가한다. 에이전트가 호스트를 관리해야 하는 설계라
`ProtectSystem=strict` 까지는 어려울 수 있으므로 단계적으로 조인다.
```ini
NoNewPrivileges=true          # 6.1 화이트리스트 적용 후에 켠다 — sudo 경로와 충돌한다
ProtectSystem=full
ProtectHome=read-only         # /home/orca 는 ReadWritePaths 로 예외 처리
ReadWritePaths=/home/orca /opt/orca
PrivateDevices=true
RestrictSUIDSGID=true
ProtectKernelTunables=true
ProtectControlGroups=true
MemoryHigh=2G                 # 5.3 — 감시가 아니라 제어
MemoryMax=2800M
OOMPolicy=stop
```
> `NoNewPrivileges=true` 는 6.1 의 sudo 경로를 막는다. 에이전트가 sudo 를 쓰는 현행 설계에서는
> 6.1 의 화이트리스트를 먼저 적용한 뒤에 켤 것. 순서를 지키지 않으면 서비스가 아니라 운영이 막힌다.

---

### 6.5 아웃바운드 트래픽 무제한 (High)

**위치:** `scripts/install/04-orca-server.sh:204` — `sudo ufw default allow outgoing`

**현상:** 인바운드는 SSH 만 허용해 잘 조여 놓았으나 아웃바운드는 전면 개방이다.

**위험:**
- 자격증명(gh 토큰, `~/.codex`, 입주 앱 `.env`)을 쥔 호스트에서 데이터 반출 경로가 무제한이다
- 6.2 의 경로로 실행된 코드가 외부와 자유롭게 통신할 수 있다
- 인바운드 통제는 침입을 막지만, 반출은 아웃바운드에서만 막힌다

**개선 방향:**
1. 전면 차단은 현실적이지 않다 (npm, GitHub, nodesource, Tailscale, AWS 가 전부 아웃바운드다).
   대신 **반출 탐지**를 먼저 둔다 — `ufw logging on` + 목적지 기준 이상 트래픽 확인
2. 최소한 알려진 대용량 업로드 경로에 대한 rate limit 또는 로깅을 검토한다
3. 장기적으로 egress 프록시를 두고 허용 도메인 목록을 관리한다. 비용·운영 부담이 있으므로
   6.1·6.2 를 먼저 처리한 다음 판단한다

---

### 6.6 보안 이벤트 탐지·감사 계층 부재 (High)

**위치:** 저장소 전반 — 해당 코드가 없다

**현상:** 5절이 제안하는 알림은 전부 **가용성** 알림이다 (서비스 다운, 디스크 참, OOM).
보안 이벤트를 남기거나 알리는 장치가 하나도 없다.

**위험:**
- 6.0 의 경로 A~D 중 무엇이 실행되어도 흔적이 남지 않는다
- 침해 사실을 모르는 것보다, 침해 후 **범위를 특정할 수 없는 것**이 복구를 더 어렵게 만든다
- 7.1 의 백업이 있어도 "어느 시점부터 오염됐는지" 모르면 복원 지점을 고를 수 없다

**개선 방향:**
1. **sudo I/O 로깅** (6.1-3 과 동일 항목) — 우선순위 최상. root 실행 내역이 최소선이다
2. **auditd** 설치 후 최소 규칙: `/etc/sudoers.d/`, `/home/orca/.ssh/authorized_keys`,
   `/opt/orca/orca-linux.AppImage`, `/etc/systemd/system/` 변경 감시
3. **SSH 로그인 알림** — `ubuntu`·`orca` 로그인 성공 시 웹훅 발송 (5.1 의 알림 경로 재사용)
4. **`verify-host.sh` 에 드리프트 검사 추가** — sudoers 드롭인 내용, `authorized_keys` 해시,
   Orca 바이너리 체크섬을 기준값과 비교한다. 이미 있는 점검 스크립트를 재사용하는 것이
   가장 저렴하다

---

### 6.7 GitHub 토큰 만료·유효성 미검사 (Medium)

**위치:** `scripts/install/05-repos.sh`, `scripts/util/verify-host.sh`

**현상:** `gh auth status` 로 토큰 존재만 확인하며 만료·revoke 여부를 주기적으로 감지하지 않는다.

**위험:**
- 토큰 만료 후 에이전트가 코드 푸시에 실패한다 — 에이전트만 알고 운영자는 모를 수 있다
- `repo` 전체 스코프 토큰이 호스트에 상주한다. 6.0 의 어느 경로로든 호스트가 뚫리면
  이 토큰으로 **모든 프라이빗 저장소**에 접근·푸시가 가능하다

**개선 방향:**
1. `verify-host.sh` 에 실제 API 호출 검사를 추가한다 (존재 확인이 아니라 유효성 확인)
2. 주 1회 cron 으로 토큰 유효성 확인 및 만료 예정 알림
3. **Fine-grained PAT 로 전환하고 대상 저장소를 한정한다.** 6.2 에서 `REPOS` 를 명시 목록으로
   좁히면 토큰 스코프도 같이 좁힐 수 있다 — 두 항목은 함께 처리하는 것이 효율적이다

---

### 6.8 Orca 페어링 URL 보관 절차 미정의 (Medium)

**위치:** `docs/lightsail-plan.md` 5절, `scripts/util/show-orca-access.sh`

**현상:** URL 을 "비밀번호처럼 취급"하라고 명시하나 실제 보관 위치·접근 제어 방법은 없다.

**위험:**
- 클립보드, 채팅 히스토리, 스크린샷에 노출될 수 있다
- URL 탈취 시 tailnet 안에서 에이전트 세션을 장악할 수 있다 (6.0 경로 C)

**개선 방향:**
1. 1Password/Bitwarden 등 비밀번호 관리자에 저장하는 절차를 문서화한다
2. 페어링 URL 재발급 방법(`systemctl restart orca-serve`)을 문서화한다
3. 브라우저 캐시 클리어 시 재발급이 필요함을 README 에 명시한다

---

### 6.9 Orca 서비스 계정 비밀번호 (Low — 재평가)

**위치:** `scripts/install/04-orca-server.sh`, `scripts/config.example.env`, `lib.sh:28`

**현상:** `ORCA_SERVICE_PASSWORD` 가 설정되면 `su - orca` 경로가 열린다.

> **초판의 판단을 정정한다.** 초판은 이 항목을 "같은 호스트의 다른 계정에서 brute force 가능"
> 으로 서술했다. 그러나 6.1 에 의해 `orca` 는 이미 무암호 root 이므로, 비밀번호 강도는
> 부차적인 방어선이다. **이 항목을 강화해도 6.1 을 처리하지 않으면 실익이 거의 없다.**
> 반대로 6.1 을 화이트리스트로 좁히면 이 항목의 중요도가 상대적으로 올라간다.

**개선 방향:**
1. 6.1 을 먼저 처리한다. 그 다음 이 항목을 재평가한다
2. 비밀번호를 쓴다면 `04-orca-server.sh` 에 최소 길이·복잡도 검증을 추가한다
3. `config.example.env` 에 안전한 생성 명령 예시를 넣는다 (`openssl rand -base64 32`)
4. `/etc/security/access.conf` 로 `su` 경로 자체를 제한하는 것도 검토한다

---

## 7. 백업과 복구

### 7.1 Orca 상태·자격증명 백업 자동화 없음 (High)

**위치:** `docs/lightsail-plan.md` 섹션 7 — 수동 절차만 있음  
**현상:** Orca 프로필(`/home/orca/.config/orca`, `.config/Orca`, `.codex`)은 Lightsail 스냅샷에 포함되나 스냅샷 외 오프사이트 백업이 없다.

**위험:**
- 리전 장애 또는 계정 문제 시 스냅샷도 접근 불가
- 인스턴스 교체 시 자격증명 재발급 및 재인증 필요 (codex, gh)

**개선 방향:**
> **주의 — 이 조치는 노출면을 넓힌다.** `/home/orca/.codex` 와 gh 토큰은 자격증명이다.
> 이것을 S3 로 복사하면 자격증명의 사본이 하나 더 생기고, 그 버킷이 새로운 침해 대상이 된다.
> 아래 1~2 를 적용할 때 3 을 함께 적용하지 않으면 복구 가능성을 얻는 대신 공격면을 사는 셈이다.

1. 주 1회 cron으로 `/home/orca/.config/orca`, `/home/orca/.codex`, `/home/orca/workspace` (git remote가 있는 항목은 제외) 를 S3 암호화 버킷에 업로드
2. `scripts/util/backup-orca.sh` 스크립트 추가
3. **버킷 통제를 함께 건다** — SSE-KMS(고객 관리 키), 키 정책에서 복호화 주체를 관리자
   principal 로 한정, 버킷 정책에서 인스턴스 역할에 `PutObject` 만 허용하고 `GetObject` 는 제외
   (백업은 쓰되 읽지 못하게 한다), 버저닝 + Object Lock 으로 랜섬웨어 대비.
   **대안:** 자격증명은 백업하지 않고 재발급 절차만 문서화하는 선택도 유효하다.
   `codex login` 과 `gh auth login` 은 몇 분이면 끝난다 — 복구 시간과 노출면을 저울질해
   결정한다
3. 복구 절차를 `docs/lightsail-plan.md` 섹션 8에 명시 (스냅샷 복원 vs 새 인스턴스 + 자격증명 재등록)

---

### 7.2 복구 절차 미검증 (High)

**위치:** `docs/lightsail-plan.md` 섹션 8  
**현상:** 장애 복구 시나리오표가 있으나 실제 스냅샷 복원→재가동 절차가 검증된 적 없다.

**위험:**
- 실제 장애 시 처음 복구를 시도하면 예상치 못한 단계에서 막힐 수 있음

**개선 방향:**
1. 분기 1회 복구 드릴: 테스트 인스턴스에 스냅샷 복원 후 `verify-host.sh` 통과 여부 확인
2. 복구 체크리스트 문서화 (아래 섹션 10 참조)
3. 스냅샷 복원 후 Tailscale 재인증 필요 여부 확인 및 문서화

---

## 8. 운영 편의성

### 8.1 Orca 버전 업데이트 절차 반자동화 (Medium)

**위치:** `docs/lightsail-plan.md` 섹션 7, `scripts/config.example.env`  
**현상:** `ORCA_VERSION`을 수동으로 변경 후 `04-orca-server.sh` 재실행이 필요하다. 최신 버전 확인 방법이 없다.

**개선 방향:**
1. `scripts/util/check-orca-update.sh` 추가: GitHub Releases API로 최신 버전 조회 후 현재 버전과 비교
2. 주 1회 cron으로 실행, 새 버전 있으면 알림
3. 업그레이드 전 자동 스냅샷 트리거 (`aws lightsail create-instance-snapshot`)

---

### 8.2 관리자 IP 변경 시 재적용 자동화 (Low)

**위치:** `terraform/variables.tf`, `terraform/firewall.tf`  
**현상:** 관리자 IP가 변경되면 수동으로 `terraform apply`를 실행해야 한다.

**개선 방향:**
1. `scripts/util/update-admin-ip.sh` 추가: 현재 공인 IP를 감지하고 `terraform.tfvars`의 `my_ip` 갱신 후 `terraform apply -auto-approve` 실행
2. Tailscale SSH 경로를 확보해두면 공인 IP 변경 시에도 긴급 접속 가능 (근본 해결)

---

## 9. 개선 우선순위 요약

> **상태(2026-09-19):** 아래 항목은 전부 저장소 코드로 반영됐다. 무엇이 어디에 들어갔고
> 무엇을 계획과 다르게 했는지는 **13절**에 있다. 단, 코드가 선언하는 상태가 바뀌었을 뿐
> 서버에는 아직 적용되지 않았다 (13.4 의 순서로 사람이 실행한다).

| 우선순위 | 항목 | 절 | 난이도 | 효과 |
|---|---|---|---|---|
| **P0** | **`REPOS=all` 에서 포크 배제 / 대상 저장소 명시** | 6.2 | **낮음** | **신뢰경계 확보 — 경로 A 차단** |
| **P0** | **sudo I/O 로깅 활성화** | 6.1, 6.6 | **낮음** | **root 실행 추적 가능** |
| P0 | 서비스 장애 알림 설정 (systemd OnFailure + cron 핑) | 5.1 | 낮음 | 침묵 장애 감지 |
| P0 | 디스크 꽉 참 자동 감지·알림 | 5.2 | 낮음 | 서비스 크래시 방지 |
| **P1** | **sudo 명령 화이트리스트 (`NOPASSWD:ALL` 제거)** | 6.1 | **중간** | **경로 A·B 의 귀결을 root 에서 분리** |
| **P1** | **VS Code SSH 키 분리** (초판 P2 에서 상향) | 6.3 | 중간 | 경로 B 차단 |
| **P1** | **`orca-serve` 유닛 하드닝 + `MemoryMax`** | 6.4, 5.3 | **낮음** | 침해 범위 축소 + OOM 제어 |
| P1 | Orca 자격증명 오프사이트 백업 스크립트 (+ KMS 통제) | 7.1 | 중간 | 복구 가능성 확보 |
| P1 | Terraform remote backend (S3) | 3.1 | 중간 | state 손실 방지 |
| P1 | Orca 바이너리 체크섬 검증 추가 | 4.3 | 낮음 | 공급망 공격 방어 — 경로 D |
| **P2** | **`verify-host.sh` 드리프트 검사 (sudoers·키·체크섬)** | 6.6 | 낮음 | 기존 스크립트 재사용, 변조 감지 |
| **P2** | **SSH 로그인 알림 / auditd 최소 규칙** | 6.6 | 중간 | 침해 범위 특정 |
| P2 | 외부 서비스 호출 재시도 로직 (`lib.sh` retry 헬퍼) | 4.1 | 중간 | 배포 안정성 |
| P2 | GitHub 토큰 Fine-grained 전환 + 만료 감지 | 6.7 | 낮음 | 토큰 반경 축소 |
| P3 | 복구 드릴 및 절차 검증 | 7.2 | 낮음 | 복구 신뢰성 |
| P3 | 아웃바운드 로깅 / egress 프록시 검토 | 6.5 | 높음 | 반출 탐지 |
| P3 | Orca 버전 자동 확인 스크립트 | 8.1 | 낮음 | 운영 편의성 |

**P0 선정 근거:** 위 두 항목은 **난이도가 낮으면서 6.0 의 공격 경로 A 를 직접 끊거나 추적
가능하게 만든다.** `REPOS` 목록 수정은 설정 한 줄이고, sudo 로깅은 sudoers 한 줄이다.
반면 sudo 화이트리스트(P1)는 에이전트가 실제로 쓰는 명령을 관찰해야 하므로 시간이 걸린다.
**먼저 끊고, 그 다음 조인다.**

---

## 10. 복구 체크리스트 (초안)

서비스 복구 시 다음 순서를 따른다.

> **상태(2026-09-19):** 이 체크리스트는 `docs/lightsail-plan.md` 8.1 로 옮겨 운영 문서에
> 합쳤고, 분기 드릴 절차를 8.2 에 추가했다. **드릴 자체는 아직 실행하지 않았다** (13.3).

### 10.1 orca-serve.service 장애

```bash
# 상태 확인
sudo systemctl status orca-serve --no-pager
sudo journalctl -u orca-serve -n 100 --no-pager

# 재시작 시도
sudo systemctl restart orca-serve
sleep 10
sudo journalctl -u orca-serve -n 30 --no-pager | grep orca_server_ready

# 여전히 실패 시 Tailscale Serve 확인
sudo tailscale serve status

# 전체 점검
cd ~/remote-lightsail-scripts
./util/verify-host.sh
sudo ./util/diagnose-web-client.sh
```

### 10.2 Tailscale 연결 장애

```bash
tailscale status
sudo systemctl restart tailscaled
sleep 5
tailscale ip -4  # 100.x.x.x 확인

# Serve 재설정 필요 시
sudo tailscale serve reset
# 04-orca-server.sh 재실행
```

### 10.3 인스턴스 복구 (스냅샷에서 재생성)

1. AWS Lightsail 콘솔에서 최신 스냅샷 확인
2. 스냅샷으로 새 인스턴스 생성 (동일 번들 권장)
3. 고정 IP를 새 인스턴스에 재연결 (기존 IP 재사용 가능)
4. SSH 접속 확인: `ssh ubuntu@<static_ip>`
5. Tailscale 재인증 여부 확인: `tailscale status`
   - 필요 시 `sudo tailscale up` 후 브라우저 인증
6. orca-serve.service 상태 확인
7. `verify-host.sh` 통과 여부 확인
8. Codex/GitHub 자격증명 유효성 재확인
9. 페어링 URL 재발급: `sudo ./util/show-orca-access.sh`

### 10.4 OOM 반복 발생 시

```bash
# OOM kill 기록 확인
sudo dmesg | grep -i 'killed process'
sudo journalctl -k | grep -i oom

# 즉시 조치: 동시 에이전트 세션 수 축소

# 근본 조치: 번들 업그레이드
# 1. Lightsail 스냅샷 생성
# 2. terraform.tfvars의 bundle_id를 large_3_0으로 변경
# 3. terraform apply (인스턴스 재생성 필요 - 중단 발생)
# 4. 고정 IP 재연결
# 5. verify-host.sh 확인
```

---

## 11. 단기 적용 가능 최소 조치

현재 코드를 크게 변경하지 않고 즉시 적용할 수 있는 항목이다.

> **상태(2026-09-19):** 아래는 전부 반영됐으나 **cron 대신 systemd timer 로** 넣었다
> (`install/01-host-base.sh`, `install/07-monitoring.sh`). 이유는 13.2 참조.

### 11.1 journald 로그 크기 제한

```bash
# /etc/systemd/journald.conf.d/limit.conf
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=100M
```

### 11.2 orca-serve 장애 감지 cron

```bash
# /etc/cron.d/orca-watch (관리자가 서버에서 직접 설정)
*/5 * * * * root \
  systemctl is-active --quiet orca-serve || \
  echo "$(date): orca-serve FAILED" >> /var/log/orca-fail.log
```

웹훅 URL이 있으면 `curl` 알림으로 확장한다.

### 11.3 디스크 공간 cron

```bash
# /etc/cron.d/disk-watch
0 * * * * root \
  df --output=pcent / | grep -oP '\d+' | \
  awk '$1>=80 {print "$(date): disk "$1"% full"}' >> /var/log/disk-warn.log
```

### 11.4 swap 비활성화 감지

`verify-host.sh`는 이미 swap 확인 항목을 포함하므로, 이를 주기적으로 실행하는 systemd timer 추가:

```bash
# /etc/systemd/system/verify-host.timer
[Timer]
OnCalendar=daily
Persistent=true
```

---

## 12. 개정 내역 (2판 — 2026-09-19)

초판(2026-08-24)은 현행 코드를 정확히 읽고 작성됐다. 검증 가능한 주장 8건 중 7건이 정확했고,
특히 4.1 의 재시도 갭 목록에서 이미 `curl --retry 3` 이 적용된 `04-orca-server.sh` 를 정확히
제외한 점은 실제 코드 대조 없이는 나올 수 없는 정확도다.

2판은 초판을 대체하지 않고 **보안 관점을 보강**한다. 초판의 제목과 범위가 "안정적 서비스 운영"
이었던 만큼 6절은 위생 점검 수준에 머물렀고, 구조적 위협 분석이 빠져 있었다.

### 12.1 정정

| 위치 | 초판 | 2판 |
|---|---|---|
| 4.3 | 바이너리 검증부를 `lines 107-130` 으로 인용 | 실제는 `:164-188`. `107-130` 은 sudo 권한 블록이다 |
| 6.3 (초판 6.1) | SSH 키 재사용을 **High**, 영향은 "워크스페이스와 자격증명" | **Critical**. 6.1 에 의해 실제 귀결은 호스트 전체 root |
| 6.9 (초판 6.4) | `su - orca` brute force 를 위험으로 서술 | 6.1 이 이미 무암호 root 이므로 부차적. 6.1 처리 전에는 실익 없음 |
| 7.1 | 자격증명 S3 백업을 조건 없이 권고 | 노출면 확대 조치임을 명시하고 KMS·버킷 통제를 필수 동반 항목으로 추가 |
| 3.1 | 잠금에 DynamoDB 테이블 필수로 서술 | Terraform 1.10+ 는 S3 네이티브 `use_lockfile` 로 대체 가능 |

### 12.2 신규 항목

| 절 | 항목 | 심각도 | 초판에 없던 이유(추정) |
|---|---|---|---|
| 6.0 | 신뢰경계와 공격 경로 | — | 항목별 점검은 있었으나 경로를 잇는 관점이 없었다 |
| 6.1 | 서비스 계정의 무암호 root 권한 | Critical | `ORCA_SERVICE_SUDO=nopasswd` 가 기본값임을 다루지 않았다 |
| 6.2 | 에이전트 런타임의 신뢰경계 미설정 | Critical | `REPOS=all` 이 포크를 포함한다는 점이 위험으로 연결되지 않았다 |
| 6.4 | `orca-serve` 유닛 하드닝 부재 | High | 5.3 에서 OOM 을 다뤘으나 해법이 감시에 머물렀다 |
| 6.5 | 아웃바운드 트래픽 무제한 | High | 인바운드 통제만 검토됐다 |
| 6.6 | 보안 이벤트 탐지·감사 계층 부재 | High | 5절의 알림이 전부 가용성 알림이었다 |

### 12.3 2판이 다루지 않은 것

- **실제 적용은 하지 않았다.** 2판은 계획이며 코드 변경을 포함하지 않았다.
  → 13절 참조. 2026-09-19 에 저장소 코드로 반영했다.
- **에이전트 자동 승인 설정을 확인하지 못했다.** Orca·Claude Code·Codex 각각의 승인 정책은
  저장소 코드가 아니라 각 도구의 런타임 설정에 있다 (6.2-3). 서버에서 직접 확인이 필요하다.
  → 여전히 미확인. 13.3 참조.
- **복구 드릴은 여전히 미검증이다** (7.2). 2판도 이 항목의 상태를 바꾸지 못했다.
  → 절차는 `docs/lightsail-plan.md` 8.2 로 문서화했으나 **실행은 하지 않았다.** 13.3 참조.

---

## 13. 적용 내역 (2026-09-19)

9절 우선순위표의 항목을 **저장소 코드로** 반영했다. 코드가 선언하는 최종 상태만 바뀌었을 뿐
**서버에는 아직 적용되지 않았다** — 반영하려면 `util/sync-host.sh` 로 스크립트를 보내고
`install/04`·`05`·`06`·`07` 을 다시 돌려야 한다 (13.4).

### 13.1 반영된 항목

| 절 | 항목 | 어디에 |
|---|---|---|
| 3.1 | S3 remote backend (`use_lockfile`, DynamoDB 없음) | `terraform/backend.tf.example`, `versions.tf` 주석, `terraform/README.md`, `.gitignore` |
| 3.2 | `admin_cidrs` 목록 변수, checkip 실패 시 재시도·검증·안내 | `terraform/variables.tf`, `firewall.tf`, `terraform.tfvars.example` |
| 3.3 | 스냅샷 7일 보존·수동 스냅샷 명명 규칙·비용 확인 절차 | `terraform/README.md` "스냅샷 보존과 비용" |
| 4.1 | `retry N CMD` 헬퍼와 적용 (apt, nodesource, npm, gh, git clone/fetch) | `scripts/util/lib.sh`, `install/01`·`02`·`05` |
| 4.2 | 에이전트 CLI 버전 고정·설치됨 감지, 기존 클론은 `git fetch` | `install/02`, `install/05` |
| 4.3 | SHA256 검증(설정값 → 릴리스 체크섬 파일 → 이전 설치와 대조), 최소 크기, `/opt/orca/CHECKSUM` | `install/04` |
| 5.1 | systemd `OnFailure` 훅 + 5분 주기 상태 확인 + 웹훅 알림 경로 | `install/04`(`OnFailure=`), `install/07` |
| 5.2 | 디스크 임계 알림, journald `SystemMaxUse`, workspace 증가 추적 | `install/01`, `install/07` |
| 5.3 | `MemoryHigh`/`MemoryMax`/`OOMPolicy=stop` **먼저**, 그다음 sysstat·스왑·OOM 감시 | `install/04`, `install/07` |
| 6.1 | `whitelist` sudo 모드 신설, sudo I/O 로깅 기본 on | `lib.sh`, `install/04`, `config.example.env` |
| 6.2 | `REPOS=all` 에서 포크·보관 기본 제외(`--source --no-archived`), 명시 목록 권장 | `install/05`, `config.example.env`, README |
| 6.3 | `orca` 전용 SSH 키 필수화, 키 중복 검사, 교체 절차 문서화 | `install/06`, `verify-host.sh`, `docs/lightsail-plan.md` 4.3 |
| 6.4 | 유닛 하드닝 (sudo 정책에 따라 단계적), 메모리 상한 | `install/04` |
| 6.5 | `ufw logging low` — 반출 탐지 | `install/04` |
| 6.6 | auditd 최소 규칙, SSH 로그인 알림, `verify-host.sh` 드리프트 검사 | `install/07`, `install/04`·`06`(기준값), `verify-host.sh` |
| 6.7 | 토큰 유효성 실제 API 호출 + 주간 점검, Fine-grained PAT 안내 | `verify-host.sh`, `install/07`, `config.example.env` |
| 6.8 | 페어링 URL 보관·재발급 절차 | `docs/lightsail-plan.md` 5절 |
| 6.9 | 비밀번호 최소 길이 검증, `openssl rand` 예시 | `install/04`, `config.example.env` |
| 7.1 | `util/backup-orca.sh` (+ KMS·버킷 통제 안내, 자격증명 기본 제외) | `scripts/util/backup-orca.sh` |
| 7.2 | 복구 체크리스트와 분기 드릴 절차 | `docs/lightsail-plan.md` 8.1~8.2 |
| 8.1 | `util/check-orca-update.sh` + 주간 타이머 | `scripts/util/check-orca-update.sh`, `install/07` |
| 8.2 | `util/update-admin-ip.sh` | `scripts/util/update-admin-ip.sh` |
| 11 | journald 한도, 장애·디스크 감시, `verify-host` 정기 실행 — cron 대신 systemd timer | `install/01`, `install/07` |

### 13.2 계획과 다르게 적용한 것

**6.1-1 기본값을 `off` 로 바꾸지 않았다.** 계획은 `lib.sh` 의 `ORCA_SERVICE_SUDO` 기본을
`off` 로 두라고 했으나 `nopasswd` 를 유지했다. 기본값을 바꾸면 모르고 재실행한 호스트에서
에이전트가 sudo 를 잃는다 — 이 저장소의 스크립트는 매 실행 선언 상태로 "맞추기" 때문에
설정을 옮기지 않은 채 `04` 를 돌리면 곧바로 운영이 막힌다. 대신 `whitelist` 모드를 새로
만들어 전면 허용과 전면 차단 사이의 단계를 두었고, sudo I/O 로깅(P0)은 기본 on 이다.
`nopasswd` 로 설치하면 스크립트와 `verify-host.sh` 양쪽이 잔여 위험을 경고로 남긴다.

**6.4 하드닝을 sudo 정책에 묶었다.** 계획의 유닛 지시어를 그대로 넣으면 현행 구성이 깨진다.
`NoNewPrivileges` 는 setuid 를 막아 sudo 경로 자체를 닫고, `ProtectSystem` / `ProtectHome` /
`ProtectKernelTunables` 는 유닛의 마운트 네임스페이스에 걸리므로 그 안에서 `sudo` 로 띄운
자식까지 함께 묶인다 — 에이전트가 `apt` 나 `/etc` 를 건드려야 하는 구성에서는 운영이 막힌다.
그래서 이 계열은 `ORCA_SERVICE_SUDO=off` 일 때만 켜고, 그 외에는 충돌하지 않는 항목
(`RestrictSUIDSGID`, `RestrictRealtime`, `ProtectControlGroups`, 메모리 상한)만 적용한다.
계획 6.4 의 "순서를 지키지 않으면 서비스가 아니라 운영이 막힌다" 를 코드로 강제한 것이다.

**11 절의 cron 을 systemd timer 로 바꿨다.** 계획은 `/etc/cron.d/` 예시를 들었으나 이 호스트는
`HOST_TIMEZONE=UTC` 계약과 입주 앱의 `cron.d` 를 이미 쓰고 있다. 감시 유닛을 timer 로 두면
`Persistent=true` 로 다운타임 중 놓친 실행을 따라잡고, 상태·로그가 저널 한 곳에 모이며,
입주 앱의 cron 과 섞이지 않는다. 결과는 같고 운영 면이 하나 줄어든다.

**3.1 backend 를 파일로 켜지 않았다.** `backend "s3"` 블록을 바로 넣으면 버킷이 없는 상태에서
`terraform init` 이 실패해 현행 로컬 state 운영이 막힌다. `backend.tf.example` 로 두고
`init -migrate-state` 절차를 문서화했다 — 버킷 생성이 사람의 결정이기 때문이다.

### 13.3 이번에도 적용하지 못한 것

- **서버 반영은 하지 않았다.** 코드만 바뀌었다. 13.4 의 순서로 사람이 실행해야 한다.
- **AWS 쪽 자원은 만들지 않았다.** state 버킷(3.1), 백업 버킷과 KMS 키(7.1), Cost Explorer
  예산 알림(3.3)은 계정 안에서 만들어야 하고 비용이 따른다.
- **에이전트 자동 승인 설정은 여전히 미확인이다** (6.2-3). Orca·Claude Code·Codex 의 런타임
  설정이라 이 저장소에서 선언할 수 없다. 서버에서 직접 확인한다.
- **복구 드릴은 미실행이다** (7.2). 절차만 `docs/lightsail-plan.md` 8.2 에 적었다.
  실행해 보기 전까지 검증된 것이 아니다.
- **sudo 화이트리스트의 실제 목록은 추정값이다** (6.1-2). `lib.sh` 의 기본 목록은 자기 유닛
  제어와 `apt-get` 뿐이다. `nopasswd` + I/O 로깅으로 며칠 돌려 `sudoreplay -l` 로 관찰한 뒤
  목록을 확정하고 `whitelist` 로 넘어가는 순서를 권장한다.
- **egress 프록시는 검토하지 않았다** (6.5-3). `ufw logging` 까지만 했다. 계획대로 6.1·6.2 를
  처리한 다음 판단한다.

### 13.4 서버 반영 순서

```bash
# 관리 PC — 새 설정값을 먼저 정한다
#   ORCA_SSH_PUBLIC_KEY   (필수: 없으면 06 이 중단한다)
#   ALERT_WEBHOOK         (비우면 알림이 로컬 로그에만 남는다)
#   REPOS                 (작업 대상만 명시하는 것을 권장)
./scripts/util/sync-host.sh

# 서버 (ubuntu)
cd ~/remote-lightsail-scripts
./install/01-host-base.sh      # journald 한도
./install/04-orca-server.sh    # sudo 로깅, 체크섬, 유닛 하드닝, 기준값
./install/05-repos.sh          # 포크 제외 재열거
./install/06-vscode-remote.sh  # 전용 키 등록
./install/07-monitoring.sh     # 알림·감시·감사
./util/verify-host.sh
```

`04` 를 돌리면 새 SHA256 을 출력한다. `config.env` 의 `ORCA_SHA256` 에 옮겨 적고
`sync-host.sh` 를 한 번 더 돌리면 다음 설치부터 검증된다.

`06` 은 `ORCA_SSH_PUBLIC_KEY` 가 없으면 중단한다. 기존 호스트에서 `ubuntu` 키로 붙어 있었다면
**새 키로 접속되는 것을 확인한 뒤** 옛 키를 지운다 (`docs/lightsail-plan.md` 4.3 "SSH 키 교체").

---

## 참고 문서

- [`docs/lightsail-plan.md`](lightsail-plan.md) — 구축·운영·백업·복구 기준
- [`scripts/util/verify-host.sh`](../scripts/util/verify-host.sh) — 서버 전체 점검 스크립트
- [`scripts/util/diagnose-web-client.sh`](../scripts/util/diagnose-web-client.sh) — Web Client 진단
- [Lightsail Snapshots 요금](https://aws.amazon.com/lightsail/pricing/) — 스냅샷 비용 확인
- [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh) — 공인 IP 없는 SSH 접근 방법

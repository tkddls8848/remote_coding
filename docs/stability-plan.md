# 안정적 서비스 운영을 위한 개선 계획

> 기준일: 2026-08-24  
> 대상: `remote_coding` 저장소 기반 AWS Lightsail + Orca 원격 개발 환경  
> 범위: 현행 코드 분석을 통해 발견된 안정성·보안·운영 갭과 개선 방향

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
1. S3 버킷 + DynamoDB 테이블로 remote backend 구성 (`terraform/versions.tf` `backend "s3"` 블록 추가)
2. DynamoDB `LockTable`로 동시 apply 방지
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

**위치:** `scripts/install/04-orca-server.sh` — 바이너리 다운로드 및 검증 부분 (lines 107-130)  
**현상:** 다운로드 후 ELF 포맷과 아키텍처 문자열 존재만 확인하며 체크섬·서명 검증이 없다.

**위험:**
- 다운로드 중간 오염 또는 CDN 침해 시 변조된 바이너리 실행 가능
- 불완전 다운로드가 ELF 헤더를 보유하는 경우 통과

**개선 방향:**
1. Orca GitHub Releases에서 함께 제공되는 SHA256 체크섬 파일 다운로드 및 검증 (`sha256sum -c`)
2. 파일 크기 최소값 검증 (예: 50MB 미만이면 불완전 다운로드로 간주 거부)
3. 체크섬 불일치 시 `.previous` 백업에서 자동 롤백

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
1. `sar` (sysstat 패키지) 설치 및 15분 단위 메모리·swap 통계 수집
2. swap 사용률 70% 초과 시 알림 발송 스크립트 (cron)
3. OOM kill 발생 시 즉시 감지: `dmesg` + `journalctl -k` 패턴 감시

---

## 6. 보안

### 6.1 VS Code Remote-SSH와 ubuntu 계정 동일 SSH 키 (High)

**위치:** `scripts/install/06-vscode-remote.sh` — `ubuntu`의 `authorized_keys`를 `orca`에 복사  
**현상:** `ubuntu` 계정 침해 시 `orca` 계정도 자동으로 접근 가능해진다.

**위험:**
- 공격자가 ubuntu 키를 얻으면 orca 워크스페이스와 코드 에이전트 자격증명까지 접근
- 키 교체 시 두 계정 모두 갱신해야 하나 단계가 없어 한 곳만 교체될 위험

**개선 방향:**
1. VS Code 전용 별도 ED25519 키페어 생성 및 `orca` 계정에만 등록
2. `ubuntu`와 `orca`의 `authorized_keys`를 분리 유지하고 `06-vscode-remote.sh` 로직 수정
3. `verify-host.sh`에 두 계정의 authorized_keys 불일치 여부 검사 추가

---

### 6.2 GitHub 토큰 만료·유효성 미검사 (Medium)

**위치:** `scripts/install/05-repos.sh`, `scripts/util/verify-host.sh`  
**현상:** `gh auth status`로 토큰 존재만 확인하며 만료·revoke 여부를 주기적으로 감지하지 않는다.

**위험:**
- 토큰 만료 후 에이전트가 코드 푸시 실패 — 에이전트만 알고 운영자는 모를 수 있음

**개선 방향:**
1. `verify-host.sh`에 `gh auth token | gh api user --input -` 형태로 실제 API 호출 추가
2. 주 1회 cron으로 토큰 유효성 확인 및 만료 예정 알림
3. Fine-grained PAT (최소 권한) 사용 권장 — `repo` 전체 scope 대신 필요한 저장소만

---

### 6.3 Orca 페어링 URL 보관 절차 미정의 (Medium)

**위치:** `docs/lightsail-plan.md` 섹션 5, `scripts/util/show-orca-access.sh`  
**현상:** URL을 "비밀번호처럼 취급"하라고 명시하나 실제 보관 위치·접근 제어 방법은 없다.

**위험:**
- 클립보드, 채팅 히스토리, 스크린샷에 노출 가능
- URL 탈취 시 서버 제어권 위임 가능

**개선 방향:**
1. 1Password/Bitwarden 등 개인 비밀번호 관리자에 저장 절차 문서화
2. 페어링 URL 재발급 방법 (`orca-serve.service restart`) 문서화
3. 브라우저 캐시 클리어 시 URL 재발급이 필요함을 README에 강조

---

### 6.4 Orca 서비스 계정 비밀번호 보안 고려 (Low)

**위치:** `scripts/install/04-orca-server.sh`, `scripts/config.example.env`  
**현상:** `ORCA_SERVICE_PASSWORD`가 설정된 경우 `su - orca` 경로가 열린다. 짧은 값은 같은 호스트의 다른 계정에서 brute force 가능.

**개선 방향:**
1. 비밀번호 최소 길이·복잡도 검증 추가 (`04-orca-server.sh` 내)
2. `config.example.env`에 안전한 비밀번호 생성 명령 예시 추가 (`openssl rand -base64 32`)
3. 입주 앱과 공유하는 호스트 특성상 `orca` 계정에 추가 `su` 제한 고려 (`/etc/security/access.conf`)

---

## 7. 백업과 복구

### 7.1 Orca 상태·자격증명 백업 자동화 없음 (High)

**위치:** `docs/lightsail-plan.md` 섹션 7 — 수동 절차만 있음  
**현상:** Orca 프로필(`/home/orca/.config/orca`, `.config/Orca`, `.codex`)은 Lightsail 스냅샷에 포함되나 스냅샷 외 오프사이트 백업이 없다.

**위험:**
- 리전 장애 또는 계정 문제 시 스냅샷도 접근 불가
- 인스턴스 교체 시 자격증명 재발급 및 재인증 필요 (codex, gh)

**개선 방향:**
1. 주 1회 cron으로 `/home/orca/.config/orca`, `/home/orca/.codex`, `/home/orca/workspace` (git remote가 있는 항목은 제외) 를 S3 암호화 버킷에 업로드
2. `scripts/util/backup-orca.sh` 스크립트 추가
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

| 우선순위 | 항목 | 난이도 | 효과 |
|---|---|---|---|
| P0 | 서비스 장애 알림 설정 (systemd OnFailure + cron 핑) | 낮음 | 침묵 장애 감지 |
| P0 | 디스크 꽉 참 자동 감지·알림 | 낮음 | 서비스 크래시 방지 |
| P1 | Orca 자격증명 오프사이트 백업 스크립트 | 중간 | 복구 가능성 확보 |
| P1 | Terraform remote backend (S3) | 중간 | state 손실 방지 |
| P1 | Orca 바이너리 체크섬 검증 추가 | 낮음 | 공급망 공격 방어 |
| P2 | 외부 서비스 호출 재시도 로직 (`lib.sh` retry 헬퍼) | 중간 | 배포 안정성 |
| P2 | VS Code SSH 키 분리 | 중간 | 계정 침해 격리 |
| P2 | GitHub 토큰 만료 주기 감지 | 낮음 | 에이전트 장애 예방 |
| P3 | 복구 드릴 및 절차 검증 | 낮음 | 복구 신뢰성 |
| P3 | Orca 버전 자동 확인 스크립트 | 낮음 | 운영 편의성 |

---

## 10. 복구 체크리스트 (초안)

서비스 복구 시 다음 순서를 따른다.

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

## 참고 문서

- [`docs/lightsail-plan.md`](lightsail-plan.md) — 구축·운영·백업·복구 기준
- [`scripts/util/verify-host.sh`](../scripts/util/verify-host.sh) — 서버 전체 점검 스크립트
- [`scripts/util/diagnose-web-client.sh`](../scripts/util/diagnose-web-client.sh) — Web Client 진단
- [Lightsail Snapshots 요금](https://aws.amazon.com/lightsail/pricing/) — 스냅샷 비용 확인
- [Tailscale SSH](https://tailscale.com/kb/1193/tailscale-ssh) — 공인 IP 없는 SSH 접근 방법

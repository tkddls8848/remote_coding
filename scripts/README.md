# scripts/

Lightsail 호스트 내부 설정을 실제 실행 순서대로 자동화한다. AWS 인스턴스, 고정 IP,
키페어, 공개 포트는 [`terraform/`](../terraform/)에서 관리한다.

## 번호 체계

번호는 `scripts/` 안에서의 실행 순서이며 전체 구축 단계 번호가 아니다.

| 번호 | 파일 | 역할 |
|---:|---|---|
| 01 | `01-host-base.sh` | 패키지 갱신, 빌드 도구, 스왑 2GB, Node.js 22, 자동 보안 업데이트 |
| 02 | `02-install-orca.sh` | Orca 설치, 헤드리스 기동 검증, 필요 시 xvfb 판정 |
| 03 | `03-orca-service.sh` | Orca를 systemd 서비스로 등록하고 자동 재시작 설정 |
| 04 | `04-caddy.sh` | Caddy 설치, HTTPS/WSS 종단, 인증서 발급 |
| 05 | `05-agent-cli.sh` | Claude Code와 Codex CLI 설치 |
| 06 | `06-repos.sh` | GitHub 저장소 클론 및 Orca 등록 |

보조 파일은 번호를 붙이지 않는다.

- `sync-host.sh`: 설정과 실행 스크립트를 서버로 전송
- `verify-host.sh`: 서버 서비스, HTTPS, 스왑 점검
- `lib.sh`: 공통 함수와 설정 로더
- `config.example.env`: 로컬 설정 예시
- `remotecodepolicy.json`: Terraform 실행 주체용 최소 IAM 정책

## 준비

저장소 루트에서 설정 파일을 만든다. `config.env`는 `.gitignore` 대상이다.

```powershell
Copy-Item scripts\config.example.env scripts\config.env
notepad scripts\config.env
```

`DOMAIN`을 비우면 `sync-host.sh`가 Terraform의 고정 IP를 읽어
`<STATIC_IP>.sslip.io`를 사용한다. 파일은 BOM 없는 UTF-8과 LF 줄바꿈으로 저장한다.

## 실행

먼저 로컬 PowerShell에서 AWS 자원을 만든다.

```powershell
terraform -chdir=terraform init
terraform -chdir=terraform apply -var phase=build
& "C:\Program Files\Git\bin\bash.exe" ./scripts/sync-host.sh
```

서버에 접속해 순서대로 실행한다.

```bash
./01-host-base.sh
./02-install-orca.sh
./03-orca-service.sh
./04-caddy.sh
./verify-host.sh
./05-agent-cli.sh

# 아래 인증은 사람이 직접 완료한다.
claude
codex
gh auth login

./06-repos.sh
```

서버 검증 후 로컬에서 최종 방화벽을 적용한다.

```powershell
terraform -chdir=terraform apply -var phase=final
```

`phase=build`는 22(현재 공인 IP만), 80, 443을 열고 `phase=final`은 443만 남긴다.
최종 전환 뒤 SSH 22가 닫히는 것은 정상이다.

## 재실행과 수동 구간

스크립트는 가능한 범위에서 재실행 가능하게 작성되어 있다. 다만 패키지 최신 버전 설치,
서비스 재시작, Caddy 설정 덮어쓰기는 다시 수행될 수 있으므로 운영 중에는 변경 내용을 먼저 확인한다.

다음 작업은 자동화하지 않는다.

- Claude Code, Codex, GitHub CLI의 브라우저 인증
- Orca 클라이언트 페어링
- 사용자 도메인의 DNS A 레코드 변경

페어링 링크는 다음 명령으로 확인하며 비밀번호처럼 취급한다.

```bash
journalctl -u orca-serve -n 100 --no-pager
```

전체 절차와 운영·복구 방법은 [`docs/lightsail-plan.md`](../docs/lightsail-plan.md)를 따른다.

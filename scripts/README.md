# scripts/

[docs/lightsail-plan.md](../docs/lightsail-plan.md)의 Phase 1~10을 실행 가능한 형태로 옮긴 것.
계획서가 정본이고, 여기 스크립트는 그 절차를 그대로 자동화한 것이다.

모든 스크립트는 **여러 번 실행해도 안전하다** — 이미 만들어진 자원과 이미 끝난 설정은 건너뛴다.

## 준비

```bash
cp scripts/config.example.env scripts/config.env
$EDITOR scripts/config.env          # DOMAIN, SSH_PUBLIC_KEY 등
```

`config.env`는 `.gitignore`에 있다. 실제 도메인·IP를 적어도 커밋되지 않는다.

## 실행 순서

| 순서 | 스크립트 | 실행 위치 | Phase |
|---|---|---|---|
| 1 | `01-provision-instance.sh` | 로컬 | 1 — 인스턴스 + 고정 IP **(여기서부터 과금)** |
| 2 | `02-firewall-build.sh` | 로컬 | 2 — 22(내 IP만) + 80 + 443 |
| 3 | `sync-host.sh` | 로컬 | 호스트 스크립트를 서버로 복사 |
| 4 | `03-host-base.sh` | 서버 | 3 — 툴체인 + 스왑 2GB + Node |
| 5 | `04-install-orca.sh` | 서버 | 4 — Orca 설치 + **헤드리스 기동 검증** |
| 6 | `05-orca-service.sh` | 서버 | 5 — systemd 서비스 |
| 7 | `06-caddy.sh` | 서버 | 6 — HTTPS/WSS 종단 |
| 8 | `verify-host.sh` | 서버 | 4절 체크리스트 (서버 쪽) |
| 9 | `07-firewall-final.sh` | 로컬 | 7 — 443 하나만 남긴다 |
| 10 | `08-agent-cli.sh` | 서버 | 8 — 에이전트 CLI 설치 (로그인은 사람이) |
| 11 | `09-repos.sh` | 서버 | 9 — 레포 클론 + 등록 |
| — | `verify-aws.sh` | 로컬 | 방화벽·인스턴스 상태 점검 |

Phase 10(클라이언트 연결)은 각 기기에서 사람이 하는 일이라 스크립트가 없다.

## 자동화되지 않는 구간

계획서에 이미 적힌 대로, 다음은 사람이 직접 해야 한다.

- **에이전트 로그인** (`claude`, `codex`) — device auth. 화면의 코드를 브라우저에 입력한다.
- **`gh auth login`** — 동일하게 device flow. `09-repos.sh`는 이게 끝나 있어야 돈다.
- **클라이언트 페어링** — 페어링 링크는 `journalctl -u orca-serve`에 나온다.
  이 링크는 비밀번호와 동급이라 스크립트가 파일로 남기거나 출력해 두지 않는다.
- **DNS A 레코드** — 도메인을 쓸 경우. 없으면 `<고정IP>.sslip.io`가 자동으로 쓰인다.

## 계획서와 달라진 점 하나

계획서 Phase 2는 구축 단계에 **22만** 열도록 되어 있는데, 그 상태로는 Phase 6에서
Let's Encrypt 인증서를 받을 수 없다. ACME 챌린지가 인터넷에서 도달해야 하기 때문이다
(HTTP-01은 80, TLS-ALPN-01은 443).

그래서 `02-firewall-build.sh`는 **22(내 IP만) + 80 + 443**을 연다.
발급이 끝나면 `07-firewall-final.sh`가 443 하나만 남긴다 — 최종 상태는 계획서와 같다.

## 되돌리기

```bash
aws lightsail delete-instance   --region ap-northeast-2 --instance-name orca-host
aws lightsail release-static-ip --region ap-northeast-2 --static-ip-name orca-host-ip
```

인스턴스를 삭제하면 과금이 멈춘다.

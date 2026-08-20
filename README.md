# remote_coding

어느 위치·어느 데스크탑에서든 항상 접근 가능한 개발환경을 만들기 위한 계획과 결정 기록.

에이전트·터미널·워크트리는 클라우드의 단일 호스트에서만 돌고, 접속하는 기기는 화면만 가져간다.
노트북을 닫아도 에이전트는 계속 돌고, 다른 자리에서 열면 하던 세션이 그대로 이어진다.

## 현재 상태

**계획 단계 — 클라우드 자원은 아직 아무것도 생성되지 않았다.**

| | |
|---|---|
| 방식 | Orca의 Remote Server 모드 (별도 인프라를 새로 설계하지 않음) |
| 호스트 | AWS Lightsail 4GB, 서울 리전, Ubuntu 24.04 — **미생성** |
| 접근 경로 | 서버 쪽 Caddy가 443에서 HTTPS/WSS 종단 → 로컬 런타임으로 프록시 |
| 클라이언트 | 데스크탑 Orca 앱 / 브라우저 / 모바일 |
| 비용 | $24/mo 정액 (인스턴스 생성 시점부터) |

## 핵심 원칙

**접속하는 쪽 PC는 건드리지 않는다.** VPN 클라이언트 설치, 방화벽 규칙 추가, 포트 개방,
공유기 포트포워딩, 상시 프로세스 등록 — 어느 것도 하지 않는다.
접속하는 쪽에서 하는 일은 앱을 설치하거나 브라우저에 URL을 넣고, 페어링 링크를 붙여넣는 것뿐이다.

모든 보안 경계는 서버에 둔다. 노출되는 대상은 개인 PC가 아니라 언제든 스냅샷으로 되돌리고
갈아엎을 수 있는 격리된 VM이다.

## 문서

| 문서 | 내용 |
|---|---|
| [docs/lightsail-plan.md](docs/lightsail-plan.md) | 구축 계획서. 10단계 절차, 실행 명령, 검증 체크리스트, 리스크 대응 |
| [docs/decision-log.md](docs/decision-log.md) | 왜 이 구조인지. 개인 PC 호스팅을 접은 이유, EC2·Graviton·IPv6 번들 검토 결과 |
| [scripts/README.md](scripts/README.md) | 계획서 Phase 1~9를 옮긴 실행 스크립트. 순서와 실행 위치 |

## 다음 액션

```bash
cp scripts/config.example.env scripts/config.env   # DOMAIN, SSH_PUBLIC_KEY 등을 채운다
./scripts/01-provision-instance.sh                 # 여기서부터 과금 시작
```

이후 순서는 [scripts/README.md](scripts/README.md)의 표를 따른다. 짚어둘 지점 셋:

1. `01`이 성공하는 순간부터 $24/mo 과금이 시작된다
2. `04-install-orca.sh`가 Electron 헤드리스 기동을 실제로 검증한다 — 계획상 가장 불확실한 지점.
   그냥 안 뜨면 `xvfb-run` 래핑으로 자동 우회하고, 그래도 안 되면 거기서 멈춘다
3. `07-firewall-final.sh`까지 마치면 공개 포트가 443 하나만 남는다

에이전트 로그인(`claude`, `codex`)과 `gh auth login`, 클라이언트 페어링은 device auth라
스크립트가 대신할 수 없다. 사람이 직접 하는 구간이다.

## 주의

- 페어링 링크와 페어링 코드는 **비밀번호와 동급**이다. 이 리포지토리는 공개이므로
  실제 도메인·IP·토큰·계정 식별자를 커밋하지 않는다. 문서의 `<DOMAIN>`, `<STATIC_IP>`,
  `<MY_IP>` 같은 표기는 실행 시 채워 넣는 자리표시자다.

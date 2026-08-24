# remote_coding

개인 원격 개발 인프라와 시스템 실습 코드를 관리한다.

| 영역 | 위치 | 내용 |
|---|---|---|
| 상시 Orca 개발 서비스 | [`remote-lightsail/`](remote-lightsail/) | Lightsail + Tailscale + Orca Web Client + Codex/Claude |
| 인프라 학습 랩 | [`infra-labs/`](infra-labs/) | Kubernetes·Ceph·BeeGFS·Hadoop 등 로컬/AWS 실습 |

## remote-lightsail

도쿄 리전(ap-northeast-1)의 4GB Lightsail에서 Orca를 systemd 서비스로 계속 실행한다. 코딩 에이전트와 저장소는
서버에 남아 있고, 관리 PC는 같은 Tailscale tailnet의 웹 브라우저로 연결한다.

```text
브라우저 ── Tailscale ──> orca-serve :6768 ──> Codex / Claude Code
SSH      ── 공인 IP /32 ─> ubuntu (설치·복구 전용)
```

Orca 6768은 공개 인터넷에 열지 않는다. 기본 4GB는 동시 에이전트 하나 기준이며 병렬 작업은 8GB
이상을 권장한다.

빠른 시작과 운영 절차는 [`remote-lightsail/README.md`](remote-lightsail/README.md),
상세 설계·복구 절차는
[`remote-lightsail/docs/lightsail-plan.md`](remote-lightsail/docs/lightsail-plan.md)를
따른다.

## infra-labs

각 랩은 독립된 README를 가진다.

- [`infra-labs/systems/`](infra-labs/systems/): 실행 가능한 랩
- [`infra-labs/docs/`](infra-labs/docs/): 검토·호환성·마이그레이션 문서

## 비밀정보와 상태 파일

`scripts/config.env`, Terraform state/tfvars, `.env`, SSH 키, Tailscale·Codex·GitHub 토큰,
Orca pairing URL은 커밋하지 않는다.

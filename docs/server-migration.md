# 기존 Lightsail → ubuntu 통합 서버 이관

2026-09-23 KST 전환 완료: `orca-host-tokyo-v2`가 기존 운영 고정 IP를 사용한다.
새 Orca 주소 `https://orca-host-tokyo-v2.<tailnet>.ts.net/web-index.html`의 HTTP 200을
확인했다. Orca는 `ubuntu` 계정으로 실행한다. 기존 서버는 롤백용으로 보존하며, 새 서버의
자동 스냅샷도 설정돼 있다.

입주 앱(`stock_chatbot`)의 이관·설치·운영은 그 앱의 저장소가 소유한다. 이 문서는 호스트
수준 — 인스턴스, Terraform state, 고정 IP, Orca — 만 다룬다.

## Terraform state 소유

기존 서버는 `orca-host-tokyo`, 새 서버는 `orca-host-tokyo-v2`다. 새 서버도 도쿄
Ubuntu 24.04 / 4GB로 구성한다.
`terraform/`는 기존 서버와 운영 고정 IP 상태, `terraform/migration/`는 새 서버 상태를 소유한다.

- 기존 상태의 `instance_name`을 바꿔 replacement를 실행하면 안 된다.
- 운영 IP 리소스는 기존 상태가 계속 소유한다. 기존 서버를 나중에 삭제할 때도 기존 상태
  전체를 destroy하면 안 된다 — 운영 IP가 함께 해제된다.

## 새 서버 구성

```bash
cp terraform/migration/terraform.tfvars.example terraform/migration/terraform.tfvars
TERRAFORM_DIR="$PWD/terraform/migration" ./scripts/util/provision-host.sh
```

새 서버용 `.env`:

```bash
ORCA_SERVICE_USER=ubuntu
ORCA_SERVICE_PASSWORD=ubuntu
ORCA_SERVICE_PASSWORD_MIN_LEN=5
ORCA_SERVICE_SUDO=nopasswd
```

01~07 설치 단계를 진행한다. Tailscale 새 노드는 고유한 `orca-host-tokyo-v2` 이름으로
가입한다. 기존 Tailscale 머신 ID를 복사하지 않는다. Orca도 새 서버에서 새로 페어링한다.
기존 `/home/orca`의 프로필과 인증은 옮기지 않으므로 `ubuntu`에서 CLI 인증을 다시 한다.

## 고정 IP 전환

선택된 방식은 **기존 고정 IP 이전**이다.

1. 새 서버 상태에서 `allocate_static_ip=false`를 적용해 임시 IP 연결과 할당을 해제한다.
2. 기존 상태에서 `static_ip_target_instance_name="orca-host-tokyo-v2"`를 적용해 운영 IP를
   새 서버에 연결한다. 이 구간의 SSH는 새 서버의 Tailscale 주소를 사용한다.
3. 새 서버 상태를 refresh한 뒤 `static_ip` output이 운영 IP인지 확인한다.

롤백은 기존 상태의 `static_ip_target_instance_name`을 기존 서버로 되돌려 적용한다.

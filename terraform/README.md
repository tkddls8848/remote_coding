# terraform/

AWS 자원 생성과 방화벽 관리는 이 디렉터리의 Terraform 구성이 담당한다.

호스트 내부 설정(기본 도구, Orca, systemd, Caddy, 에이전트 CLI, 저장소)은
`scripts/01-host-base.sh`부터 `06-repos.sh`까지가 담당한다.
Lightsail 방화벽은 AWS API 호출이라 여기서 선언으로 표현되지만, 그 뒤 트래픽을
TLS 종단해서 `127.0.0.1:4224`로 넘기는 Caddy 설정은 호스트 안에 들어가야 하는 일이라
Terraform이 대신할 수 없다.

## 준비

```powershell
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
```

AWS 자격증명은 `scripts/`와 동일하게 `aws configure`로 설정한 기본 체인을 그대로 쓴다.
여기 파일에는 액세스 키를 넣지 않는다.

## 기존 키페어 이름 충돌

Lightsail 키페어는 Terraform import를 지원하지 않는다. `orca-host-key`가 이미 있으면
무작정 삭제하지 말고 사용 중인 인스턴스를 확인한다. 안전한 선택은 `key_pair_name`을 새 이름으로
바꾸는 것이다. 기존 키를 교체하려면 그 키를 쓰는 인스턴스의 SSH 접근 영향까지 검토한다.

## 실행

```powershell
# 구축 단계 — 22(내 IP만)+80+443. Let's Encrypt 인증서 발급에 80/443 이 필요하다.
terraform apply -var phase=build

# 완료 후 — 443만 남긴다
terraform apply -var phase=final
# 또는 terraform.tfvars 의 phase 를 final 로 바꾸고 그냥: terraform apply
```

`terraform apply -var phase=build`가 성공하는 순간부터 $24/mo 과금이 시작된다
(4GB 번들 정액). `terraform plan`으로 먼저 확인 가능하다.

## 상태 확인

```powershell
terraform output              # 고정 IP, ssh 명령, 접속 URL
terraform plan                 # drift 확인
```

## 되돌리기

```powershell
terraform destroy
```

인스턴스와 고정 IP를 한 번에 정리한다. 인스턴스가 삭제되면 과금이 멈춘다.

## state 파일

`terraform.tfstate`에는 고정 IP 등 리소스 상세가 그대로 담긴다. `.gitignore`로
커밋 대상에서 빠져 있다 — 로컬에만 둔다. 여러 사람/기기에서 같이 쓸 계획이 생기면
그때 원격 backend(S3 등)를 추가한다. 지금은 1인 프로젝트라 로컬 state로 충분하다.

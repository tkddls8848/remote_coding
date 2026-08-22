# terraform/

AWS Lightsail의 2GB CLI 개발 + `stock_chatbot` 호스트를 관리한다. 기본 번들은
`small_3_0`(2GB RAM, 2 vCPU)이며, 인터넷 공개 포트는 현재 공인 IP `/32`로 제한한 TCP 22 하나다.

호스트 내부 설정은 [`../scripts/`](../scripts/)가 담당한다. 이 구성에는 Orca, Caddy, HTTPS/WSS
프록시가 없으므로 80과 443을 열지 않는다.

## 준비

저장소 루트에서 실행한다.

```powershell
Copy-Item service\remote-lightsail\terraform\terraform.tfvars.example service\remote-lightsail\terraform\terraform.tfvars
notepad service\remote-lightsail\terraform\terraform.tfvars
terraform -chdir=service/remote-lightsail/terraform init
terraform -chdir=service/remote-lightsail/terraform plan
terraform -chdir=service/remote-lightsail/terraform apply
```

인프라 생성과 호스트 스크립트 복사를 한 번에 하려면 위 대신
[`../scripts/util/provision-host.sh`](../scripts/util/provision-host.sh)를 실행한다. 내부에서
같은 `init`/`apply`를 돌린 뒤 SSH가 열릴 때까지 기다렸다가 `sync-host.sh`까지 이어서 수행한다.

`my_ip`를 비우면 Terraform이 현재 공인 IP를 조회한다. 네트워크가 바뀌어 SSH가 막히면
`terraform apply`를 다시 실행해 `/32` 규칙을 갱신한다.

`phase=build`와 `phase=final`은 호환성을 위해 남아 있지만 CLI 전용 구성에서는 모두 TCP 22만
연다. 일반적인 설치에는 `terraform apply` 하나면 충분하다.

## 이름 충돌과 state

키페어와 고정 IP 이름이 이미 사용 중이면 삭제하기 전에 소유 인스턴스를 확인한다. 특히
Lightsail 키페어는 Terraform import를 지원하지 않는다. 충돌을 피해야 하면
`terraform.tfvars`의 `instance_name`, `key_pair_name`, `static_ip_name`을 새 이름으로 바꾼다.

`terraform.tfstate`에는 IP와 리소스 상세가 들어가므로 커밋하지 않는다. 인스턴스를 교체하거나
2GB에서 4GB로 올릴 때는 먼저 수동 스냅샷을 만들고, 새 인스턴스와 state를 별도 전환 절차로
검증한다.

## 확인과 삭제

```powershell
terraform -chdir=service/remote-lightsail/terraform output
terraform -chdir=service/remote-lightsail/terraform plan

# 더 이상 필요하지 않을 때만 실행한다.
terraform -chdir=service/remote-lightsail/terraform destroy
```

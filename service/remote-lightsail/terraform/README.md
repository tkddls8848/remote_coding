# terraform/

브라우저 제어형 Orca 서버의 Lightsail 리소스를 관리한다. 기본값은 도쿄 리전(ap-northeast-1) Ubuntu 24.04,
`medium_3_0`(4GB RAM, 2 vCPU), 고정 IPv4다.

```powershell
Copy-Item service\remote-lightsail\terraform\terraform.tfvars.example service\remote-lightsail\terraform\terraform.tfvars
terraform -chdir=service/remote-lightsail/terraform init
terraform -chdir=service/remote-lightsail/terraform plan
terraform -chdir=service/remote-lightsail/terraform apply
```

공인 방화벽의 완전한 의도 상태는 TCP 22 하나이며 현재 관리자 공인 IP `/32`에만 허용된다.
`my_ip`를 비우면 apply 시 `checkip.amazonaws.com`에서 감지한다. Orca TCP 6768은 Tailscale
사설 경로로만 사용하므로 Terraform 방화벽에 추가하지 않는다.

`phase=build|final`은 기존 state 호환성을 위해 유지하며 현재 두 값의 방화벽 결과는 같다.

## 리전 변경

리전을 바꾸면 Lightsail 인스턴스·고정 IP·키페어가 모두 새 리전에 새로 만들어진다. 기존 리전의
리소스는 state에서 사라질 뿐 자동으로 지워지지 않으므로, 옮기기 전에 이 순서를 따른다.

1. 기존 리전에서 스냅샷과 `/home/orca/.config/{orca,Orca}`, `/home/orca/workspace` 백업을 만든다.
2. 기존 리전 값으로 `terraform destroy` 를 실행해 옛 인스턴스와 고정 IP를 정리한다.
   (`terraform -chdir=... destroy -var region=ap-northeast-2`)
3. `region` 을 새 값으로 두고 `terraform init -reconfigure` 후 `apply` 한다.
4. 고정 IP가 바뀌므로 SSH 접속 주소와 `~/.ssh/known_hosts` 항목을 갱신한다.

`availability_zone` 은 `<region>a` 로 유도한다. 다른 AZ가 필요하면
`aws lightsail get-regions --include-availability-zones --region <리전>` 으로 확인한다.

## 용량

- `medium_3_0`(4GB): Orca + 동시 에이전트 1개 시작점
- `large_3_0`(8GB): 병렬 에이전트, 큰 빌드, 여러 브라우저 탭에 권장

번들을 바꾸면 인스턴스 교체가 발생할 수 있다. 먼저 Lightsail 수동 스냅샷과
`/home/orca/.config/{orca,Orca}`, `/home/orca/workspace` 백업을 만든다.

## 출력과 폐기

```powershell
terraform -chdir=service/remote-lightsail/terraform output
terraform -chdir=service/remote-lightsail/terraform plan

# 정말 폐기할 때만
terraform -chdir=service/remote-lightsail/terraform destroy
```

Terraform state와 `terraform.tfvars`에는 인프라 정보가 있으므로 커밋하지 않는다. 브라우저
페어링 URL은 Terraform output으로 다루지 않는다.

# terraform/

브라우저 제어형 Orca 서버의 Lightsail 리소스를 관리한다. 기본값은 서울 리전 Ubuntu 24.04,
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

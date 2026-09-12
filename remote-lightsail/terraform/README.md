# terraform/

브라우저 제어형 Orca 서버의 Lightsail 리소스를 관리한다. 기본값은 도쿄 리전(ap-northeast-1) Ubuntu 24.04,
`medium_3_0`(4GB RAM, 2 vCPU), 고정 IPv4다.

```powershell
Copy-Item service\remote-lightsail\terraform\terraform.tfvars.example service\remote-lightsail\terraform\terraform.tfvars
terraform -chdir=remote-lightsail/terraform init
terraform -chdir=remote-lightsail/terraform plan
terraform -chdir=remote-lightsail/terraform apply
```

공인 방화벽의 기본 의도 상태는 TCP 22 하나이며 현재 관리자 공인 IP `/32`에만 허용된다.
`my_ip`를 비우면 apply 시 `checkip.amazonaws.com`에서 감지한다. Orca TCP 6768은 Tailscale
사설 경로로만 사용하므로 Terraform 방화벽에 추가하지 않는다. 입주 앱의 내부 포트도
루프백 전용이다. 공개 DNS와 리버스 프록시가 준비된 경우에만 `enable_public_web=true`로 80/443을 연다.

영속 운영 데이터 보호를 위해 `enable_auto_snapshot=true`가 기본이며, 매일 19:00 UTC
(04:00 KST/JST)에 Lightsail 자동 스냅샷을 시작한다.

`phase=build|final`은 기존 state 호환성을 위해 유지하며 현재 두 값의 방화벽 결과는 같다.

## 도쿄 신규 배포

기본 리전이 도쿄(`ap-northeast-1`)이므로 그대로 `apply` 하면 도쿄에 인스턴스·고정 IP·키페어가
새로 만들어진다. 인스턴스는 `ap-northeast-1a` 에 놓인다(`availability_zone` 은 `<region>a` 로 유도).

다른 리전에 이미 배포한 것이 로컬 state 에 있다면, 같은 state 에서 리전만 바꿔 `apply` 하지 않는다.
provider 리전이 바뀌면 기존 리소스를 조회하지 못해 state 에서 빠지고(실물은 계정에 그대로 남는다)
새 리전에 새로 만들려 한다. 도쿄를 별개 배포로 두려면 state 를 분리한다.

```powershell
terraform -chdir=remote-lightsail/terraform workspace new tokyo
terraform -chdir=remote-lightsail/terraform apply
```

기존 배포는 `default` workspace 에 그대로 남는다. 리소스 이름 기본값은 `orca-host-tokyo`,
`orca-host-tokyo-key`, `orca-host-tokyo-ip` 라서 다른 리전의 기존 `orca-host` 계열과 콘솔에서 바로
구분된다. Lightsail 이름은 리전별로 관리되어 같은 이름을 써도 충돌하지는 않지만, 한 계정에서 두
대를 함께 볼 때를 위해 리전 접미사를 기본값으로 둔다.

새로 만든 인스턴스는 고정 IP가 새로 발급되므로, 접속 주소와 `~/.ssh/known_hosts` 는 새 IP 기준으로
쓴다. 다른 AZ가 필요하면 `aws lightsail get-regions --include-availability-zones --region ap-northeast-1`
로 확인한다.

## 용량

- `medium_3_0`(4GB): Orca + 동시 에이전트 1개 시작점
- `large_3_0`(8GB): 병렬 에이전트, 큰 빌드, 여러 브라우저 탭에 권장

번들을 바꾸면 인스턴스 교체가 발생할 수 있다. 먼저 Lightsail 수동 스냅샷과
`/home/orca/.config/{orca,Orca}`, `/home/orca/workspace` 백업을 만든다.

## 출력과 폐기

```powershell
terraform -chdir=remote-lightsail/terraform output
terraform -chdir=remote-lightsail/terraform plan

# 정말 폐기할 때만
terraform -chdir=remote-lightsail/terraform destroy
```

Terraform state와 `terraform.tfvars`에는 인프라 정보가 있으므로 커밋하지 않는다. 브라우저
페어링 URL은 Terraform output으로 다루지 않는다.

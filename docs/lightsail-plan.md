# Lightsail Orca 원격 코딩 호스트 구축 및 운영

> 기준일: 2026-08-21
> 상태: 저장소에는 Terraform과 호스트 설정 스크립트가 준비되어 있다. 실제 AWS 자원 생성 여부는
> 문서가 아니라 `terraform -chdir=terraform plan`과 AWS 콘솔에서 확인한다.

이 문서는 AWS Lightsail에 Orca 헤드리스 런타임을 설치하고 HTTPS/WSS로 연결하는 절차의 정본이다.
AWS 자원은 [`terraform/`](../terraform/)이, Ubuntu 호스트 내부 설정은 [`scripts/`](../scripts/)가 담당한다.

## 1. 목표와 완료 조건

개발 워크트리, 터미널, 코딩 에이전트는 Lightsail 호스트에서 계속 실행하고 클라이언트는
Orca 앱 또는 브라우저로 접속한다. 접속 PC의 VPN, 방화벽, 공유기 설정은 변경하지 않는다.

완료 조건은 다음과 같다.

- Orca 데스크톱 앱과 브라우저에서 같은 원격 환경에 접속된다.
- 클라이언트를 종료해도 서버의 작업과 세션이 유지된다.
- 재부팅 후 `orca-serve`와 Caddy가 자동으로 다시 실행된다.
- Orca의 내부 포트 4224는 인터넷에 직접 공개되지 않는다.
- 구축 완료 후 Lightsail 공개 인바운드 포트는 TCP 443 하나다.

## 2. 구조

```text
클라이언트 Orca / 브라우저
          │ HTTPS · WSS :443
          ▼
Lightsail 공개 방화벽
          │ TCP 443만 허용
          ▼
Caddy ── reverse_proxy ──> 127.0.0.1:4224 Orca
 TLS                         systemd: orca-serve
```

Caddy는 TLS 인증서 발급·갱신과 WebSocket 프록시를 담당한다. Orca는 4224에서 평문 HTTP/WS로
동작하지만 Lightsail 방화벽에 4224를 열지 않는다.

## 3. 구성 소유권과 번호 체계

| 범위 | 정본 | 내용 |
|---|---|---|
| AWS 자원 | `terraform/` | 인스턴스, Lightsail 키페어, 고정 IP, 공개 포트 |
| 호스트 설정 | `scripts/01`~`06` | 기본 도구, Orca, systemd, Caddy, 에이전트 CLI, 저장소 |
| 전송·검증 | 번호 없는 보조 스크립트 | `sync-host.sh`, `verify-host.sh` |
| 사람의 작업 | 자동화하지 않음 | AWS/GitHub/에이전트 로그인, DNS, Orca 페어링 |

`scripts/` 번호는 호스트 안에서의 실행 순서다. 예전의 전체 Phase 번호를 파일명에 섞지 않는다.

## 4. 사전 준비

### 4.1 로컬 도구

Windows 11 PowerShell 기준이다.

```powershell
aws --version
terraform -version
ssh -V
& "C:\Program Files\Git\bin\bash.exe" --version
```

필요하면 설치한다.

```powershell
winget install --id Amazon.AWSCLI -e
winget install --id Hashicorp.Terraform -e
winget install --id Git.Git -e
```

`Get-Command bash`가 `C:\Windows\System32\bash.exe`를 반환하면 WSL bash다. 이 저장소의
로컬 셸 스크립트는 Git Bash를 명시해 실행한다.

### 4.2 AWS 인증과 IAM

```powershell
$env:AWS_PAGER = ""
aws configure
aws sts get-caller-identity
```

Terraform 구성에 액세스 키를 기록하지 않는다. 실행 주체에는
[`scripts/remotecodepolicy.json`](../scripts/remotecodepolicy.json)의 작업을 허용하는 고객 관리형
정책을 연결한다. 조직에서 SSO나 역할을 사용하면 장기 액세스 키 대신 해당 자격증명 체인을 사용한다.

### 4.3 SSH 키와 설정 파일

```powershell
if (-not (Test-Path "$env:USERPROFILE\.ssh\id_ed25519.pub")) {
    ssh-keygen -t ed25519 -C "orca-host"
}

Copy-Item terraform\terraform.tfvars.example terraform\terraform.tfvars
Copy-Item scripts\config.example.env scripts\config.env
notepad terraform\terraform.tfvars
notepad scripts\config.env
```

- `terraform.tfvars`: 리전, 번들, 이미지, 키 경로, 방화벽 단계
- `config.env`: 도메인, GitHub 소유자, 등록할 저장소
- `DOMAIN`을 비우면 `<STATIC_IP>.sslip.io`를 자동 사용한다.
- 두 파일과 Terraform state는 커밋하지 않는다.
- 셸 파일과 `config.env`는 BOM 없는 UTF-8, LF 줄바꿈을 사용한다.

### 4.4 번들·이미지 확인

기본값은 서울 리전, Ubuntu 24.04, 4GB Linux/public IPv4 번들이다. AWS의 상품과 ID는 바뀔 수
있으므로 새로 구축하기 전에 실제 활성 값을 확인한다.

```powershell
aws lightsail get-bundles --region ap-northeast-2 `
  --query 'bundles[?isActive && ramSizeInGb==`4`].[bundleId,name,price,cpuCount,diskSizeInGb]' `
  --output table

aws lightsail get-blueprints --region ap-northeast-2 `
  --query 'blueprints[?isActive && contains(name, `Ubuntu 24.04`)].[blueprintId,name,version]' `
  --output table
```

2026-08-21 공식 AWS 표의 Medium 4GB Linux/public IPv4 기준은 월 USD 24, 2 vCPU,
4GB RAM, 80GB SSD다. 실제 청구와 리전별 전송량은 구축 시 AWS 가격표와 Billing에서 재확인한다.

## 5. 구축 절차

### 5.1 Terraform 초기화와 검토

저장소 루트에서 실행한다.

```powershell
terraform -chdir=terraform init
terraform -chdir=terraform fmt -check
terraform -chdir=terraform validate
terraform -chdir=terraform plan -var phase=build
```

`phase=build`의 공개 포트는 다음과 같다.

- TCP 22: 실행 시 감지한 현재 공인 IP `/32`만 허용
- TCP 80: 인증서 HTTP-01 검증을 위해 임시 공개
- TCP 443: HTTPS/WSS와 TLS-ALPN 검증을 위해 공개

### 5.2 인스턴스 생성

```powershell
terraform -chdir=terraform apply -var phase=build
terraform -chdir=terraform output
```

이 작업은 Lightsail 인스턴스, 키페어, 고정 IP와 공개 포트를 만든다. 인스턴스 생성 시점부터
사용량이 청구된다.

현재 구성의 `aws_lightsail_key_pair`는 로컬 공개키 원문을 Lightsail에 등록한다. Lightsail
키페어 리소스는 기존 키를 Terraform state로 가져오는 import를 지원하지 않는다. 같은 이름의
키가 이미 있으면 적용을 반복하지 말고, 사용할 키와 영향받는 인스턴스를 확인한 뒤 기존 키 이름을
변경하거나 명시적으로 정리한다.

### 5.3 설정과 스크립트 전송

```powershell
& "C:\Program Files\Git\bin\bash.exe" ./scripts/sync-host.sh
$ip = terraform -chdir=terraform output -raw static_ip
ssh ubuntu@$ip
```

`sync-host.sh`는 `~/orca-host.env`와 실행 스크립트를 서버 홈으로 복사하고 실행 권한을 설정한다.

### 5.4 호스트 기본 설정

서버에서 실행한다.

```bash
./01-host-base.sh
```

이 스크립트는 패키지를 갱신하고 빌드 도구, Python, Git, curl, Node.js 22를 설치한다. 2GB 스왑과
비대화형 자동 보안 업데이트도 설정한다. 운영 서비스가 생긴 뒤 재실행하면 패키지 업그레이드가
발생할 수 있으므로 변경 창에 수행한다.

### 5.5 Orca 설치와 헤드리스 검증

```bash
./02-install-orca.sh
```

GitHub의 최신 `orca-ide_*_amd64.deb`를 설치하고 `orca serve`가 `/web-index.html`에 응답하는지
검사한다. 디스플레이 없이 실패하면 xvfb를 설치해 재검사하고 성공 시
`~/.orca-needs-xvfb` 플래그를 남긴다. xvfb로도 실패하면 이후 단계를 실행하지 않고 출력 로그를
확인한다.

### 5.6 Orca systemd 서비스

```bash
./03-orca-service.sh
systemctl status orca-serve --no-pager
```

서비스는 `ubuntu` 사용자로 실행되고 실패 시 자동 재시작한다. 앞 단계의 xvfb 판정을 그대로
사용하고 메모리 상한을 2GB로 둔다. `--pairing-address`에는 `wss://<DOMAIN>`을 광고한다.

페어링 링크 확인:

```bash
journalctl -u orca-serve -n 100 --no-pager
```

페어링 링크는 비밀번호와 동급이다. 저장소, 이슈, 문서, 공개 채널에 남기지 않는다.

### 5.7 Caddy와 HTTPS/WSS

```bash
./04-caddy.sh
systemctl status caddy --no-pager
```

Caddy는 `https://<DOMAIN>`을 `127.0.0.1:4224`로 프록시한다. 사용자 도메인을 쓴다면 실행 전에
DNS A 레코드가 Terraform의 고정 IP를 가리켜야 한다. 추가 Basic Auth가 필요하면 평문 비밀번호가
아닌 Caddy 해시를 전달한다.

```bash
caddy hash-password
BASIC_AUTH_USER=myuser BASIC_AUTH_HASH='<HASH>' ./04-caddy.sh
```

### 5.8 서버 검증

```bash
./verify-host.sh
```

다음을 모두 확인한다.

- `orca-serve`, `caddy`가 active·enabled 상태
- 로컬 4224와 외부 HTTPS 웹 번들이 응답
- 스왑 활성
- 최근 Orca 로그에 치명적 오류가 없음

### 5.9 에이전트와 GitHub 인증

```bash
./05-agent-cli.sh
claude
codex
gh auth login
```

설치는 자동화하지만 브라우저 인증은 사람이 직접 한다. 인증 코드와 토큰을 로그나 설정 파일에
복사하지 않는다.

### 5.10 저장소 등록

```bash
./06-repos.sh
orca repo list
```

`~/orca/<repo>`에 저장소를 복제하고 Orca에 등록한다. 대상은 로컬 `scripts/config.env`의
`REPOS`, `GITHUB_OWNER`에서 관리하며 `sync-host.sh`를 다시 실행해야 서버 설정에 반영된다.

### 5.11 최종 방화벽 전환

서버 검증과 필요한 SSH 작업을 마친 뒤 로컬에서 실행한다.

```powershell
terraform -chdir=terraform apply -var phase=final
terraform -chdir=terraform output open_ports

aws lightsail get-instance-port-states --region ap-northeast-2 `
  --instance-name orca-host --output table
```

`phase=final`은 기존 공개 포트 규칙 전체를 TCP 443 하나로 교체한다. 이후 일반 SSH 접속이 막히는
것은 정상이다. 관리가 필요하면 Lightsail 브라우저 SSH를 사용하거나 잠시 `phase=build`를 적용하고,
작업 직후 `phase=final`로 복구한다.

## 6. 클라이언트 연결과 인수 테스트

| 클라이언트 | 연결 방법 |
|---|---|
| Orca 데스크톱 | Remote Orca Servers에서 서비스 로그의 페어링 링크 추가 |
| 브라우저 | `https://<DOMAIN>/web-index.html` 열기 |
| Orca CLI 지원 환경 | `orca environment add --name cloud --pairing-code "<PAIRING_LINK>"` |

기능과 메뉴 이름은 Orca 버전에 따라 달라질 수 있으므로 설치된 클라이언트의 안내를 우선한다.

인수 테스트:

1. 클라이언트에서 저장소와 터미널을 연다.
2. 코딩 에이전트 작업을 시작하고 클라이언트를 완전히 종료한다.
3. 다른 클라이언트로 접속해 서버 작업이 유지되는지 확인한다.
4. 서버를 재부팅하고 `orca-serve`, Caddy와 원격 접속이 자동 복구되는지 확인한다.
5. `terraform -chdir=terraform plan`에서 의도하지 않은 변경이 없는지 확인한다.

## 7. 운영

| 목적 | 명령 또는 방법 |
|---|---|
| 상태 | `systemctl status orca-serve caddy --no-pager` |
| Orca 로그 | `journalctl -u orca-serve -f` |
| Caddy 로그 | `journalctl -u caddy -f` |
| 서비스 재시작 | `sudo systemctl restart orca-serve` |
| AWS drift 확인 | `terraform -chdir=terraform plan` |
| 공인 포트 확인 | `aws lightsail get-instance-port-states --region ap-northeast-2 --instance-name orca-host` |
| 수동 스냅샷 | `aws lightsail create-instance-snapshot --region ap-northeast-2 --instance-name orca-host --instance-snapshot-name <NAME>` |
| 스펙 상향 | 스냅샷으로 상위 번들 인스턴스 생성 후 검증하고 고정 IP 재부착 |
| 완전 삭제 | `terraform -chdir=terraform destroy` |

스냅샷, 데이터 전송, 세금 등은 인스턴스 번들과 별도로 청구될 수 있다. 삭제 전 필요한 워크트리,
자격증명, 미푸시 커밋을 백업한다.

## 8. 장애 대응

| 증상 | 점검과 대응 |
|---|---|
| SSH 접속 거부 | 현재 공인 IP가 바뀌었는지 확인하고 `phase=build` 재적용 또는 브라우저 SSH 사용 |
| Orca 기동 실패 | `journalctl -u orca-serve`; `~/.orca-needs-xvfb`; 4224 충돌 확인 |
| HTTPS 인증서 실패 | DNS가 고정 IP를 가리키는지, build 단계에서 80/443이 열렸는지, Caddy 로그 확인 |
| 브라우저는 열리지만 페어링 실패 | `--pairing-address`, WSS 주소, Orca/Caddy 로그 확인 |
| 메모리 부족 | `free -h`, `systemd-cgtop`, 커널 OOM 로그 확인 후 작업량 축소 또는 상위 번들 검토 |
| 페어링 링크 유출 | Orca 접근 권한에서 즉시 회수하고 새 링크로 재페어링 |
| Terraform 키페어 이름 충돌 | Lightsail 키페어는 import 불가. 기존 키의 사용처를 확인한 뒤 이름 변경 또는 명시적 교체 |
| Terraform state 유실 | 무작정 apply하지 말고 AWS 자원을 조사해 import 가능한 자원부터 state 복구. 키페어는 재구성 필요 |

## 9. 보안 원칙

- 최종 공개 포트는 443만 유지한다.
- 4224, 데이터베이스, 개발 서버 포트를 인터넷에 직접 열지 않는다.
- AWS·GitHub·에이전트 토큰과 페어링 링크를 Git에 커밋하지 않는다.
- `terraform.tfstate`도 비밀정보가 포함될 수 있는 민감 파일로 취급한다.
- 운영 중 패키지 업그레이드와 스크립트 재실행은 변경 창에 수행한다.
- 불필요해진 인스턴스, 고정 IP, 스냅샷은 비용과 복구 필요성을 확인한 뒤 정리한다.

## 10. 공식 참고 자료

- [Amazon Lightsail 인스턴스 번들](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-bundles.html)
- [AWS CLI `get-bundles`](https://docs.aws.amazon.com/cli/latest/reference/lightsail/get-bundles.html)
- [AWS CLI `put-instance-public-ports`](https://docs.aws.amazon.com/cli/latest/reference/lightsail/put-instance-public-ports.html)
- [Terraform `aws_lightsail_key_pair`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lightsail_key_pair)

# remote_coding

어느 위치·어느 데스크탑에서든 항상 접근 가능한 개발환경을 만들기 위한 계획과 결정 기록.

에이전트·터미널·워크트리는 클라우드의 단일 호스트에서만 돌고, 접속하는 기기는 화면만 가져간다.
노트북을 닫아도 에이전트는 계속 돌고, 다른 자리에서 열면 하던 세션이 그대로 이어진다.

이 문서는 **조작하는 쪽이 Windows 11 + PowerShell**인 상황을 기준으로 쓴다.
서버(호스트)는 Ubuntu 24.04이고, 서버에서 도는 스크립트는 리눅스 쉘에서 실행한다.

## 현재 상태

**계획 단계 — 클라우드 자원은 아직 아무것도 생성되지 않았다.**

| | |
|---|---|
| 방식 | Orca의 Remote Server 모드 (별도 인프라를 새로 설계하지 않음) |
| 호스트 | AWS Lightsail 4GB, 서울 리전, Ubuntu 24.04 — **미생성** |
| 접근 경로 | 서버 쪽 Caddy가 443에서 HTTPS/WSS 종단 → 로컬 런타임으로 프록시 |
| 조작하는 쪽 | Windows 11 / PowerShell (+ Git Bash, AWS CLI v2, Terraform, 내장 OpenSSH) |
| 클라이언트 | 데스크탑 Orca 앱 / 브라우저 / 모바일 |
| 비용 | $24/mo 정액 (인스턴스 생성 시점부터) |

## 핵심 원칙

**접속하는 쪽 PC는 건드리지 않는다.** VPN 클라이언트 설치, 방화벽 규칙 추가, 포트 개방,
공유기 포트포워딩, 상시 프로세스 등록 — 어느 것도 하지 않는다.
접속하는 쪽에서 하는 일은 앱을 설치하거나 브라우저에 URL을 넣고, 페어링 링크를 붙여넣는 것뿐이다.

모든 보안 경계는 서버에 둔다. 노출되는 대상은 개인 PC가 아니라 언제든 스냅샷으로 되돌리고
갈아엎을 수 있는 격리된 VM이다.

## 문서 / 코드

| | 내용 |
|---|---|
| [docs/lightsail-plan.md](docs/lightsail-plan.md) | 구축 계획서. 10단계 절차, 아키텍처, 검증 체크리스트, 리스크 대응 |
| [docs/decision-log.md](docs/decision-log.md) | 왜 이 구조인지. 개인 PC 호스팅을 접은 이유, EC2·Graviton·IPv6 번들 검토 결과 |
| [terraform/](terraform/) | AWS 자원(인스턴스·고정 IP·키페어·방화벽) — 계획서 Phase 1·2·7 |
| [scripts/](scripts/) | 호스트 내부 설정(Orca·systemd·Caddy·에이전트 CLI·레포) — 계획서 Phase 3~6, 8~9 |

**AWS API로 되는 일과 호스트 안에 들어가야 하는 일이 나뉘어 있다.** 인터넷 쪽으로 어떤 포트가
열리는지는 `terraform/`이 선언하고, 그 트래픽을 TLS 종단해서 로컬 4224로 넘기는 일은 `scripts/`가
서버 안에서 한다. 자세한 이유는 각 디렉터리의 README를 본다.

---

## Windows 준비

한 번만 하면 되는 부분이다. 다섯 가지를 맞춘다: 도구, bash 경유 실행, 줄바꿈, AWS 자격증명, Terraform.

### 1. 도구

PowerShell에서 전부 응답해야 한다.

```powershell
aws --version         # aws-cli/2.x  ← v1이면 안 된다
bash --version        # Git for Windows 동봉
ssh -V                # Windows 11 내장 OpenSSH
terraform -version    # 1.5 이상
```

없으면:

```powershell
winget install --id Amazon.AWSCLI -e
winget install --id Git.Git -e
winget install --id Hashicorp.Terraform -e
# OpenSSH 클라이언트가 빠져 있을 때만 (관리자 PowerShell)
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

`bash`가 **WSL 쪽으로 잡히면 안 된다.** 확인:

```powershell
(Get-Command bash).Source
# C:\Program Files\Git\usr\bin\bash.exe  ← 이래야 한다
# C:\Windows\System32\bash.exe           ← WSL. 아래처럼 Git bash를 명시한다
```

WSL로 잡히면 이 세션에서만 별칭을 덮어쓴다:

```powershell
Set-Alias bash "C:\Program Files\Git\bin\bash.exe" -Scope Global
```

### 2. 스크립트는 PowerShell이 직접 실행하지 못한다

`scripts/*.sh`는 bash 스크립트다. `./scripts/sync-host.sh`는 PowerShell에서 동작하지
않는다. **항상 `bash`에 넘긴다.**

```powershell
bash ./scripts/sync-host.sh
```

경로 구분자는 `/`를 쓴다. bash에 넘어가는 인자에서 `\`는 이스케이프 문자로 읽힌다.
`terraform/`은 반대로 **PowerShell에서 직접** 실행한다 (`terraform apply` 등) — bash로
감쌀 필요 없다.

### 3. 줄바꿈을 LF로 고정한다

이 리포는 `core.autocrlf=true` 상태에서 체크아웃되면 워크트리의 `.sh`가 **CRLF**가 된다.
로컬 Git Bash는 CRLF를 견디지만, `sync-host.sh`가 그 파일을 그대로 서버로 복사하고
**Ubuntu의 bash는 `\r`을 견디지 못한다** (`/usr/bin/env: 'bash\r': No such file or directory`).
Phase 3에서 터진다. 지금 맞춰 놓는다.

```powershell
git config core.autocrlf input
git rm --cached -r . | Out-Null
git reset --hard
git ls-files --eol scripts    # 전부 i/lf, w/lf 여야 한다
```

`w/crlf`가 하나라도 남아 있으면 서버 단계에서 실패한다.

### 4. AWS 자격증명과 IAM 정책

```powershell
$env:AWS_PAGER = ""            # 페이저가 뜨면 스크립트가 멈춘다
aws configure                  # 액세스 키 / 시크릿 / ap-northeast-2 / json
aws sts get-caller-identity    # ARN이 나오면 성공
```

Terraform도 이 자격증명을 그대로 쓴다 (provider 설정에 키를 따로 넣지 않는다).

Lightsail에는 `AmazonLightsailFullAccess` 같은 관리형 정책이 **없다.** 이 절차가 호출하는
액션만 담은 정책이 `scripts/remotecodepolicy.json`에 있다. 고객 관리형 정책으로 만들어 붙인다.

```powershell
aws iam create-policy --policy-name remotecodepolicy `
  --policy-document file://scripts/remotecodepolicy.json

aws iam attach-user-policy --user-name <IAM_USER> `
  --policy-arn arn:aws:iam::<ACCOUNT_ID>:policy/remotecodepolicy
```

`file://` 뒤 경로는 `/`로 쓴다. 백슬래시는 AWS CLI가 못 읽는다.

> **PowerShell 인용 주의** — `--query`에 들어가는 JMESPath는 **작은따옴표**로 감싼다.
> 큰따옴표 안에서 백틱(`` ` ``)은 PowerShell 이스케이프 문자로 먹혀서 표현식이 깨진다.
> ```powershell
> aws lightsail get-instance-port-states --region ap-northeast-2 --instance-name orca-host `
>   --query 'portStates[?state==`open`].fromPort' --output text
> ```

### 5. SSH 키

Terraform이 임포트할 공개키다. 없으면 만든다.

```powershell
if (-not (Test-Path "$env:USERPROFILE\.ssh\id_ed25519")) {
    ssh-keygen -t ed25519 -C "orca-host"
}
```

`terraform/terraform.tfvars`의 `ssh_public_key_path`는 기본값이 `~/.ssh/id_ed25519.pub`다.
Terraform이 실행되는 쪽(PowerShell)의 `~`를 그대로 인식하므로 따로 바꿀 필요는 없다.

---

## 실행

### 1) AWS 자원 — Terraform

```powershell
cd terraform
Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars            # phase, region 등 확인
terraform init
terraform apply -var phase=build    # 여기서부터 과금 시작
```

성공하면 `terraform output`으로 고정 IP와 접속 명령이 나온다. 자세한 사용법은
[terraform/README.md](terraform/README.md).

### 2) 호스트 설정 — scripts/

```powershell
Copy-Item scripts\config.example.env scripts\config.env
notepad scripts\config.env          # DOMAIN, REPOS, GITHUB_OWNER
```

`config.env`는 `.gitignore`에 있어서 실제 도메인을 적어도 커밋되지 않는다.
**저장할 때 BOM을 붙이면 안 된다.** BOM이 붙으면 `lib.sh`가 이 파일을 읽는 순간
`$'\357\273\277#': command not found`로 죽는다. 메모장은 인코딩을 "UTF-8"로 두면 되고,
PowerShell로 쓸 거면 `Set-Content -Encoding utf8`은 5.1에서 BOM을 붙이므로 쓰지 않는다.

| 순서 | 명령 | 실행 위치 |
|---|---|---|
| 1 | `terraform apply -var phase=build` (`terraform/`) | PowerShell **(여기서부터 과금)** |
| 2 | `bash ./scripts/sync-host.sh` | PowerShell |
| 3 | `ssh ubuntu@<STATIC_IP>` 후 `./03-host-base.sh` | 서버 |
| 4 | `./04-install-orca.sh` | 서버 |
| 5 | `./05-orca-service.sh` | 서버 |
| 6 | `./06-caddy.sh` | 서버 |
| 7 | `./verify-host.sh` | 서버 |
| 8 | `terraform apply -var phase=final` (`terraform/`) | PowerShell |
| 9 | `./08-agent-cli.sh` | 서버 |
| 10 | `./09-repos.sh` | 서버 |
| — | `terraform plan` (`terraform/`) | PowerShell (언제든 상태 점검) |

모든 스크립트는 여러 번 실행해도 안전하다. 이미 만들어진 자원과 끝난 설정은 건너뛴다.

짚어둘 지점 셋:

1. `terraform apply -var phase=build`가 성공하는 순간부터 $24/mo 과금이 시작된다
2. `04-install-orca.sh`가 Electron 헤드리스 기동을 실제로 검증한다 — 계획상 가장 불확실한 지점.
   그냥 안 뜨면 `xvfb-run` 래핑으로 자동 우회하고, 그래도 안 되면 거기서 멈춘다
3. `terraform apply -var phase=final`까지 마치면 공개 포트가 443 하나만 남는다

에이전트 로그인(`claude`, `codex`)과 `gh auth login`, 클라이언트 페어링은 device auth라
스크립트가 대신할 수 없다. 사람이 직접 하는 구간이다.

---

## 자주 쓰는 명령

고정 IP는 Terraform state가 정본이다. 변수에 담아 두면 편하다.

```powershell
cd terraform
$ip = terraform output -raw static_ip
cd ..
```

| 목적 | 명령 |
|---|---|
| AWS 자원 상태 점검 (drift 확인) | `terraform -chdir=terraform plan` |
| 서버 접속 | `ssh ubuntu@$ip` |
| Orca 서비스 상태 | `ssh ubuntu@$ip 'systemctl status orca-serve --no-pager'` |
| 페어링 링크 확인 | `ssh ubuntu@$ip 'journalctl -u orca-serve -n 50 --no-pager'` |
| 내 공인 IP 확인 | `(Invoke-RestMethod https://checkip.amazonaws.com).Trim()` |
| 접속 주소 열기 | `Start-Process "https://$ip.sslip.io/web-index.html"` |

집·회사가 바뀌어 공인 IP가 달라지면 SSH가 막힌다. 구축 중이라면
`terraform apply -var phase=build`를 다시 돌려 현재 IP로 갱신한다 (`my_ip`를 비워두면
자동 재감지). `final` 단계 이후에는 SSH가 닫혀 있는 것이 정상이고, 일시적으로
열어야 하면 `phase=build`로 다시 돌린 뒤 작업하고 `phase=final`로 되돌린다.

## 되돌리기

```powershell
cd terraform
terraform destroy
```

인스턴스와 고정 IP를 한 번에 정리한다. 과금이 멈춘다.

## 주의

- 페어링 링크와 페어링 코드는 **비밀번호와 동급이다.** 이 리포지토리는 공개이므로
  실제 도메인·IP·토큰·계정 식별자를 커밋하지 않는다. 문서의 `<DOMAIN>`, `<STATIC_IP>`,
  `<MY_IP>` 같은 표기는 실행 시 채워 넣는 자리표시자다.
- `scripts/config.env`, `terraform/terraform.tfvars`, `terraform/*.tfstate*`, `*.pem`,
  `*.key`는 `.gitignore`에 있다. 이름을 바꿔 저장하지 않는다.

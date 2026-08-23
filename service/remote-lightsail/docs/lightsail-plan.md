# Lightsail 상시 Orca 서버 구축·운영 계획

> 기준일: 2026-08-23
> 목표: Lightsail에서 Orca와 코딩 에이전트를 계속 실행하고 웹 브라우저로 제어한다.

## 1. 확정 아키텍처

```text
관리 PC (Tailscale + 웹 브라우저)
              │ HTTP/WS over tailnet
              ▼
Lightsail Ubuntu 24.04 / medium_3_0(4GB)
├─ tailscaled
├─ orca-serve.service :6768
│  ├─ Web Client
│  ├─ terminals / worktrees / browser tabs
│  └─ Codex 또는 Claude Code
└─ /home/orca
   ├─ .config/{orca,Orca}       # 런타임 상태·페어링
   ├─ .codex                    # Codex 자격증명/설정
   └─ workspace                 # 개발 저장소
```

관리면과 작업면을 분리한다.

- SSH 22: `ubuntu` 관리자 계정, 현재 공인 IP `/32`만 허용
- Orca 6768: Lightsail 공인 방화벽에는 미개방, Tailscale 사설망에서만 접근
- 에이전트/저장소: 권한이 제한된 `orca` system user가 소유

이 선택은 별도 도메인·Caddy·공개 TLS 인증서가 필요 없고 Orca의 pairing/E2EE 접근 권한을
사설망 안에 한 번 더 가둔다. 공개 리버스 프록시는 기본 설계에 포함하지 않는다.

## 2. 구축

### 로컬

```powershell
Copy-Item service\remote-lightsail\terraform\terraform.tfvars.example service\remote-lightsail\terraform\terraform.tfvars
Copy-Item service\remote-lightsail\scripts\config.example.env service\remote-lightsail\scripts\config.env
& "C:\Program Files\Git\bin\bash.exe" ./service/remote-lightsail/scripts/util/provision-host.sh
```

Terraform은 인스턴스·고정 IP·키페어·SSH 방화벽을 만들고 스크립트를 서버로 복사한다.

### 서버

```bash
cd ~/remote-lightsail-scripts
./install/01-host-base.sh
./install/02-agent-cli.sh
./install/03-private-network.sh
sudo tailscale up
```

Tailscale 로그인 후 관리 PC도 같은 tailnet에 연결한다.

```bash
./install/04-orca-server.sh
sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec codex login --device-auth'
sudo -u orca -H /bin/bash -c 'cd "$HOME" && exec gh auth login'
./install/05-repos.sh
./util/verify-host.sh
sudo ./util/show-orca-access.sh
```

`codex login --device-auth`는 원격 서버에서 device authorization을 시작하고 관리 PC의
브라우저에서 완료한다. AppImage의 `account add`는 GUI/X11 초기화나 실행 중인 Orca의
single-instance lock에 걸릴 수 있으므로 headless 설치 절차에는 쓰지 않는다. 자동화용 API key를
쓸 경우 표준 API 요금이 적용되며, 키는 저장소나 systemd unit에 직접 넣지 않는다.

## 3. 브라우저 접속

`show-orca-access.sh`의 URL을 같은 tailnet의 브라우저에서 연다. URL fragment에 pairing
capability가 들어 있어 일반 HTTP 로그의 query에는 남지 않지만, URL 자체는 비밀번호와 같다.

- 채팅·이슈·화면 공유에 붙이지 않는다.
- 공용 브라우저나 시크릿 모드를 일상 클라이언트로 쓰지 않는다.
- 브라우저 저장소를 지우면 새 pairing이 필요할 수 있다.
- 새 링크이 필요하면 `sudo systemctl restart orca-serve` 후 접근 URL을 다시 조회한다. 기존에
  발급된 클라이언트 grant는 서버 프로필이 유지되는 한 재부팅·업그레이드 후 재연결된다.

Orca Web Client/Remote Server는 Beta다. 브라우저에서 로컬 OS 파일 선택·다운로드처럼 Electron
데스크톱 기능에 의존하는 일부 동작은 제한될 수 있으므로, 복구 경로로 SSH를 유지한다.

## 4. 운영 기준

| 점검 | 명령/기준 |
|---|---|
| 서비스 | `systemctl is-active orca-serve tailscaled` |
| 로그 | `journalctl -u orca-serve -f` |
| 메모리 | `free -h`; swap이 지속 증가하면 8GB로 확장 |
| 디스크 | `df -h /home /opt/orca`; 80% 전에 정리/확장 |
| 공인 포트 | Lightsail에서 TCP 22 `/32`만 존재 |
| Orca 접속 | `show-orca-access.sh` URL을 tailnet 브라우저에서 확인 |

4GB는 동시 에이전트 하나 기준이다. 병렬 에이전트, 대형 빌드, 장시간 유지되는 내장 브라우저 탭은
메모리를 빠르게 늘리므로 8GB로 올리거나 사용 후 탭/터미널을 닫는다.

## 5. 업그레이드와 백업

헤드리스 `orca serve`는 자동 업데이트하지 않는다. 다음 순서로 명시적으로 올린다.

1. Lightsail 스냅샷 생성
2. `/home/orca/.config/orca`, `/home/orca/.config/Orca`, `/home/orca/workspace` 백업
3. `scripts/config.env`의 `ORCA_VERSION` 변경 후 서버에 재동기화
4. `04-orca-server.sh` 재실행
5. 로그의 `orca_server_ready`와 브라우저 재연결 확인

다운그레이드는 바이너리만 되돌리면 안 된다. 새 버전이 상태 스키마를 바꿀 수 있으므로 같은 시점의
Orca 프로필 백업도 함께 복구한다.

## 6. 장애 복구

```bash
sudo systemctl status orca-serve --no-pager
sudo journalctl -u orca-serve -n 200 --no-pager
tailscale status
tailscale ip -4
free -h
df -h
```

- `orca_server_ready` 없음: AppImage/Xvfb/FUSE 의존성과 서비스 로그 확인
- 브라우저 연결 실패: 관리 PC tailnet, 광고된 주소, 6768 리스너 확인
- 에이전트 실행 실패: `as_orca`와 같은 HOME 전환 방식으로 `codex login status`,
  `gh auth status`, PATH 확인
- exit 3 반복: 같은 `orca` 프로필을 쓰는 다른 Orca 프로세스를 종료한 뒤
  `systemctl reset-failed orca-serve` 실행
- OOM/swap 과다: 스냅샷 후 `large_3_0` 새 인스턴스로 검증 전환

## 7. 폐기

자격증명 revoke, 필요한 저장소 push/백업, Tailscale 장치 제거, Lightsail 스냅샷 확인 후에만
Terraform destroy를 실행한다.

```powershell
terraform -chdir=service/remote-lightsail/terraform destroy
```

## 참고 근거

- [Orca Headless Linux Server](https://github.com/stablyai/orca/blob/main/docs/reference/headless-linux-server.md)
- [Orca Remote Servers](https://www.onorca.dev/docs/remote-servers)
- [OpenAI Codex authentication](https://learn.chatgpt.com/docs/auth)
- [Amazon Lightsail instance bundles](https://docs.aws.amazon.com/lightsail/latest/userguide/amazon-lightsail-bundles.html)

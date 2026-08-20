# Lightsail 4GB Orca 호스트 구축 계획

> 상태: **계획 단계. 아직 아무 자원도 생성되지 않음.** 이 문서의 명령을 실행하는 시점부터 과금이 시작됩니다.
>
> 아래 Phase 1~9는 [`scripts/`](../scripts/)에 실행 가능한 스크립트로 옮겨져 있습니다.
> 이 문서가 정본이고 스크립트는 그 절차의 자동화입니다 — 순서와 실행 위치는
> [`scripts/README.md`](../scripts/README.md)를 보세요.

## 0. 목표와 완료 조건

**목표** — 어느 위치·어느 데스크탑에서든 항상 접근 가능한 개발환경. 에이전트·터미널·워크트리는
클라우드의 단일 호스트에서만 돌고, 접속하는 기기는 화면만 가져간다.

**설계 원칙 (이번 방향 전환의 핵심)**

1. **접속하는 쪽 PC는 절대 건드리지 않는다.** VPN 클라이언트 설치, 방화벽 규칙 추가,
   포트 개방, 상시 프로세스 등록 — 어느 것도 하지 않는다. 앱을 깔거나 브라우저를 여는 게 전부다.
2. **모든 보안 경계는 서버 쪽에 둔다.** 노출되는 대상은 개인 PC가 아니라 언제든 스냅샷 찍고
   갈아엎을 수 있는 격리된 VM이다.
3. **공개 포트는 443 하나.** 런타임 포트는 인터넷에 직접 노출하지 않는다.

**완료 조건 (Definition of Done)**

- [ ] 임의의 데스크탑에서 Orca 앱 설치 + 페어링 링크만으로 접속된다 (네트워크 설정 0)
- [ ] 아무것도 설치할 수 없는 PC에서 브라우저만으로 접속된다
- [ ] 클라이언트를 모두 끄고 다음 날 다시 붙어도 터미널·에이전트 세션이 그대로 살아있다
- [ ] 서버 재부팅 후 사람 개입 없이 런타임이 자동 복구된다
- [ ] Lightsail 방화벽에 열린 인바운드 포트가 443 하나뿐이다

---

## 1. 최종 아키텍처

```
 ┌──────────────────────── Lightsail (ap-northeast-2, 4GB) ────────────────────────┐
 │                                                                                 │
 │   Caddy  :443  ──TLS 종단 + WebSocket 프록시──▶  Orca 헤드리스  :4224           │
 │     │                                            (systemd, 자동 재시작)         │
 │     │                                              ├─ 워크트리 / 터미널          │
 │     │                                              ├─ Claude · Codex 세션        │
 │     └─ Let's Encrypt 자동 갱신                     └─ 웹 클라이언트 번들         │
 │                                                                                 │
 │   Lightsail 방화벽: 인바운드 443만 개방                                          │
 └─────────────────────────────────┬───────────────────────────────────────────────┘
                                   │  https / wss  (인터넷)
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
   데스크탑 Orca 앱           브라우저 (설치 불가 PC)      모바일 Orca 앱
   페어링 링크 입력            /web-index.html            페어링 코드 입력
        │                          │                          │
        └────────── 로컬 PC 설정 변경: 없음 ──────────────────┘
```

**왜 리버스 프록시인가** — Orca 런타임은 평문 WebSocket(ws)이다. 브라우저는 HTTPS 페이지에서
평문 ws로 붙는 것을 막기 때문에(앱 내부 메시지: *"This HTTPS page cannot connect to a plain ws://
Orca server. Open the web client over HTTP or pair with a wss:// endpoint."*), 브라우저 접속을
지원하려면 wss 종단이 반드시 필요하다. Caddy가 그 역할과 인증서 자동 갱신을 함께 맡는다.

---

## 2. 사전 준비

| 항목 | 내용 |
|---|---|
| AWS 계정 | 서울 리전(ap-northeast-2) 사용. Lightsail 조회 권한은 확인됨, **생성 권한은 실행 시 확인 필요** |
| 도메인 | 보유 도메인이 있으면 A 레코드 1개. 없으면 `<고정IP>.sslip.io`로 진행 가능 (Let's Encrypt 발급됨) |
| SSH 키 | Lightsail 키페어 신규 생성 또는 기존 공개키 임포트 |
| GitHub | 레포 클론용. 서버에서 `gh auth login` (device flow) |
| 에이전트 계정 | Claude / Codex — 서버에서 device auth로 로그인 (브라우저 코드 입력) |

**비용**: Medium-4GB Linux(public IPv4) **$24/mo 정액** (2 vCPU / 4GB / 80GB SSD / 4TB 전송 포함).
수동 스냅샷은 별도 (GB당 과금). 인스턴스를 삭제하면 과금이 멈춘다.

---

## 3. 단계별 구축

### Phase 1 — 인스턴스 생성

```bash
export AWS_PAGER=""
REGION=ap-northeast-2
NAME=orca-host

# 키페어: 기존 공개키를 임포트하거나(권장) 신규 생성
aws lightsail import-key-pair --region $REGION \
  --key-pair-name orca-host-key \
  --public-key-base64 "$(base64 -w0 ~/.ssh/id_ed25519.pub)"

aws lightsail create-instances --region $REGION \
  --instance-names $NAME \
  --availability-zone ${REGION}a \
  --blueprint-id ubuntu_24_04 \
  --bundle-id medium_3_0 \
  --key-pair-name orca-host-key \
  --tags key=project,value=orca-host

# 재부팅해도 주소가 바뀌지 않도록 고정 IP 부착
aws lightsail allocate-static-ip --region $REGION --static-ip-name ${NAME}-ip
aws lightsail attach-static-ip  --region $REGION --static-ip-name ${NAME}-ip --instance-name $NAME
aws lightsail get-static-ip     --region $REGION --static-ip-name ${NAME}-ip --query 'staticIp.ipAddress' --output text
```

- `medium_3_0` = 4GB 번들. `ubuntu_24_04` = Ubuntu 24.04 LTS. 두 값 모두 서울 리전에서 조회 확인됨.
- 실패하면 IAM 권한 문제일 가능성이 높다 (`lightsail:CreateInstances` 등).

### Phase 2 — 방화벽을 먼저 좁힌다

Lightsail은 기본으로 22와 80을 연다. 구축 중에는 SSH만, 완료 후에는 443만 남긴다.

```bash
# 구축 단계: SSH는 내 현재 공인 IP에서만. 80/443은 인증서 발급 때문에 열어둔다.
aws lightsail put-instance-public-ports --region $REGION --instance-name $NAME \
  --port-infos fromPort=22,toPort=22,protocol=TCP,cidrs=<MY_IP>/32 \
               fromPort=80,toPort=80,protocol=TCP \
               fromPort=443,toPort=443,protocol=TCP
```

> **80/443을 함께 여는 이유** — Phase 6의 Let's Encrypt 발급은 ACME 챌린지가 인터넷에서
> 도달해야 성립한다(HTTP-01은 80, TLS-ALPN-01은 443). 구축 단계에 22만 열어두면
> Phase 6에서 인증서를 받지 못한다. 발급이 끝나면 Phase 7이 443 하나만 남긴다 —
> **최종 상태는 그대로 443 하나다.**

> `put-instance-public-ports`는 **기존 규칙을 통째로 교체**한다. 매번 최종 상태 전체를 적어야 한다.

가정용 회선은 IP가 바뀔 수 있다. 바뀌어서 잠기면 **Lightsail 콘솔의 브라우저 SSH**로 들어가
규칙을 갱신하면 된다 — 이 경로가 있기 때문에 22를 아예 닫는 최종 상태가 가능하다.

### Phase 3 — 기본 툴체인과 여유 메모리

```bash
ssh ubuntu@<STATIC_IP>

sudo apt-get update && sudo apt-get upgrade -y
# Orca 원격 터미널에는 빌드 도구가 필요하다 (없으면 파일/깃/에디터는 되지만 터미널이 안 뜬다)
sudo apt-get install -y build-essential python3 git curl ca-certificates unzip

# 4GB에서 빌드가 도는 만큼 스왑 2GB를 깔아둔다
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Node (에이전트 CLI와 프로젝트 빌드에 사용)
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs

# 보안 패치 자동 적용
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades
```

### Phase 4 — Orca 설치

```bash
DEB_URL=$(curl -fsSL https://api.github.com/repos/stablyai/orca/releases/latest \
  | grep -o 'https://[^"]*orca-ide_[^"]*_amd64\.deb' | head -1)
curl -fsSLO "$DEB_URL"
sudo apt-get install -y ./orca-ide_*_amd64.deb

orca status
```

> **리스크**: Orca는 Electron 앱이고 서버에는 디스플레이가 없다. `orca serve`는 헤드리스 서버용으로
> 문서화된 경로지만, 그래픽 라이브러리 의존성 때문에 기동에 실패할 수 있다.
> 그럴 경우 `sudo apt-get install -y xvfb` 후 systemd `ExecStart`를 `xvfb-run -a /usr/bin/orca serve ...`로
> 감싸는 것이 표준 우회다. **이 단계가 이 계획에서 가장 불확실한 지점이므로 여기서 한 번 검증하고 넘어간다.**

### Phase 5 — 런타임을 systemd 서비스로

`/etc/systemd/system/orca-serve.service`

```ini
[Unit]
Description=Orca headless runtime
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=ubuntu
Environment=HOME=/home/ubuntu
ExecStart=/usr/bin/orca serve --port 4224 --pairing-address wss://<DOMAIN>
Restart=always
RestartSec=5
# 4GB 박스에서 런타임이 메모리를 독점하지 않도록
MemoryMax=2G

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now orca-serve
systemctl status orca-serve
```

- `--pairing-address`는 **클라이언트에게 광고할 주소만** 바꾼다. 실제 바인딩은 로컬 4224 그대로이고,
  외부에서 4224로 직접 붙는 경로는 Lightsail 방화벽이 막는다.
- 페어링 링크는 서비스 로그에 나온다: `journalctl -u orca-serve -n 100`.
  **이 링크는 비밀번호와 동급이다.** 옮길 때 메신저·이슈·문서에 남기지 않는다.

### Phase 6 — Caddy로 HTTPS/WSS 종단

```bash
sudo apt-get install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt-get update && sudo apt-get install -y caddy
```

`/etc/caddy/Caddyfile`

```
<DOMAIN> {
    encode zstd gzip

    # 선택: Orca 페어링 토큰 앞에 인증을 한 겹 더 둔다
    # basic_auth {
    #     <USER> <BCRYPT_HASH>     # caddy hash-password 로 생성
    # }

    reverse_proxy 127.0.0.1:4224
}
```

```bash
sudo systemctl reload caddy
```

- Caddy는 WebSocket 업그레이드를 자동 처리하고 Let's Encrypt 인증서를 자동 발급·갱신한다.
- 인증서 발급 중에는 80이 열려 있어야 할 수 있다(HTTP-01). 발급 후 80은 닫아도 갱신은
  TLS-ALPN으로 이어진다. 발급이 실패하면 80을 잠시 열고 재시도한다.
- 도메인이 없으면 `<STATIC_IP>.sslip.io`를 그대로 쓸 수 있다.

### Phase 7 — 최종 방화벽: 443만

```bash
aws lightsail put-instance-public-ports --region $REGION --instance-name $NAME \
  --port-infos fromPort=443,toPort=443,protocol=TCP

aws lightsail get-instance-port-states --region $REGION --instance-name $NAME --output table
```

이후 서버 접속은 **Lightsail 콘솔의 브라우저 SSH**를 쓴다. SSH를 상시로 열어둘 이유가 없다.

### Phase 8 — 에이전트 CLI 인증 (대화형, 사람이 직접)

```bash
# Claude Code
npm i -g @anthropic-ai/claude-code && claude      # 출력되는 URL/코드로 브라우저 인증

# Codex
npm i -g @openai/codex && codex
```

자동화 불가 구간이다. 화면에 뜨는 코드를 사람이 브라우저에 입력해야 한다.

### Phase 9 — 레포 등록

```bash
gh auth login                      # device flow
mkdir -p ~/orca && cd ~/orca
git clone https://github.com/tkddls8848/gong-go.git
git clone https://github.com/tkddls8848/homepage.git
git clone https://github.com/tkddls8848/naraapi.git
git clone https://github.com/tkddls8848/pathfinder.git
git clone https://github.com/tkddls8848/devlog.git

for r in gong-go homepage naraapi pathfinder devlog; do orca repo add --path ~/orca/$r; done
orca repo list
```

### Phase 10 — 클라이언트 연결

| 기기 | 방법 |
|---|---|
| 데스크탑 (설치 가능) | Orca 설치 → Settings → Remote Orca Servers → Add Server → 페어링 링크 붙여넣기.<br>CLI로는 `orca environment add --name cloud --pairing-code "<링크>"` |
| 설치 불가 PC | 브라우저에서 `https://<DOMAIN>/web-index.html` → 페어링. 일부 데스크탑 전용 기능은 제한됨 |
| 모바일 | 앱 계정 메뉴에서 페어링 코드 발급 후 입력. 코드는 몇 분 뒤 만료되므로 그때그때 새로 발급 |

**어느 경우에도 접속하는 PC의 네트워크 설정은 건드리지 않는다.**

---

## 4. 검증 체크리스트

```bash
systemctl is-active orca-serve caddy          # 둘 다 active
curl -I https://<DOMAIN>/web-index.html       # 200
aws lightsail get-instance-port-states --region ap-northeast-2 \
  --instance-name orca-host --output table    # 443만
free -h                                        # 스왑 잡혀 있는지
journalctl -u orca-serve --since "10 min ago" # 에러 없는지
```

그리고 실제 시나리오로:

1. 데스크탑에서 붙어 워크트리를 만들고 에이전트를 돌린다
2. 클라이언트를 완전히 종료한다
3. 다른 기기(또는 브라우저)로 붙어 **같은 세션이 그대로인지** 확인한다
4. `sudo reboot` 후 사람 개입 없이 다시 붙는지 확인한다

---

## 5. 운영

| 작업 | 명령 / 방법 |
|---|---|
| 스냅샷 | `aws lightsail create-instance-snapshot --region ap-northeast-2 --instance-name orca-host --instance-snapshot-name orca-host-$(date +%Y%m%d)` (GB당 과금) |
| 스펙 상향 | 스냅샷 → 상위 번들로 새 인스턴스 생성 → 고정 IP 재부착 |
| Orca 업데이트 | 최신 .deb 재설치 후 `sudo systemctl restart orca-serve` |
| 로그 | `journalctl -u orca-serve -f`, `journalctl -u caddy -f` |
| 접근 회수 | Orca 설정의 Shared Server Access에서 개별 grant 취소 |
| 비용 확인 | AWS Billing 콘솔. 정액이라 예측 가능 |
| 완전 삭제 | `aws lightsail delete-instance --instance-name orca-host` + `release-static-ip` (과금 중단) |

---

## 6. 리스크와 대응

| 리스크 | 영향 | 대응 |
|---|---|---|
| **Electron 헤드리스 기동 실패** | 구축 중단 | Phase 4에서 선검증. 실패 시 `xvfb-run`으로 래핑 |
| 443이 인터넷에 공개됨 | 스캐너 노출 | Caddy basic_auth 추가, Orca 페어링 토큰, fail2ban, 접근 로그 주기 확인 |
| 페어링 링크 유출 | 런타임 무단 접근 | Shared Server Access에서 즉시 회수. 링크를 평문으로 남기지 않기 |
| 4GB 부족 | 빌드 실패, OOM | 스왑 2GB 선반영. 지속되면 8GB($44) 번들로 상향 |
| 가정 IP 변동으로 SSH 잠김 | 접속 불가 | Lightsail 브라우저 SSH 콘솔로 우회 (최종 상태에서는 22를 아예 닫음) |
| 인증서 발급 실패 | 브라우저 접속 불가 | 80을 잠시 열고 재발급. 도메인 없으면 `sslip.io` |
| 로컬에만 있던 환경 이관 누락 | 일부 작업 불가 | Docker·에뮬레이터·로컬 DB는 서버에 별도 구성 필요. 4GB에서는 Docker 동시 사용에 주의 |

---

## 7. 이번 계획에서 **하지 않는** 것

- 접속하는 PC에 VPN·터널·에이전트 설치 — **하지 않는다**
- 로컬 방화벽 규칙 추가/변경, 포트 개방 — **하지 않는다**
- 공유기 포트포워딩 — **하지 않는다**
- 로컬 PC에 상시 프로세스·예약 작업 등록 — **하지 않는다**
- 개인 PC를 외부에 노출 — **하지 않는다**

접속하는 쪽에서 하는 일은 앱을 설치하거나 브라우저 주소창에 URL을 넣는 것, 그리고 페어링 링크를
붙여넣는 것뿐이다.

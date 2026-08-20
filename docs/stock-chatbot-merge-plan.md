# stock_chatbot을 orca-host로 통합하는 구현 계획

> 상태: **계획 단계.** 아직 아무것도 옮기지 않았다. 이 문서는 두 Lightsail 인스턴스를
> 하나로 합치는 절차와, 합치기 전에 손봐야 할 코드·문서를 적은 실행 계획서다.
>
> 대상 저장소는 둘이다 — 호스트 쪽은 이 저장소(`remote_coding`), 앱 쪽은
> [`tkddls8848/stock_chatbot`](https://github.com/tkddls8848/stock_chatbot).

## 0. 현재 상태와 목표

|                | stock_chatbot            | orca-host (이 저장소)             |
| -------------- | ------------------------ | ------------------------------ |
| 번들           | `micro_3_0` 1GB / 2 vCPU · **$7/mo** | `medium_3_0` 4GB / 2 vCPU · **$24/mo** |
| 프로비저닝     | Terraform (`iac/terraform`, state는 로컬) | 셸 스크립트 (`scripts/01~09`) |
| 공개 포트      | 22만 (`allowed_ssh_cidrs`로 좁힘) | 최종 443만 (22는 닫음) |
| 서비스         | `stock-chatbot.service`  | `orca-serve.service` + Caddy   |
| 백업           | 자동 스냅샷 19:00 UTC + `cron` tar 03:00 KST | 없음 |

**목표** — orca-host 하나만 남기고 stock_chatbot 인스턴스를 폐기한다. 반대 방향은
성립하지 않는다. 1GB에서 Electron 런타임과 에이전트 CLI는 뜨지 않는다.

**절감액은 $7/mo가 전부다.** 그러므로 이 통합의 판단 기준은 비용이 아니라
**24시간 도는 운영 봇을, 에이전트가 재부팅·빌드·OOM을 일으키는 개발 호스트에
같이 올려도 되는가**다. 3절의 격리 장치를 함께 넣는 조건에서만 진행한다.

**완료 조건**

- [ ] orca-host에서 `stock-chatbot.service`가 `enabled` + `active`이고 재부팅 후 자동 복구된다
- [ ] `data/`(관심종목·뉴스·리서치·Polymarket 상태)가 손실 없이 넘어왔다
- [ ] 같은 텔레그램 토큰으로 도는 프로세스가 **한 순간도 둘이 아니었다**
- [ ] 자동 스냅샷과 백업 cron이 orca-host에서 돌고 있다
- [ ] 옛 인스턴스와 고정 IP가 삭제되어 과금이 $24/mo로 떨어졌다
- [ ] 양쪽 저장소의 문서가 새 구조를 가리킨다 (7절)

> **선행 확인.** 이 저장소의 `README.md`와 `docs/lightsail-plan.md`는 아직
> "클라우드 자원 미생성"으로 되어 있다. 실제로 떠 있다면 그 표기부터 갱신하고
> 이 계획을 시작한다 — 두 문서가 어긋난 채로는 어느 쪽이 사실인지 알 수 없다.

---

## 1. 최종 배치

```
 ┌───────────────── Lightsail orca-host (ap-northeast-2, medium_3_0 4GB) ─────────────────┐
 │                                                                                        │
 │   Caddy :443 ──TLS/WSS──▶ orca-serve :4224          stock-chatbot.service              │
 │                            User=ubuntu                User=stockbot                    │
 │                            MemoryMax=2G               MemoryMax=<실측>                 │
 │                              │                          │                              │
 │                              ├─ ~/orca/<repo>           ├─ /srv/stock-chatbot (운영)   │
 │                              └─ ~/orca/stock_chatbot    │   ├─ .env  (stockbot 600)    │
 │                                 (개발용 클론)            │   └─ data/  ← 백업·스냅샷 대상 │
 │                                                         └─ webadmin 127.0.0.1:8787     │
 │                                                                                        │
 │   공개 포트: 443 하나. 봇은 인바운드를 쓰지 않는다(텔레그램 롱폴링 = 아웃바운드).      │
 └────────────────────────────────────────────────────────────────────────────────────────┘
```

봇을 올리는 방식은 **호스트 systemd 유닛 직접 등록**이다. Docker는 4GB에서 Orca와
겹치는 부담이 크고(`lightsail-plan.md` 6절도 주의로 적고 있다), 리소스 제한과 자동
재시작은 systemd cgroup으로 동일하게 얻는다.

---

## 2. 소유권 분할 — 어느 저장소가 무엇을 책임지나

지금은 두 저장소가 각자 인스턴스를 소유한다. 통합 후에는 **호스트는 이 저장소, 앱은
stock_chatbot**으로 가른다. 경계를 흐리면 다음 사람이 유닛 파일을 어디서 고쳐야 하는지
알 수 없게 된다.

| 대상 | 소유 | 위치 |
|---|---|---|
| 인스턴스·고정 IP·방화벽·스냅샷 애드온 | **remote_coding** | `scripts/01`, `02`, `07` |
| 호스트 공통 설정 (스왑, Node, TZ, 보안 패치) | **remote_coding** | `scripts/03-host-base.sh` |
| 봇 운영 클론 + 설치 호출 | **remote_coding** | `scripts/10-stock-chatbot.sh` (신설) |
| venv·`.env` 골격·systemd 유닛·백업 cron | **stock_chatbot** | `iac/host/install.sh` (신설) |
| 배포 갱신·설정 변경·장애 대응 절차 | **stock_chatbot** | `docs/server-ops.md` |

`iac/host/install.sh`는 현재 `iac/terraform/user_data.sh.tftpl`의 5·6·7·9절(venv,
`.env` 골격, systemd 유닛, 백업 cron)을 그대로 옮긴 것이다. 유닛 정의가 앱 저장소에
남아야 `WorkingDirectory=app/`(없으면 `ModuleNotFoundError: core`)과
`MPLBACKEND=Agg`(없으면 `/market` 차트 실패) 같은 앱 사정이 앱 쪽 변경으로 따라간다.

`stock_chatbot/iac/terraform`은 6단계에서 `destroy` 후 폐기한다.

> **`user_data.sh.tftpl`의 dash 제약은 `install.sh`에 따라오지 않는다.** 그 제약은
> Lightsail이 user_data를 `/bin/sh`로 실행하기 때문이었다. 새 스크립트는 사람이
> bash로 실행하므로 이 저장소의 다른 스크립트와 같은 스타일(`set -euo pipefail`,
> `lib.sh`)로 쓴다.

---

## 3. 격리 — 통합의 전제 조건

### 3.1 운영 체크아웃과 개발 워크트리를 나눈다

서비스는 `/srv/stock-chatbot`에서 돌고, 에이전트 작업용 클론은 `~/orca/stock_chatbot`에
따로 둔다. **같은 디렉터리를 쓰면 에이전트가 브랜치를 바꾸는 순간 운영 코드가 바뀐다.**
`scripts/09-repos.sh`의 `REPOS`에 `stock_chatbot`을 추가하는 것은 개발용 클론에만
해당하고, 운영 클론은 `10-stock-chatbot.sh`가 따로 만든다.

### 3.2 전용 계정으로 돌린다

`User=stockbot`으로 실행하고 `.env`는 `stockbot:stockbot 0600`으로 둔다. 에이전트가
쥔 `ubuntu` 계정이 `grep -r`로 텔레그램 토큰과 Cloudflare 자격증명을 우발적으로 읽는
경로를 막는다.

**완전한 차단은 아니다.** `ubuntu`는 sudo를 가지므로 마음먹으면 읽을 수 있고, 443이
공개된 호스트라 페어링 링크가 새면 봇 토큰까지 같은 반경에 들어온다. 이것은 통합으로
넓어지는 blast radius이고, $7/mo로 사던 격리를 파는 것이 이 결정의 실질이다 —
줄이는 것이지 없애는 것이 아니다.

### 3.3 텔레그램 단일 폴링은 불변식이다

같은 토큰으로 두 프로세스가 `getUpdates`를 치면 텔레그램이
`Conflict: terminated by other getUpdates request`를 돌려주고 **양쪽이 번갈아 죽는다.**
개발 워크트리에서 에이전트가 `python app/bot.py`를 실행하면 그 순간 운영 봇이 죽는다.
따라서 개발 클론의 `.env`에는 **토큰을 넣지 않는다**(테스트는 외부 API를 mock하므로
토큰 없이 돈다). 운영 `.env`는 3.2의 권한으로 분리한다.

---

## 4. 이관 전에 손봐야 할 코드

### 4.1 사전선별 CPU 예산 상수

`app/core/config.py`의 `NEWS_PREFILTER_LIGHTSAIL_*`는 `micro_3_0`(2 vCPU × baseline
10% = 하루 4.8 vCPU-hour) 기준이고, `CLAUDE.md`가 "bundle을 바꾸면 이 두 상수도 함께
바꾼다"고 못박아 두었다. `medium_3_0`의 baseline은 **문서 값을 믿지 말고** Lightsail
콘솔 CPU 그래프의 sustainable zone으로 확인한 뒤 반영한다.

다만 상수를 올리는 것이 곧 정답은 아니다. 통합 후에는 두 가지가 어긋난다.

- `account_foreground_cpu`가 쓰는 `time.process_time()`은 **봇 프로세스만** 계량한다.
  같은 호스트의 Orca·에이전트·빌드가 태우는 CPU는 예산에 잡히지 않으므로, 상수만 올리면
  둘이 합쳐 버스트 크레딧을 갉아먹는다.
- 반대로 `NEWS_PREFILTER_MAX_LOAD_AVERAGE = 1.5`는 **시스템 전체** load를 본다.
  2 vCPU 박스에서 에이전트가 돌면 상시 1.5를 넘고, 그러면 사전선별 보정이 영구히
  물러나 승격 판정에 필요한 관측이 쌓이지 않는다.

**초기값 제안** — baseline 실측치로 상수를 올리되 `NEWS_PREFILTER_CPU_RESERVE_RATIO`를
0.25 → 0.5로 함께 올려 봇이 쓰는 **절대량은 micro 시절과 비슷하게** 둔다.
`MAX_LOAD_AVERAGE`는 2.0~2.5로 올린다. 1~2주간
`journalctl -u stock-chatbot | grep PREFILTER`로 실측한 뒤 재조정한다.

### 4.2 systemd 리소스 제한

| 유닛 | 설정 | 왜 |
|---|---|---|
| `stock-chatbot` | `MemoryMax=<실측 후 512M~768M>` | 4GB를 Orca(2G)·에이전트·빌드와 나눈다 |
| `stock-chatbot` | `OOMScoreAdjust=-500` | OOM 때 빌드·에이전트가 먼저 죽게 한다 |
| `stock-chatbot` | `CPUWeight=200` | 뉴스 주기·텔레그램 응답이 빌드에 밀리지 않게 |
| `orca-serve` | `CPUWeight=100` (기본) | 대화형이라 지연에 민감하지만 24/7 일정은 없다 |

`MemoryMax`는 추측으로 정하지 않는다. 옛 인스턴스에서
`systemctl status stock-chatbot | grep Memory`로 정상 구간의 실측치를 먼저 확보하고,
피크(`/market` 차트 생성, pandas 임포트)에 여유를 얹는다.

### 4.3 호스트 준비에서 빠진 것 둘

`scripts/03-host-base.sh`는 (a) **타임존을 설정하지 않고** (b) **`python3-venv`를 깔지
않는다.** 봇의 "지금"은 `core/clock.py`가 KST로 고정하므로 하루 경계는 무관하지만,
**백업 cron과 journal 시각은 호스트 타임존을 따른다** — UTC로 두면 `0 3 * * *`가
12:00 KST에 돌아 04:00 KST 스냅샷에 그날 tar가 들어가지 않는다.
`10-stock-chatbot.sh`에 `timedatectl set-timezone Asia/Seoul`과
`apt-get install -y python3-venv`를 넣는다.

### 4.4 자동 스냅샷 애드온

지금 애드온은 stock_chatbot 인스턴스에 붙어 있다. `data/`가 orca-host로 옮겨가므로
애드온도 함께 옮긴다(19:00 UTC = 04:00 KST, 03:00 KST tar 뒤).

```bash
aws lightsail enable-add-on --region ap-northeast-2 \
  --resource-name orca-host \
  --add-on-request addOnType=AutoSnapshot,autoSnapshotAddOnRequest={snapshotTimeOfDay=19:00}
```

---

## 5. 관리 웹(8787)

`WEB_ADMIN_HOST`는 `127.0.0.1` 그대로 둔다. 최종 방화벽에서 22가 닫히므로
`terraform output -raw web_admin_tunnel_command`(SSH 터널)는 더 쓸 수 없다.
**기본 접근 경로는 Orca 웹 터미널**이고, 그 안에서 `curl`로 확인한다.

브라우저로 보고 싶으면 Caddy에 별도 호스트명 + `basic_auth` + IP allowlist 라우트를
추가하는 선택지가 있다(평문 노출은 아니게 된다). **기본안에는 넣지 않는다** —
필요해질 때 별도 결정으로 다룬다.

---

## 6. 전환 절차

전환 창은 **11:00~23:00 KST의 정각 직후**다. 07:00(야간 다이제스트)과
08:35~10:35(Polymarket 스냅숏, 재시도 포함)을 피한다 — APScheduler jobstore가 메모리라
꺼져 있는 동안 지나간 스케줄은 따라잡지 않는다.

### 단계 1 — 사전 준비 (창 밖에서 해도 된다)

1. stock_chatbot의 작업 브랜치를 `main`에 병합·푸시. 서버는 `main`을 pull한다.
2. 양쪽 인스턴스 수동 스냅샷.
3. 옛 인스턴스에서 실측치 확보: `free -h`, `systemctl status stock-chatbot | grep Memory`,
   `journalctl -u stock-chatbot | grep PREFILTER | tail -20`.
4. 4.1~4.2의 코드 변경을 stock_chatbot `main`에 반영.

### 단계 2 — orca-host 준비 (봇을 기동하지 않는다)

```bash
# 서버 (ubuntu)
./scripts/10-stock-chatbot.sh      # TZ, python3-venv, stockbot 계정, 운영 클론, venv, 유닛, cron
systemctl is-enabled stock-chatbot # disabled 상태여야 정상 — 기동은 단계 4에서
```

부트스트랩이 봇을 기동하지 않는 규칙은 그대로 유지한다. `.env`가 비어 있어 지금 켜면
`ConfigurationError`로 죽고, 무엇보다 옛 봇이 아직 살아 있다(3.3).

### 단계 3 — 정지와 데이터 이관 (여기서부터 창 안)

```bash
# 옛 호스트
sudo systemctl stop stock-chatbot && sudo systemctl disable stock-chatbot
tar czf ~/cutover-data.tgz -C ~/stock_chatbot data
```

**전송 경로.** orca-host는 22가 닫혀 있어 옛 호스트에서 밀어 넣을 수 없다. 옛 호스트의
`allowed_ssh_cidrs`에 orca-host 고정 IP `/32`를 추가해 `terraform apply`하고,
**Orca 웹 터미널에서 당겨온다.** 방화벽 변경이 Terraform 관리 범위 안에 남는 쪽이라
콘솔에서 손으로 연 규칙이 다음 apply에 되돌려지는 사고가 없다.

```bash
# orca-host (Orca 터미널)
scp ubuntu@<OLD_IP>:~/cutover-data.tgz /tmp/
sudo -u stockbot tar xzf /tmp/cutover-data.tgz -C /srv/stock-chatbot
```

전송이 끝나면 `allowed_ssh_cidrs`를 원복하고 apply 한다.

### 단계 4 — `.env`와 기동

`.env`는 파일째 옮기되 `WEB_ADMIN_PASSWORD`는 새로 만든다(옛 호스트에서 유출된 적 없다는
보장이 필요 없어진다). 소유권과 권한은 3.2대로.

```bash
sudo chown stockbot:stockbot /srv/stock-chatbot/.env && sudo chmod 600 /srv/stock-chatbot/.env
sudo systemctl enable --now stock-chatbot
journalctl -u stock-chatbot -f
```

### 단계 5 — 검증

| 확인 | 기준 |
|---|---|
| `journalctl -u stock-chatbot` | `봇 시작됨. 활성 기능: ...` 목록이 기대와 같다 |
| 텔레그램에서 `/market` | 차트 이미지가 온다 (`MPLBACKEND=Agg` 확인) |
| `/system prefilter` | 화면이 그려지고 CPU 예산 줄이 새 상수를 반영한다 |
| `/system polymarket` | 두 축(백필·가동률)이 그려진다 |
| `free -h`, `uptime` | 스왑 여유가 있고 load가 상시 2를 넘지 않는다 |
| `systemctl is-enabled stock-chatbot orca-serve caddy` | 셋 다 `enabled` |
| `aws lightsail get-instance-port-states` | **443 하나** |

### 단계 6 — 관망과 정리

**24~72시간** 관망한다. 옛 인스턴스는 **stopped로 남긴다** — Lightsail은 정지 상태도
과금하지만 그 며칠치가 되돌릴 지점의 값이다. 그 사이 07:00 다이제스트 1회, 08:35
Polymarket 스냅숏 1회, 야간 큐 한 사이클이 지나가는 것을 확인한다.

정리:

```bash
# 옛 인스턴스 최종 스냅샷 후 (로컬, stock_chatbot 저장소)
cd iac/terraform && terraform destroy      # 고정 IP도 함께 사라진다
```

고정 IP가 인스턴스에서 분리된 채 1시간이 지나면 $0.005/시간이 붙는다. `destroy`는
둘 다 지우므로 이 문제는 생기지 않지만, 삭제 후 `aws lightsail get-static-ips`로
남은 것이 없는지 한 번 본다.

### 되돌리기

되돌리는 순서는 전환의 역순이고, 불변식은 여전히 3.3 하나다.

1. orca-host에서 `sudo systemctl stop stock-chatbot && sudo systemctl disable stock-chatbot`
2. 그 사이 orca-host에서 쌓인 `data/`를 tar로 회수 (돌려놓지 않으면 그만큼 잃는다)
3. 옛 인스턴스 start → `data/` 반영 → `systemctl enable --now stock-chatbot`

`terraform destroy`를 실행한 뒤에는 이 경로가 없다. 그래서 6단계의 관망이 파괴 앞에 있다.

---

## 7. 함께 갱신할 문서

| 저장소 | 문서 | 무엇을 |
|---|---|---|
| remote_coding | `README.md` | "미생성" 표기 해제, 호스트가 봇도 함께 돌린다는 사실과 이 문서 링크 |
| remote_coding | `docs/lightsail-plan.md` | Phase 10 뒤에 stock_chatbot 항목 추가, 재부팅 금지 창(07:00 / 08:35~10:35 KST) 명시 |
| remote_coding | `scripts/README.md` | `10-stock-chatbot.sh` 행 추가 |
| stock_chatbot | `iac/terraform/README.md` | 인스턴스 생성 절차를 폐기하고 "호스트는 remote_coding이 소유"로 재작성 |
| stock_chatbot | `docs/server-ops.md` | 1절(접속 — 브라우저 SSH / Orca 터미널), 3절(경로 `/srv/stock-chatbot`, 계정 `stockbot`), 9절(스냅샷 주체) |
| stock_chatbot | `CLAUDE.md` | 배포 절 — 유일한 배포 문서가 무엇인지 |

**재부팅 창 규칙이 이 저장소로 넘어온다는 점이 핵심이다.** 지금까지 개발 편의로
자유롭게 재부팅하던 호스트가, 통합 후에는 놓치면 그날 Polymarket 가동률에서 하루를
깎는 스케줄을 지고 있다.

---

## 8. 리스크

| 리스크 | 영향 | 대응 |
|---|---|---|
| 개발 워크트리에서 봇을 실행 | 운영 봇이 `Conflict`로 죽는다 | 3.1 경로 분리 + 개발 `.env`에 토큰 없음 |
| 에이전트가 `.env`를 읽는다 | 토큰·자격증명 노출 | 3.2 계정 분리 (sudo 경로는 남는다 — 감수) |
| load가 상시 1.5 초과 | 사전선별 보정이 영구히 굶는다 | 4.1 `MAX_LOAD_AVERAGE` 상향 + 실측 재조정 |
| 4GB를 Orca·봇·빌드가 나눠 씀 | OOM으로 봇이 죽는다 | 4.2 `MemoryMax`·`OOMScoreAdjust`, 스왑 2G는 이미 있음 |
| 호스트 TZ가 UTC | 백업 tar가 스냅샷에 안 들어간다 | 4.3 `timedatectl set-timezone Asia/Seoul` |
| 전환 중 이중 폴링 | 양쪽이 번갈아 죽는다 | 6단계 3 → 4 순서 (정지 후 기동) |
| 개발 편의 재부팅 | Polymarket 하루치가 빈다 | 7절 문서화된 창 준수 |
| 통합 자체 (blast radius) | 개발 호스트 사고가 곧 봇 정지 | 관망 기간 유지, 옛 인스턴스를 곧바로 지우지 않음 |

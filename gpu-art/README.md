# gpu-art — 그림 생성 전용 GPU 서버

게임 그림(로컬 Qwen-Image-Edit-2511 + ComfyUI)을 노트북 대신 GPU 서버에서 그린다. 두 갈래가 있다.

| | **RunPod** (`runpod/`, 기본) | AWS EC2 (`terraform/` · `scripts/`) |
|---|---|---|
| 맞는 쓰임 | **작업할 때만 몰아서 켠다** | 늘 같은 서버 · AWS 계정 안에 두고 싶을 때 |
| GPU | RTX PRO 4500 Blackwell 32GB · RAM 50GB · 8 vCPU (대체 후보 없음) | L4 24GB (g6.2xlarge) |
| 값(대략) | 켠 동안 시간당 약 0.75달러 · **꺼 두면 0원** | 시간당 약 1.2달러 · 꺼 두면 디스크 100GB 한 달 약 10달러 |
| 켜고 끄기 | 팟을 만들고 통째로 지운다(켤 때마다 모델까지 새로 받는다) | 인스턴스를 켜고 끈다 |
| 붙는 길 | SSH 터널(공개키로만) | Tailscale |

## RunPod — 작업할 때만 켜기

```text
관리 PC (게임 도구 · Claude Code)
  └─ SSH 터널 127.0.0.1:8188 ──> RunPod 팟 (pytorch/pytorch 이미지, 아무 데이터 센터)
                                   ├─ sshd :22  ← 공개 포트는 이것 하나, 공개키로만
                                   ├─ ComfyUI 127.0.0.1:8188  ← 인증이 없으므로 터널로만
                                   ├─ /opt = 팟 디스크(ComfyUI · venv · models) — 켤 때마다 새로 조립
                                   └─ 30분 놀면 팟이 스스로 지운다(남는 것 없음)
```

저장 공간을 두지 않는다. 그린 그림은 게임 도구가 바로 받아 가고, 나머지(ComfyUI · 모델)는 판이 고정되어 있어
켤 때마다 다시 받으면 된다. 그래서 꺼 둔 동안 값이 없고, 저장 공간이 있는 데이터 센터에 묶이지 않아 GPU 가
남은 곳 어디서나 켠다. 대신 켤 때마다 모델 약 48GB 를 받느라 5~15분 걸린다(받는 동안도 GPU 값이 나간다 —
한 번에 약 0.1달러). 한 달에 수십 번 켜지 않는 한 저장 공간(90GB 한 달 약 6.3달러)보다 싸다.

처음 한 번:
1. RunPod 가입 · 충전(처음 10~25달러면 충분).
2. RunPod 웹 → Settings → API Keys 에서 키를 만들어 최상위 `.env` 에 `RUNPOD_API_KEY=...`.
3. 관리 PC 에 SSH 키가 있어야 한다(`~/.ssh/id_ed25519` 등, 없으면 `ssh-keygen -t ed25519`).
   공개키는 `gpu.py` 가 팟에 실어 보낸다. Windows 는 OpenSSH 클라이언트(설정 → 선택적 기능)가 있으면 된다.
4. 예전에 네트워크 저장 공간(`art-gpu-models`)을 만들었다면 `python gpu-art/runpod/gpu.py destroy-volume --yes` 로 지운다.

```bash
python gpu-art/runpod/gpu.py start     # 팟 만들기 → SSH 터널 → ComfyUI 응답까지 (5~15분)
python gpu-art/runpod/gpu.py status
python gpu-art/runpod/gpu.py tunnel    # 노트북이 잠들었다 깨서 터널이 끊겼을 때
python gpu-art/runpod/gpu.py ssh       # 서버 안으로 (예: ssh tail -f /opt/art/boot.log)
python gpu-art/runpod/gpu.py stop      # 다 그렸으면 지운다 (안 지워도 30분 놀면 스스로 지운다)
```

터널이 관리 PC 의 `127.0.0.1:8188` 을 팟의 ComfyUI 로 넘기므로 게임 도구는 노트북 ComfyUI 때와 같은
`COMFY_URL=http://127.0.0.1:8188`(기본값)을 그대로 쓴다. 노트북 ComfyUI 를 같이 켜 둘 때만 `.env` 에
`RUNPOD_LOCAL_PORT=8189` 처럼 바꾸고 `COMFY_URL` 도 맞춘다. 터널은 `start` 를 실행한 PC 에서만 열린다.

유휴 감시는 그림 대기열 · GPU 사용 · SSH 셸 접속(`gpu.py ssh`)을 본다. ComfyUI 터널은 늘 붙어 있으므로
접속으로 치지 않는다. 준비 중에 실패하면 팟은 멈춰 기다리다가(`gpu.py ssh` 로 `/opt/art/boot.log` 를 볼 수 있다)
놀면 스스로 지운다.

판 · 모델은 AWS 쪽과 같다(아래 "판 고정" · `models.txt`). GPU · 데이터 센터 · 클라우드 종류는 `runpod/gpu.py` 의
`RUNPOD_*` 기본값이다 — 데이터 센터는 비워 두면 아무 곳, Community Cloud 는 `RUNPOD_CLOUD_TYPE=COMMUNITY`
(더 싸다, 공인 IP 가 있는 호스트만 고른다). 바꿀 때만 `.env` 에 같은 이름으로 적는다.

## AWS EC2

게임 그림을 AWS GPU 서버에서 그린다.
노트북(RTX 3060 Laptop 6GB · RAM 32GB)에서는 ComfyUI 가 RAM 을 약 23GB 써서 다른 작업과 같이
돌리면 멈췄다. 이 서버는 **그림만** 그린다 — 게임 저장소 · 게임 실행 · `.env` 의 다른 비밀은
노트북에 그대로 두고, 게임 도구가 Tailscale 너머의 ComfyUI 에 그림을 맡긴다.

```text
관리 PC (게임 도구 · Claude Code)
  └─ Tailscale ──> EC2 GPU (Ubuntu 24.04 · Deep Learning Base AMI)
                     ├─ comfyui.service  :8188  (tailscale0 주소에만 묶임)
                     ├─ /srv/comfy/ComfyUI/models  (gpu-art/models.txt)
                     └─ gpu-idle-stop.timer  (오래 놀면 스스로 중지)

관리 PC SSH ── 공인 IP /32 ──> 설치 · 복구용 ubuntu 계정
```

ComfyUI 에는 인증이 없다. 그래서 8188 은 보안 그룹에 열지 않고 Tailscale 로만 붙는다.
Orca 호스트(최상위 `terraform/`)와는 **state 를 나눈다** — 수명이 달라서(필요할 때만 켜고,
통째로 지웠다 다시 만들기도 한다) 같이 두면 한쪽 apply 가 다른 쪽을 건드릴 위험만 생긴다.

### 크기와 값 (도쿄, 대략 — 실제 값은 AWS 가격표로 확인)

| 종류 | GPU | vCPU / RAM | 시간당(온디맨드) |
|---|---|---|---|
| `g4dn.2xlarge` | T4 16GB | 8 / 32GB | 약 1.0달러 |
| **`g6.2xlarge`** (기본) | **L4 24GB** | **8 / 32GB** | **약 1.2달러** |
| `g5.2xlarge` | A10G 24GB | 8 / 32GB | 약 1.5달러 |

- 꺼져 있을 때는 디스크(gp3 100GB) 값만 낸다 — 한 달 약 10달러.
- 켜져 있는 동안은 공인 IPv4 값(시간당 0.005달러)이 더 붙는다.
- 24시간 내내 켜 두면 한 달 약 900달러. 유휴 타이머(기본 30분)가 깜빡 켜 둔 것을 막는다.
- `use_spot = true` 면 40~60% 싸지만 AWS 가 회수하면 그리던 한 장이 실패한다(디스크는 남는다).
- RAM 16GB 짜리(`*.xlarge`)는 받지 않는다 — 모델을 올리다 멈춘다.

### 처음 한 번

1. **GPU 한도 신청.** 새 계정은 G 인스턴스 vCPU 한도가 0 이다.
   Service Quotas → EC2 → *Running On-Demand G and VT instances* 를 **8** 이상으로(스팟이면
   *All G and VT Spot Instance Requests*). 승인에 하루에서 며칠 걸린다.
2. **권한.** 이 모듈은 EC2 의 인스턴스 · 키페어 · 보안 그룹과 AMI · VPC · 서브넷 조회,
   `DescribeInstanceTypeOfferings`, `Start/StopInstances` 를 쓴다.
3. **Tailscale.** 관리 PC 가 Orca 호스트와 같은 tailnet 에 이미 있으면 그대로 된다.
   서버 인증을 자동으로 하려면 최상위 `.env` 에 `GPU_TS_AUTHKEY=<auth key>` 를 한 줄 더한다(선택 —
   `.env.example` 에는 없다. 비우면 처음 설치할 때 인증 URL 을 출력하고 기다린다).
4. **기본 VPC** 가 있어야 한다(대부분의 계정에 있다).

### 만들기

Windows 는 Git Bash 에서(최상위 `scripts/util/provision-host.sh` 와 같다).

```bash
aws login                                   # 또는 aws configure
./gpu-art/scripts/provision.sh              # terraform apply → SSH 대기 → 스크립트 복사
```

그 다음 출력된 SSH 주소로 붙어 차례로 실행한다(모델 받기까지 20~30분).

```bash
cd ~/gpu-art/scripts
./install/01-base.sh        # 패키지 · 시간대 · GPU 확인
./install/02-tailscale.sh   # Tailscale (처음에는 인증 URL)
./install/03-comfyui.sh     # ComfyUI v0.39.0 + ComfyUI-GGUF, systemd
./install/04-models.sh      # models.txt 를 받고 sha256 확인
./install/05-idle-stop.sh   # 오래 놀면 스스로 중지
```

### 매일 쓰기

```bash
./gpu-art/scripts/gpu.sh start     # 켜고 ComfyUI 가 응답하면 COMFY_URL 을 알려 준다
./gpu-art/scripts/gpu.sh status
./gpu-art/scripts/gpu.sh stop      # 다 그렸으면 끈다 (안 꺼도 유휴 타이머가 끈다)
```

게임 저장소의 그림 도구는 `COMFY_URL` 을 읽는다(없으면 노트북의 `http://127.0.0.1:8188`).

```powershell
$env:COMFY_URL = "http://art-gpu-tokyo:8188"
python godot/tools/sd/qwen_faction.py barbarian
```

### 판 고정

판은 코드의 기본값이다. AWS 는 `scripts/lib.sh`, RunPod 는 `runpod/gpu.py` 가 읽으므로 두 곳을 같이 고친다.

| 무엇 | 판 | 어디서 바꾸나 |
|---|---|---|
| ComfyUI | `v0.39.0` (노트북과 같다) | `GPU_COMFY_VERSION` |
| ComfyUI-GGUF | `6ea2651` | `GPU_COMFY_GGUF_COMMIT` |
| gguf (pip) | `0.19.0` | `GPU_GGUF_PIP_VERSION` |
| PyTorch | cu128 색인의 최신 | `GPU_TORCH_INDEX_URL` (AWS 만) |
| 모델 | `models.txt` (sha256 고정) | 게임 저장소 `godot/tools/sd/MODELS.md` 와 같이 고친다 |
| AMI | 처음 만들 때의 최신 | 새 AMI 는 무시한다 — 바꾸려면 `terraform apply -replace=aws_instance.gpu` 후 설치를 다시 |

### 지우기

```bash
terraform -chdir=gpu-art/terraform destroy     # 서버 · 디스크(모델 포함) · 보안 그룹 · 키페어
```

모델은 다시 받으면 되므로(약 17GB, 몇 분) 디스크를 따로 남기지 않는다.

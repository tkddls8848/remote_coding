# forfun을 흡수해 이 저장소를 전용 인프라 저장소로 승격하는 계획

> 상태: **계획 단계.** 아직 아무것도 옮기지 않았고 아무것도 지우지 않았다.
> 이 문서는 [`tkddls8848/forfun`](https://github.com/tkddls8848/forfun)의 랩 인프라
> 코드를 이 저장소(`remote_coding`)로 이관하고, forfun을 폐기하기까지의 절차서다.
>
> **먼저 1절을 읽는다.** 조사 과정에서 이관 방식 자체를 바꾸게 한 사실이 넷 나왔다.
> 그중 하나(1-A, 유출된 API 키)는 이관과 무관하게 **오늘 처리해야 하는 것**이다.

## 0. 현재 상태와 목표

|                | remote_coding (이 저장소)          | forfun                                   |
| -------------- | -------------------------------- | ---------------------------------------- |
| 생성           | 2026-08-19                       | 2023-11-08                               |
| 공개 여부      | public                           | public                                   |
| 커밋           | 7                                | 177 (랩 코드를 건드린 것 112)            |
| 저장소 크기    | 81 KB                            | 20 MB (워킹트리는 4.1 MB)                |
| 내용           | orca-host 프로비저닝 — `terraform/`, `scripts/01~06`, `docs/` | 랩 13종 (`systems/`) + 검토 문서 4종 (`docs/`) |
| 스타 / 포크 / 이슈 | 0 / 0 / 0                    | 0 / 0 / 0                                |
| 라이선스       | 없음                             | 없음                                     |

**목표** — 이 저장소 하나만 남긴다. forfun의 `systems/` 랩 13종과 `docs/` 검토 문서를
이 저장소로 옮기고, forfun은 삭제한다.

forfun은 원래 "학습 내용의 결과물 저장소"였고 2024년 중반부터 인프라 랩 저장소로
성격이 바뀌었다. 그 전환이 히스토리에 그대로 남아 있다는 점이 이 계획의 난이도를
결정한다 (1절).

**완료 조건**

- [ ] 유출된 DeepSeek API 키가 폐기되었다 (1-A — 이관과 무관하게 선행)
- [ ] `systems/` 아래 랩 13종이 이 저장소에서 동작한다
- [ ] 이 저장소 크기가 4 MB 근처다 (forfun의 20 MB 히스토리가 딸려오지 않았다)
- [ ] `.gitignore`가 랩의 실제 경로(`systems/**`)를 덮는다 — VM 이미지·kubeconfig·join 시크릿
- [ ] `git ls-files --ignored --exclude-standard -c`가 비어 있다 (추적 중인데 무시되는 파일 없음)
- [ ] `git ls-files --eol`에 `w/crlf`가 하나도 없다
- [ ] `README.md`가 두 도메인(호스트 / 랩)을 모두 가리키고 깨진 링크가 없다
- [ ] forfun의 로컬 미러 백업이 있다 (PR ref 포함)
- [ ] forfun이 아카이브 → 삭제되었다

---

## 1. 먼저 알아야 할 네 가지

조사 결과다. 이 넷을 모르고 시작하면 잘못된 방식으로 이관하게 된다.

### A. 🚨 DeepSeek API 키가 공개 히스토리에 노출되어 있다

```
AI/n8n/deepseek.json:414
  "value": "Bearer sk-44a781d7c41a46609eed26a64f5b3d69"
```

**약 30개 커밋에 걸쳐 있고, forfun은 public이다.** 현재 트리에는 없지만 히스토리에
있으므로 커밋 SHA만 알면 지금도 읽힌다.

**이관 계획과 분리해서, 오늘 처리한다.** 저장소를 지우는 것은 대응이 아니다 —
이미 노출된 시간이 있고, 크롤러는 공개 저장소의 히스토리를 훑는다.

1. DeepSeek 콘솔에서 해당 키를 **폐기(revoke)**한다
2. 새 키를 발급하고, 어디에도 커밋하지 않는다
3. 청구 내역에 모르는 사용량이 있는지 확인한다

폐기하고 나면 이 키가 히스토리에 남아 있든 말든 무해해진다. 그래서 3절의 이관 방식이
"유출 키를 새 저장소로 들이지 않는다"만 만족하면 충분해진다.

> 현재 트리(`systems/`, `docs/`)는 따로 훑어봤고 **깨끗하다.** 실제 자격증명은 없고
> `<CEPH_ADMIN_KEY>` 같은 플레이스홀더뿐이다. 하나 예외는
> `systems/aws-kubeadm-storage-lab/ansible/roles/addons/defaults/main.yml:11`의
> `grafana_admin_password: "admin12345"`인데, 격리된 랩의 기본값이라 심각도는 낮다.
> 이관 후에 변수로 빼는 정도면 된다.

### B. ✅ main에서 탈락한 랩이 하나 있다 — 확인 완료, 조치하지 않는다

`local-gostore-vagrant` — Go 단일 바이너리 스토리지 랩. PR #2로 2026-08-18에
머지되었으나 이후 히스토리 재작성으로 main에서 탈락했고, 지금은 PR ref로만 닿는
dangling 객체다.

```
PR #2 merge commit : c3a03d026d365685c84da160a237144a9fd7ad53
main의 조상인가?    : 아니오
현재 트리에 있는가?  : 아니오
```

**의도된 결정이었음을 확인했다.** 같은 날 방향을 바꿨다:

```
2026-08-18  PR #2 머지    → local-gostore-vagrant  (독립 랩, Go 2,591줄 + Vagrantfile + 스크립트 8개)
2026-08-18  커밋 90f94b6  → block-store-app-go     (앱만, Go 1,560줄, local-ceph-vagrant 안에)
2026-08-20  히스토리 재작성 → PR #2 머지가 main에서 빠짐
```

독립 랩을 접고 축소판을 기존 `local-ceph-vagrant` 안에 접어넣는 쪽으로 전환한 것이다.
**따라서 구조하지 않는다.** forfun 삭제와 함께 사라지는 것이 의도한 결과다.

여기 적어두는 이유는, 나중에 누군가(또는 미래의 내가) PR #2가 머지됐는데 코드가 없는
것을 발견하고 사고로 오해하지 않게 하기 위해서다. 되짚어야 할 일이 생기면 4-0의
미러에서 위 SHA로 꺼낼 수 있다.

### C. 히스토리 20 MB 중 대부분이 이관 대상과 무관하다

forfun 히스토리에 있었던 최상위 디렉터리:

```
AI  LLM  MLops  web  nodejs  vibe_components  devops
00. naraapi   02. docker   03. k8s   04. ChatGPT4   05. trade_binance
06. Machine Learning   07.ollama-pdf-rag   08. project   08.llama3   09.streamlit
```

가장 큰 blob들:

| 크기    | 경로                                            |
| ------- | ----------------------------------------------- |
| 18.6 MB | `AI/webcrawling/chromedriver-win64/chromedriver.exe` |
| 7.1 MB  | `LLM/ollama-pdf-rag/sr650v3.pdf`                |
| 2.7 MB  | `LLM/ollama-pdf-rag/경남교육청_수목관리_업무매뉴얼.pdf` |
| 0.6 MB  | `AI/webcrawling/.../THIRD_PARTY_NOTICES.chromedriver` |
| 0.3 MB  | `AI/ollama/olla/Scripts/python.exe`              |

현재 트리에는 하나도 없지만 히스토리에는 영구히 남는다.

**결론: 히스토리를 통째로 가져오는 방식(`git subtree add`, `git remote add` 후 merge)은
쓰지 않는다.** 81 KB 저장소가 20 MB가 되고, 유출된 키(A)와 죽은 바이너리를 함께
들여오게 된다. 3절에서 방식을 고른다.

### D. forfun의 `.gitignore`가 죽어 있다

규칙이 전부 `devops/systems/**` 접두사로 쓰여 있는데, 실제 경로는 `systems/**`다.
`change folder directory` 커밋에서 폴더를 옮기면서 `.gitignore`를 고치지 않았다.

```gitignore
devops/systems/**/*.qcow2        # 매칭되는 파일이 없다
devops/systems/**/kubeconfig     # 매칭되는 파일이 없다
devops/systems/**/admin.conf     # 매칭되는 파일이 없다
devops/systems/**/join-command.sh
```

**즉 VM 디스크 이미지, kubeconfig, 클러스터 join 시크릿이 지금 아무것도 막히지 않은
상태다.** 랩을 한 번 돌리고 `git add -A`를 하면 그대로 public에 올라간다. 이관하면서
반드시 다시 쓴다 (4-3).

같은 파일에 랩 코드와 충돌하는 광범위 규칙도 있다:

| 규칙            | 문제                                                        |
| --------------- | ----------------------------------------------------------- |
| `lib/`          | `systems/local-spectrum-scale-ces-s3/scripts/lib/`이 추적 중인데 앞으로 추가되는 파일은 무시된다 |
| `*.png` `*.svg` | 문서용 이미지를 못 넣는다                                   |
| `build/` `target/` `dist/` `var/` `env/` | Python/Next.js 템플릿 잔재. 랩 경로와 우연히 겹칠 수 있다 |

이 저장소의 `.gitignore`는 반대로 `terraform/*.tfvars`가 **루트에 앵커**되어 있다.
랩들의 `systems/*/opentofu/terraform.tfvars`는 플레이스홀더라 커밋된 상태이므로,
합칠 때 이 둘을 의도적으로 갈라야 한다. 무심코 `**/terraform.tfvars`로 바꾸면
랩 13종의 설정 파일이 통째로 사라진다.

---

## 2. 최종 구조

`terraform/`과 `scripts/`는 루트에 그대로 두고, 랩을 `systems/`로 옆에 붙인다.

```
remote_coding/
├── terraform/          orca-host AWS 자원 (Lightsail·고정 IP·키페어·방화벽)
├── scripts/            orca-host 호스트 설정 01~06
├── systems/            ← 이관. 랩 하나 = 폴더 하나, 서로 참조하지 않는다
│   ├── aws-k3s-storage-lab/
│   ├── aws-kubeadm-storage-lab/
│   ├── local-ceph-kvm/
│   └── ... (13종)
└── docs/
    ├── lightsail-plan.md               (기존)
    ├── stock-chatbot-merge-plan.md     (기존)
    ├── forfun-consolidation-plan.md    (이 문서)
    ├── kubernetes-review-fix-list.md          ← 이관
    ├── os-compatibility-review.md             ← 이관
    ├── os-migration-rhel9-ubuntu2604.md       ← 이관
    └── spectrum-scale-ces-lab-feasibility.md  ← 이관
```

**루트를 건드리지 않는 쪽을 고른 이유** — `README.md`, `terraform/README.md`,
`scripts/README.md`, `docs/lightsail-plan.md`, `docs/stock-chatbot-merge-plan.md`가
전부 `cd terraform`, `bash ./scripts/sync-host.sh` 같은 루트 기준 경로를 쓴다.
`hosts/orca-host/` 아래로 내리면 이관 작업 위에 대규모 경로 수정이 겹친다.
이관과 재배치를 한 커밋에 섞으면 뭐가 깨졌는지 분리가 안 된다.

**대칭 구조를 원한다면** `hosts/orca-host/{terraform,scripts}`로 내리는 것도 가능하다.
다만 **이관이 끝나고 검증된 뒤 별도 커밋으로** 한다.

`docs/` 파일명은 양쪽에 겹치는 것이 없다 — 충돌 없이 합쳐진다.

### 저장소 이름 (선택)

`remote_coding`은 이제 내용과 어긋난다. 랩 13종에 호스트 1종인데 이름은 호스트만
가리킨다. GitHub은 이름을 바꿔도 옛 URL을 리다이렉트하므로 비용이 크지 않다.

바꾼다면 이관과 폐기가 **전부 끝난 뒤** 마지막에 한다. 중간에 바꾸면 `gh` 명령과
로컬 remote가 동시에 흔들린다. 바꾼 뒤에는 로컬에서:

```powershell
git remote set-url origin https://github.com/tkddls8848/<새이름>.git
```

---

## 3. 이관 방식 — 현재 main 스냅샷만 가져온다

| 방식 | 방법 | 히스토리 | 저장소 크기 | 유출 키(A) |
| --- | --- | --- | --- | --- |
| **A. 히스토리 통째** | `git remote add` + `merge --allow-unrelated-histories` | 177 커밋 전부 | 81 KB → **20 MB** | **함께 딸려온다** ❌ |
| **B. 스냅샷** ← 채택 | main의 파일만 복사해 1커밋 | 없음 | 81 KB → 4 MB | 안 들어온다 ✅ |
| C. 경로 필터 | `git filter-repo`로 `systems/`·`docs/`만 남기고 merge | 랩 관련 112 커밋 | 81 KB → 4 MB | 안 들어온다 ✅ |

**B로 간다.** 판단 근거는 4-0이다.

**미러 백업이 어차피 177 커밋을 통째로 보존한다.** 그러면 작업 저장소에 그 히스토리를
끌고 들어올 이유가 없다. 랩의 개발 경위가 궁금해지는 날 `forfun-mirror.git`을 열면 된다.
버리는 게 아니라 **작업 저장소 밖에 두는 것**이다.

B가 C보다 나은 이유:

- `git filter-repo` 설치(파이썬 의존)와 경로 재작성 단계가 통째로 없어진다
- 필터 결과가 맞는지 검증할 일이 없다 — 스냅샷은 눈으로 본 그대로다
- 새 히스토리가 "이 저장소가 랩을 흡수한 시점"에서 깨끗하게 시작한다.
  2024년의 `devops/` 시절 경로가 섞인 히스토리는 앞으로 읽을 일이 없다
- 명령이 셋뿐이라 틀릴 여지가 없다

**A는 쓰지 않는다.** 위 표의 마지막 두 열이 이유다.

> `local-gostore-vagrant`(1-B)는 main에 없으므로 B로 가져오면 따라오지 않는다.
> 그것이 의도한 결과다.

---

## 4. 실행 절차

실행 위치를 표시한다. `bash`는 Git Bash를 뜻한다 (WSL의 bash가 아니다 —
루트 `README.md`의 "Windows 준비 1·2"를 따른다).

### 4-0. 백업 — 되돌릴 수 없는 것부터 (bash)

**이 단계 전에는 forfun에 아무 파괴적 작업도 하지 않는다.**

스냅샷 방식(3절)을 택했으므로 **이 미러가 랩 히스토리 177 커밋의 유일한 사본이 된다.**
작업 저장소에는 히스토리가 들어오지 않는다.

```bash
mkdir -p ~/forfun-migration && cd ~/forfun-migration

git clone --mirror https://github.com/tkddls8848/forfun.git forfun-mirror.git
cd forfun-mirror.git
git fetch origin '+refs/pull/*:refs/pull/*'      # PR 머지 커밋까지 (1-B 포함)
git rev-parse c3a03d026d365685c84da160a237144a9fd7ad53   # SHA가 나오면 성공
du -sh .                                          # 20 MB 근처
cd ..
```

`refs/pull/*` 한 줄은 1-B의 탈락한 랩과 PR 머지 커밋들을 함께 담는다. 가져오기로 한
것은 없지만, 나중에 되짚을 일이 생겼을 때 여기 없으면 어디에도 없다. 한 줄이니 넣는다.

**이 `forfun-mirror.git`을 이 PC 밖에 한 벌 복사한다.** 외장 디스크든 다른 클라우드
저장소든 상관없다. forfun을 지운 뒤에는 이것이 유일한 원본이다.

### 4-1. 이 저장소 준비 (PowerShell)

```powershell
cd C:\Users\tkddl\orca\remote_coding
git status                        # clean 이어야 한다
git checkout -b feat/absorb-forfun
```

줄바꿈 설정을 먼저 맞춘다. 랩에는 `.sh`가 100개 넘게 들어오고, 이 저장소는 이미
CRLF 사고를 겪은 이력이 `README.md`에 적혀 있다.

```powershell
git config core.autocrlf input
```

### 4-2. 랩 가져오기 — main 스냅샷 복사 (bash)

`.git`을 가져오지 않고 파일만 복사한다. 히스토리는 4-0의 미러에 있다.

```bash
cd ~/forfun-migration
git clone --depth 1 https://github.com/tkddls8848/forfun.git forfun-snap

cp -r forfun-snap/systems      ~/orca/remote_coding/
cp    forfun-snap/docs/*.md    ~/orca/remote_coding/docs/
```

`README.md`·`.gitignore`·`.gitattributes`는 **복사하지 않는다.** 이 저장소에 같은 이름이
있고, 그냥 덮으면 orca-host 쪽 규칙이 날아간다. 셋은 4-3·4-4·4-5에서 손으로 합친다.

`forfun-snap`에 그 셋 말고 빠뜨린 최상위 파일이 없는지 확인한다.

```bash
ls -A forfun-snap
# .git  .gitattributes  .gitignore  README.md  docs  systems   ← 이게 전부여야 한다
```

복사 결과를 확인한다.

```bash
cd ~/orca/remote_coding
ls systems | wc -l          # 13
git status --short | head   # systems/ 와 docs/ 아래만 새로 뜬다
rm -rf ~/forfun-migration/forfun-snap
```

### 4-3. `.gitignore` 다시 쓰기 — 1-D의 구멍 메우기

기존 내용을 **지우지 말고**, 아래 블록을 이어 붙인다. 루트 `terraform/`·`scripts/`
규칙은 orca-host용이라 그대로 유효하다.

```gitignore
# ─────────────────────────────────────────────────────────────
# systems/ — 랩 공통. forfun 에서 이관하며 devops/ 접두사를 걷어냈다.
# (옛 규칙은 경로가 어긋나 아무것도 막지 못하고 있었다)
# ─────────────────────────────────────────────────────────────

# OpenTofu / Terraform 상태
#   tfvars 는 랩마다 플레이스홀더라 의도적으로 커밋한다 — 루트 terraform/ 과 다르다
systems/**/.terraform/
systems/**/*.tfstate
systems/**/*.tfstate.*
systems/**/.terraform.tfstate.lock.info
systems/**/crash.log

# VM 디스크 / 설치 이미지
systems/**/*.vdi
systems/**/*.vmdk
systems/**/*.qcow2
systems/**/*.img
systems/**/*.iso
systems/**/*.box
systems/**/.vagrant/

# 클러스터 자격증명 / join 시크릿
systems/**/kubeconfig
systems/**/kubeconfig-*
systems/**/admin.conf
systems/**/join-command.sh
systems/**/worker_join.sh

# 프로비저너 스크래치
systems/**/*.retry
systems/**/.ansible/
systems/**/.cache/
systems/**/.generated/
systems/**/.lab/
systems/**/tmp/

# in-tree 로 클론되는 업스트림 레포
systems/**/rook/
systems/**/kubespray-repo/

# 에이전트 로컬 설정
**/.claude
```

**forfun의 아래 규칙은 가져오지 않는다.**

| 버리는 규칙 | 이유 |
| --- | --- |
| `lib/` `build/` `target/` `dist/` `var/` `env/` | Python/Next.js 템플릿 잔재. `systems/local-spectrum-scale-ces-s3/scripts/lib/`가 추적 중이라 실제로 충돌한다 |
| `*.png` `*.svg` `*.woff` | 전역 규칙. 문서 이미지를 막는다 |
| Next.js / Jupyter / Django 블록 | 이관 대상에 해당 코드가 없다 |
| `devops/systems/**` 전체 | 경로가 어긋난 죽은 규칙. 위 블록이 대체한다 |

**즉시 검증한다** (PowerShell):

```powershell
# 추적 중인데 무시되는 파일 — 비어 있어야 한다
git ls-files --ignored --exclude-standard -c

# 개별 확인: 이 둘은 무시되면 안 된다
git check-ignore -v systems/local-spectrum-scale-ces-s3/scripts/lib/common.sh
git check-ignore -v systems/local-kubeadm-gpu/04_worker_join.sh
git check-ignore -v systems/aws-k3s-storage-lab/opentofu/terraform.tfvars
# ↑ 셋 다 아무 출력이 없어야 정상이다 (출력이 있으면 그 규칙에 걸린 것)
```

> `04_worker_join.sh`는 `worker_join.sh` 규칙과 아슬아슬하게 빗겨간다 (basename이
> 다르므로 매칭되지 않는다). 그래서 확인 목록에 넣었다.

각 랩이 가진 자체 `.gitignore`는 건드리지 않는다 — forfun의 "생성 파일과 비밀정보는
각 시스템의 `.gitignore`에서 관리한다"는 규칙을 유지한다.

### 4-4. `.gitattributes` 합치기

forfun 쪽이 상위집합이므로 그것을 채택하고, 이 저장소에만 있던 `*.env`를 더한다.

```gitattributes
# 텍스트 파일은 LF로 통일 (Windows에서 CRLF 자동 변환 방지)
* text=auto eol=lf

*.sh   text eol=lf
*.yml  text eol=lf
*.yaml text eol=lf
*.json text eol=lf
*.tf   text eol=lf
*.tfvars text eol=lf
*.py   text eol=lf
*.md   text eol=lf
*.txt  text eol=lf
*.env  text eol=lf

# 바이너리는 변환 제외
*.png binary
*.jpg binary
*.gif binary
*.ico binary
*.pem binary
```

적용하고 검증한다 (PowerShell):

```powershell
git add --renormalize .
git ls-files --eol | Select-String 'w/crlf'    # 아무것도 안 나와야 한다
```

`w/crlf`가 남으면 `scripts/sync-host.sh`가 서버로 복사한 스크립트가 Ubuntu에서
`/usr/bin/env: 'bash\r'` 로 죽는다. 루트 `README.md` "Windows 준비 3"에 적힌 그 문제다.

### 4-5. 문서 갱신

| 파일 | 할 일 |
| --- | --- |
| `README.md` | 저장소 정체를 "orca-host 계획"에서 "인프라 코드 저장소"로 다시 쓴다. `systems/` 랩 목록 표(forfun README에서 가져온다)를 넣고, 기존 orca-host 절차는 유지한다 |
| `README.md` | **깨진 링크 수정** — 현재 `docs/decision-log.md`를 가리키는데 그 파일은 없다 |
| `docs/` 이관 4종 | 본문의 `devops/systems/...` 경로 표기를 `systems/...`로 고친다 |
| `systems/*/README.md` | forfun 저장소 URL을 가리키는 곳이 있으면 고친다 |

경로 표기가 남아 있는지 훑는다 (bash):

```bash
grep -rn 'devops/systems\|tkddls8848/forfun' --include='*.md' . | head -30
```

### 4-6. 커밋과 검증

```powershell
git add -A
git status                        # 무엇이 올라가는지 눈으로 확인한다
git commit -m "forfun 흡수: 랩 13종 이관, ignore 규칙 재작성, 문서 갱신"
git push -u origin feat/absorb-forfun
```

푸시 **전에** 마지막으로 확인한다:

```powershell
git ls-files --ignored --exclude-standard -c          # 비어 있어야 한다
git ls-files --eol | Select-String 'w/crlf'           # 비어 있어야 한다
git ls-files | Measure-Object -Line                   # 25 → 400 근처
```

랩 하나를 실제로 돌려 본다. 최소 하나는 검증하고 넘어간다 —
예: `cd systems/local-kubeadm-vagrant && vagrant up`

문제 없으면 main으로 병합한다.

### 4-7. forfun 폐기 — 마지막

**앞 단계가 전부 끝나고, main에 병합되고, 4-0의 미러가 안전한 곳에 복사된 뒤에만 한다.**

먼저 아카이브한다. 되돌릴 수 있고, 실수로 커밋되는 것도 막힌다.

```powershell
gh repo archive tkddls8848/forfun --yes
```

forfun README를 이 저장소로 안내하도록 바꿔두면 좋다 (아카이브 전에).

**최소 2주는 아카이브 상태로 둔다.** 이 기간에 빠뜨린 것이 드러난다.
그동안 새 저장소로만 작업한다.

그 뒤 삭제한다.

```powershell
gh auth refresh -h github.com -s delete_repo    # delete_repo 스코프가 필요하다
gh repo delete tkddls8848/forfun --yes
```

삭제 직전 마지막 확인:

- [ ] `forfun-mirror.git`이 이 PC 밖에도 복사되어 있다
- [ ] `refs/pull/*`이 그 미러에 들어 있다 (`git rev-parse c3a03d0...`가 응답한다)
- [ ] 새 저장소에서 랩을 최소 하나 실제로 기동해 봤다
- [ ] 어디에도 `tkddls8848/forfun` 링크가 남아 있지 않다 (이력서·블로그·북마크 포함)

> `claude/go-rust-wrapper-conversion-ldzt59` 브랜치는 main보다 1 뒤, 0 앞이다
> (완전히 병합됨). 따로 챙길 것이 없다.

---

## 5. 되돌리기

| 시점 | 방법 |
| --- | --- |
| 4-6 커밋 전 | `git checkout main; git branch -D feat/absorb-forfun` |
| 4-6 푸시 후, 병합 전 | 브랜치를 지운다. main은 손대지 않았다 |
| main 병합 후 | 병합 커밋이면 `git revert -m 1 <sha>`, 아니면 `git revert <sha>`. forfun은 아직 살아 있다 |
| forfun 아카이브 후 | `gh repo unarchive tkddls8848/forfun` |
| **forfun 삭제 후** | **`forfun-mirror.git`이 유일한 경로다.** `git push --mirror`로 새 저장소에 복원 |

마지막 줄이 4-0을 건너뛰면 안 되는 이유다.

---

## 6. 리스크

| 리스크 | 확률 | 영향 | 대응 |
| --- | --- | --- | --- |
| 유출된 DeepSeek 키가 이미 악용됨 | 중 | 중 | **1-A를 오늘 처리한다.** 청구 내역 확인 |
| 백업 전에 forfun을 지워 177 커밋 히스토리 소실 | 중 | 높음 | 4-0을 첫 단계로 고정 |
| 미러 백업을 잃으면 랩 히스토리가 함께 사라짐 | 중 | 중 | 스냅샷 방식의 유일한 대가다. 미러를 이 PC 밖에 복사 |
| ignore 규칙 재작성이 추적 중인 파일을 덮음 | 중 | 중 | `git ls-files --ignored --exclude-standard -c`가 비었는지 확인 |
| CRLF가 섞여 서버에서 스크립트 실패 | 중 | 중 | 4-4의 `--renormalize` + `w/crlf` 확인 |
| 랩을 돌려본 뒤 kubeconfig·VM 이미지가 커밋됨 | 중 | 높음 | 4-3에서 `systems/**` 규칙을 넣는 것이 이 대응 |
| 히스토리 재작성으로 1-B 외에 더 탈락한 것이 있을 가능성 | 낮 | 중 | 미러(`refs/pull/*` 포함)를 보관해 두고 필요할 때 확인 |
| `remote_coding` 이름이 내용과 어긋난 채 굳음 | 중 | 낮음 | 2절 마지막. 전부 끝난 뒤 선택적으로 개명 |

---

## 7. 순서 요약

```
오늘  ── 1-A  DeepSeek 키 폐기                        (이관과 무관, 지연 불가)
  │
  ├─ 4-0  미러 백업 (refs/pull/* 포함) → PC 밖에 복사   ← 되돌릴 수 없는 것
  │        ↑ 히스토리는 전부 여기 남는다. 그래서 4-2 를 스냅샷으로 할 수 있다
  ├─ 4-1  브랜치 생성, core.autocrlf=input
  ├─ 4-2  main 스냅샷에서 systems/·docs/ 복사 (히스토리 없이)
  ├─ 4-3  .gitignore 재작성  ← 1-D 의 구멍
  ├─ 4-4  .gitattributes 통합 + renormalize
  ├─ 4-5  README·문서 갱신
  ├─ 4-6  커밋 · 검증 · 랩 1종 실기동 · main 병합
  │
  ├─ 4-7a forfun 아카이브
  │        ⋯ 2주 대기, 새 저장소로만 작업 ⋯
  ├─ 4-7b forfun 삭제
  └─ (선택) 저장소 개명
```

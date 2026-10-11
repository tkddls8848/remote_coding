"""RunPod 그림 서버 켜기 · 끄기 · 상태 (관리 PC 에서, 파이썬 표준 라이브러리만).

  python gpu-art/runpod/gpu.py start     저장 공간(없으면 만든다) + 팟을 만들고 ComfyUI 가 응답하면 COMFY_URL 을 알려 준다
  python gpu-art/runpod/gpu.py stop      팟을 지운다 (저장 공간의 모델 · 설치는 남는다)
  python gpu-art/runpod/gpu.py status    팟 · 저장 공간 · ComfyUI 응답
  python gpu-art/runpod/gpu.py url       게임 도구에 넘길 COMFY_URL 만 출력
  python gpu-art/runpod/gpu.py volume    저장 공간만 만든다(이미 있으면 그대로)
  python gpu-art/runpod/gpu.py destroy-volume --yes   저장 공간까지 지운다(모델을 다시 받아야 한다)

설정은 저장소 최상위 .env 하나(RUNPOD_* · GPU_*). 값은 화면에 찍지 않는다.
팟은 켤 때 새로 만들고 끌 때 지운다 — 켜 둔 동안만 GPU 값을 낸다. 30분 놀면 팟이 스스로 지운다(boot.sh).
"""
import base64, json, os, sys, time, urllib.error, urllib.request
from pathlib import Path

for _s in (sys.stdout, sys.stderr):
    _s.reconfigure(encoding='utf-8', errors='replace')   # Windows 콘솔에서 한글이 깨지지 않게

HERE = Path(__file__).resolve().parent
GPU_DIR = HERE.parent
ROOT = GPU_DIR.parent
API = 'https://rest.runpod.io/v1'


def env():
    v = {}
    f = ROOT / '.env'
    if f.exists():
        for line in f.read_text(encoding='utf-8').splitlines():
            line = line.strip()
            if not line or line.startswith('#') or '=' not in line:
                continue
            k, _, val = line.partition('=')
            val = val.strip()
            if len(val) >= 2 and val[0] == val[-1] and val[0] in '"\'':
                val = val[1:-1]
            v[k.strip()] = val
    return v


E = env()
def cfg(k, default=''):
    return os.environ.get(k) or E.get(k) or default   # 명령 줄에서 한 번만 바꿀 때는 환경 변수가 이긴다


KEY = cfg('RUNPOD_API_KEY')
POD_NAME = cfg('RUNPOD_POD_NAME', 'art-gpu')
VOLUME_NAME = cfg('RUNPOD_VOLUME_NAME', 'art-gpu-models')
VOLUME_GB = int(cfg('RUNPOD_VOLUME_GB', '90'))
DATACENTER = cfg('RUNPOD_DATACENTER', 'EU-RO-1')
# RTX PRO 4500 Blackwell(32GB)만 쓴다. 모델 묶음을 32GB 에 맞췄으므로 24GB 카드로 내려가지 않게 대체 후보를 두지 않는다.
GPU_TYPES = [g.strip() for g in cfg('RUNPOD_GPU_TYPES', 'NVIDIA RTX PRO 4500 Blackwell').split(',') if g.strip()]
IMAGE = cfg('RUNPOD_IMAGE', 'pytorch/pytorch:2.8.0-cuda12.8-cudnn9-runtime')
TS_HOST = cfg('GPU_TAILSCALE_HOSTNAME', POD_NAME)
PORT = 8188
URL = f'http://{TS_HOST}:{PORT}'


def die(msg):
    print('  xx ' + msg, file=sys.stderr)
    sys.exit(1)


def call(method, path, body=None):
    if not KEY:
        die("RUNPOD_API_KEY 가 .env 에 없다. RunPod 웹 → Settings → API Keys 에서 만들어 저장소 최상위 .env 에 한 줄로 넣을 것.")
    req = urllib.request.Request(API + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json',
                                          'User-Agent': 'art-gpu/1.0 (+gpu-art/runpod/gpu.py)'})   # 기본 Python-urllib 은 Cloudflare 가 막는다(1010)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        die(f'RunPod {method} {path} → {e.code}: {e.read().decode("utf-8", "replace")[:600]}')


def items(x):
    return x if isinstance(x, list) else (x or {}).get('items') or (x or {}).get('data') or []


def volume():
    for v in items(call('GET', '/networkvolumes')):
        if v.get('name') == VOLUME_NAME:
            if v.get('dataCenterId') != DATACENTER:
                print(f'  !! 저장 공간이 {v.get("dataCenterId")} 에 있다 — 팟도 그 데이터 센터에 만든다')
            if (v.get('size') or 0) < VOLUME_GB:   # 늘리기만 된다(줄이기는 안 된다)
                print(f'==> 저장 공간 늘리기 {v.get("size")}GB → {VOLUME_GB}GB')
                v = call('PATCH', f'/networkvolumes/{v["id"]}', {'size': VOLUME_GB}) or v
            return v
    print(f'==> 저장 공간 만들기 {VOLUME_NAME} ({VOLUME_GB}GB, {DATACENTER})')
    return call('POST', '/networkvolumes', {'name': VOLUME_NAME, 'size': VOLUME_GB, 'dataCenterId': DATACENTER})


def pods():
    return [p for p in items(call('GET', '/pods')) if p.get('name') == POD_NAME and p.get('desiredStatus') != 'TERMINATED']


def comfy_up(timeout=4):
    try:
        with urllib.request.urlopen(URL + '/system_stats', timeout=timeout) as r:
            return json.loads(r.read())
    except Exception:
        return None


def start():
    vol = volume()
    live = [p for p in pods() if p.get('desiredStatus') == 'RUNNING']
    if live:
        print(f'==> 이미 켜져 있다 ({live[0]["id"]})')
    else:
        if not cfg('GPU_TS_AUTHKEY'):
            print('  !! GPU_TS_AUTHKEY 가 비었다 — 처음 켜는 것이면 Tailscale 에 붙지 못해 멈춘다(저장 공간에 노드 상태가 있으면 괜찮다).')
        boot = base64.b64encode((HERE / 'boot.sh').read_bytes()).decode()
        models = base64.b64encode((GPU_DIR / 'models.txt').read_bytes()).decode()
        body = {
            'name': POD_NAME, 'imageName': IMAGE, 'computeType': 'GPU', 'gpuCount': 1,
            'gpuTypeIds': GPU_TYPES, 'gpuTypePriority': 'custom', 'cloudType': 'SECURE',
            'networkVolumeId': vol['id'], 'volumeMountPath': '/workspace', 'dataCenterIds': [vol.get('dataCenterId') or DATACENTER],
            'containerDiskInGb': 30, 'minRAMPerGPU': 32, 'allowedCudaVersions': ['12.8', '12.9', '13.0'],
            'ports': [],   # 공개 포트 없음 — Tailscale 로만 붙는다
            'dockerStartCmd': ['bash', '-c', 'echo "$BOOT_SH" | base64 -d > /boot.sh && exec bash /boot.sh'],
            'env': {
                'BOOT_SH': boot, 'MODELS_TXT': models, 'IDLE_SH': base64.b64encode((HERE / 'idle_guard.sh').read_bytes()).decode(), 'TS_HOST': TS_HOST, 'TS_AUTHKEY': cfg('GPU_TS_AUTHKEY'),
                'COMFY_VERSION': cfg('GPU_COMFY_VERSION', 'v0.39.0'),
                'GGUF_COMMIT': cfg('GPU_COMFY_GGUF_COMMIT', '6ea2651e7df66d7585f6ffee804b20e92fb38b8a'),
                'GGUF_PIP': cfg('GPU_GGUF_PIP_VERSION', '0.19.0'),
                'IDLE_MIN': cfg('GPU_IDLE_STOP_MINUTES', '30'),
            },
        }
        print(f'==> 팟 만들기 ({GPU_TYPES[0]} 우선, {body["dataCenterIds"][0]})')
        p = call('POST', '/pods', body)
        print(f'  ok {p.get("id")} · 시간당 {p.get("costPerHr", "?")}달러')
    print(f'==> ComfyUI 응답 대기 ({URL}) — 처음에는 모델을 받느라 10~20분, 그다음부터 1~3분')
    t0 = time.time()
    while time.time() - t0 < 40 * 60:
        if comfy_up():
            print(f'  ok 켜짐 — COMFY_URL={URL} ({round(time.time() - t0)}초)')
            return
        time.sleep(10)
        print(f'  .. {round(time.time() - t0)}초', end='\r', flush=True)
    die('40분 안에 ComfyUI 가 응답하지 않았다. RunPod 웹에서 팟 로그(boot.log)를 보거나 tailscale ssh root@' + TS_HOST + ' 로 붙어 /workspace/boot.log 를 볼 것.')


def stop():
    ps = pods()
    if not ps:
        print('  ok 켜진 팟 없음')
    for p in ps:
        call('DELETE', f'/pods/{p["id"]}')
        print(f'  ok 지움 {p["id"]} (저장 공간은 남는다)')


def status():
    vs = [v for v in items(call('GET', '/networkvolumes')) if v.get('name') == VOLUME_NAME]
    print('저장 공간:', ', '.join(f'{v["id"]} {v.get("size")}GB {v.get("dataCenterId")}' for v in vs) or '없음')
    ps = pods()
    print('팟:', ', '.join(f'{p["id"]} {p.get("desiredStatus")} 시간당 {p.get("costPerHr", "?")}달러' for p in ps) or '없음(꺼짐)')
    s = comfy_up()
    print('ComfyUI:', f'응답함 — COMFY_URL={URL} · {s["devices"][0]["name"]}' if s else f'응답 없음 ({URL})')


def destroy_volume():
    if '--yes' not in sys.argv:
        die('모델 · 설치가 모두 지워진다. 정말이면 --yes 를 붙인다.')
    if pods():
        die('팟이 켜져 있다. 먼저 stop.')
    for v in items(call('GET', '/networkvolumes')):
        if v.get('name') == VOLUME_NAME:
            call('DELETE', f'/networkvolumes/{v["id"]}')
            print(f'  ok 지움 {v["id"]}')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    {'start': start, 'stop': stop, 'status': status, 'volume': lambda: print(volume().get('id')),
     'url': lambda: print(URL), 'destroy-volume': destroy_volume}.get(cmd, lambda: print(__doc__))()

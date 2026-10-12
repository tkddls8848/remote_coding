"""RunPod 그림 서버 켜기 · 끄기 · 상태 (관리 PC 에서, 파이썬 표준 라이브러리 + ssh 만).

  python gpu-art/runpod/gpu.py start     팟을 만들고 SSH 터널을 열고 ComfyUI 가 응답하면 COMFY_URL 을 알려 준다
  python gpu-art/runpod/gpu.py stop      터널을 닫고 팟을 지운다 (남는 것 없음)
  python gpu-art/runpod/gpu.py status    팟 · SSH 주소 · 터널 · ComfyUI 응답
  python gpu-art/runpod/gpu.py tunnel    터널만 다시 연다 (노트북이 잠들었다 깨서 끊겼을 때)
  python gpu-art/runpod/gpu.py ssh [명령]  팟 안으로 들어간다 (예: ssh tail -f /opt/art/boot.log)
  python gpu-art/runpod/gpu.py url       게임 도구에 넘길 COMFY_URL 만 출력
  python gpu-art/runpod/gpu.py destroy-volume --yes   예전에 쓰던 네트워크 저장 공간을 지운다(이제 쓰지 않는다)

설정은 저장소 최상위 .env 하나(RUNPOD_* · GPU_*). 값은 화면에 찍지 않는다.
저장 공간을 두지 않는다 — 팟은 켤 때 새로 만들어 모델까지 처음부터 받고(boot.sh), 끌 때 통째로 지운다.
꺼 둔 동안 값이 없고, 저장 공간에 묶이지 않으니 GPU 가 있는 아무 데이터 센터에서나 켠다. 30분 놀면 팟이 스스로 지운다.
ComfyUI 에는 인증이 없으므로 공개하지 않는다 — 공개 포트는 SSH(공개키로만) 하나이고, ComfyUI 는 SSH 터널로 쓴다.
"""
import base64, json, os, shutil, signal, socket, subprocess, sys, time, urllib.error, urllib.request
from pathlib import Path

for _s in (sys.stdout, sys.stderr):
    _s.reconfigure(encoding='utf-8', errors='replace')   # Windows 콘솔에서 한글이 깨지지 않게

HERE = Path(__file__).resolve().parent
GPU_DIR = HERE.parent
ROOT = GPU_DIR.parent
STATE = ROOT / '.gpu-art'   # 터널 pid · 팟별 SSH 호스트 키 (커밋하지 않는다)
API = 'https://rest.runpod.io/v1'
GQL = 'https://api.runpod.io/graphql'


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
OLD_VOLUME_NAME = cfg('RUNPOD_VOLUME_NAME', 'art-gpu-models')   # 예전 네트워크 저장 공간 — 남아 있으면 알려 주고 지울 수 있게만
# 비우면 아무 데이터 센터. 고정하려면 쉼표로(예: EU-RO-1,US-KS-2)
DATACENTERS = [d.strip() for d in cfg('RUNPOD_DATACENTER').split(',') if d.strip()]
CLOUD = cfg('RUNPOD_CLOUD_TYPE', 'SECURE')   # COMMUNITY 면 더 싸다(공인 IP 있는 호스트만 고른다)
# RTX PRO 4500 Blackwell(32GB)만 쓴다. 모델 묶음을 32GB 에 맞췄으므로 24GB 카드로 내려가지 않게 대체 후보를 두지 않는다.
GPU_TYPES = [g.strip() for g in cfg('RUNPOD_GPU_TYPES', 'NVIDIA RTX PRO 4500 Blackwell').split(',') if g.strip()]
IMAGE = cfg('RUNPOD_IMAGE', 'pytorch/pytorch:2.8.0-cuda12.8-cudnn9-runtime')
DISK_GB = int(cfg('RUNPOD_DISK_GB', '80'))   # 모델(약 48GB) + ComfyUI · 가상 환경. 켜 둔 동안만 값을 낸다
SSH_KEY = cfg('RUNPOD_SSH_KEY')               # 비우면 ssh 기본 키(~/.ssh/id_ed25519 등)
PORT = 8188
LOCAL_PORT = int(cfg('RUNPOD_LOCAL_PORT', str(PORT)))
URL = f'http://127.0.0.1:{LOCAL_PORT}'   # 노트북 ComfyUI 와 같은 주소 — 게임 도구 기본값 그대로 쓴다


def die(msg):
    print('  xx ' + msg, file=sys.stderr)
    sys.exit(1)


def request(url, method='GET', body=None):
    if not KEY:
        die("RUNPOD_API_KEY 가 .env 에 없다. RunPod 웹 → Settings → API Keys 에서 만들어 저장소 최상위 .env 에 한 줄로 넣을 것.")
    req = urllib.request.Request(url, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={'Authorization': 'Bearer ' + KEY, 'Content-Type': 'application/json',
                                          'User-Agent': 'art-gpu/1.0 (+gpu-art/runpod/gpu.py)'})   # 기본 Python-urllib 은 Cloudflare 가 막는다(1010)
    with urllib.request.urlopen(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def call(method, path, body=None):
    try:
        return request(API + path, method, body)
    except urllib.error.HTTPError as e:
        die(f'RunPod {method} {path} → {e.code}: {e.read().decode("utf-8", "replace")[:600]}')


def items(x):
    return x if isinstance(x, list) else (x or {}).get('items') or (x or {}).get('data') or []


def pods():
    return [p for p in items(call('GET', '/pods')) if p.get('name') == POD_NAME and p.get('desiredStatus') != 'TERMINATED']


def ssh_endpoint(pod):
    """팟의 SSH 공인 주소 (ip, port). 아직 없으면 None."""
    p = call('GET', f'/pods/{pod["id"]}') or pod
    pm = p.get('portMappings') or {}
    ip, port = p.get('publicIp'), pm.get('22') or pm.get(22)
    if ip and port:
        return ip, int(port)
    try:   # REST 가 아직 주소를 주지 않을 때 GraphQL 로 한 번 더 본다
        q = 'query { pod(input: {podId: "%s"}) { runtime { ports { ip isIpPublic privatePort publicPort type } } } }' % pod['id']
        r = request(GQL, 'POST', {'query': q})
        for x in ((((r or {}).get('data') or {}).get('pod') or {}).get('runtime') or {}).get('ports') or []:
            if x.get('privatePort') == 22 and x.get('isIpPublic') and x.get('type') == 'tcp':
                return x['ip'], int(x['publicPort'])
    except Exception:
        pass
    return None


def local_pubkey():
    cands = [SSH_KEY + '.pub'] if SSH_KEY else [str(Path.home() / '.ssh' / n) for n in ('id_ed25519.pub', 'id_ecdsa.pub', 'id_rsa.pub')]
    for c in cands:
        if Path(c).is_file():
            return Path(c).read_text(encoding='utf-8').strip()
    return ''


def ssh_cmd(pod, ep):
    STATE.mkdir(exist_ok=True)
    a = ['ssh', '-p', str(ep[1]),
         '-o', f'UserKnownHostsFile={STATE / "known_hosts"}', '-o', 'StrictHostKeyChecking=accept-new',
         '-o', f'HostKeyAlias=art-gpu-{pod["id"]}',   # 팟마다 호스트 키가 새로 생긴다 — 같은 IP:포트를 다른 팟이 받아도 엉키지 않게
         '-o', 'ConnectTimeout=10']
    if SSH_KEY:
        a += ['-i', SSH_KEY]
    return a + [f'root@{ep[0]}']


def port_open(port):
    try:
        socket.create_connection(('127.0.0.1', port), timeout=1).close()
        return True
    except OSError:
        return False


def close_tunnel():
    f = STATE / 'tunnel.pid'
    if f.exists():
        try:
            os.kill(int(f.read_text()), signal.SIGTERM)
        except (OSError, ValueError):
            pass
        f.unlink(missing_ok=True)
        time.sleep(1)


def open_tunnel(pod, ep):
    """ssh -N -L 로 127.0.0.1:LOCAL_PORT → 팟의 127.0.0.1:8188. 열리면 True."""
    close_tunnel()
    if port_open(LOCAL_PORT):
        die(f'127.0.0.1:{LOCAL_PORT} 를 다른 프로그램이 쓰고 있다(노트북 ComfyUI?). 끄거나 .env 에 RUNPOD_LOCAL_PORT=8189 처럼 바꿀 것.')
    a = ssh_cmd(pod, ep)
    a[1:1] = ['-N', '-L', f'127.0.0.1:{LOCAL_PORT}:127.0.0.1:{PORT}', '-o', 'BatchMode=yes', '-o', 'ExitOnForwardFailure=yes',
              '-o', 'ServerAliveInterval=30', '-o', 'ServerAliveCountMax=3']
    kw = {'creationflags': 0x00000200 | 0x00000008} if os.name == 'nt' else {'start_new_session': True}   # 이 명령이 끝나도 터널은 남는다
    with open(STATE / 'tunnel.log', 'ab') as log:
        p = subprocess.Popen(a, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=log, **kw)
    for _ in range(20):
        if p.poll() is not None:
            return False
        if port_open(LOCAL_PORT):
            (STATE / 'tunnel.pid').write_text(str(p.pid))
            return True
        time.sleep(1)
    p.kill()
    return False


def tunnel_to(pod, wait_min=10):
    t0 = time.time()
    ep = None
    while time.time() - t0 < wait_min * 60:
        ep = ep or ssh_endpoint(pod)
        if ep and open_tunnel(pod, ep):
            print(f'  ok 터널 {URL} → 팟 {ep[0]}:{ep[1]}')
            return ep
        time.sleep(10)
        print(f'  .. SSH 대기 {round(time.time() - t0)}초', end='\r', flush=True)
    die(f'{wait_min}분 안에 SSH 로 붙지 못했다. {STATE / "tunnel.log"} 와 RunPod 웹의 팟 로그를 볼 것'
        ' (공개키: RunPod 계정 설정 또는 ~/.ssh/id_ed25519.pub).')


def comfy_up(timeout=4):
    try:
        with urllib.request.urlopen(URL + '/system_stats', timeout=timeout) as r:
            return json.loads(r.read())
    except Exception:
        return None


def start():
    if not shutil.which('ssh'):
        die('ssh 가 없다. Windows 는 설정 → 시스템 → 선택적 기능 → OpenSSH 클라이언트.')
    pub = local_pubkey()
    if not pub:
        die('SSH 공개키가 없다. ssh-keygen -t ed25519 로 만들거나 .env 에 RUNPOD_SSH_KEY=<개인 키 경로>.')
    live = [p for p in pods() if p.get('desiredStatus') == 'RUNNING']
    if live:
        pod = live[0]
        print(f'==> 이미 켜져 있다 ({pod["id"]})')
    else:
        b64 = lambda p: base64.b64encode(p.read_bytes()).decode()
        body = {
            'name': POD_NAME, 'imageName': IMAGE, 'computeType': 'GPU', 'gpuCount': 1,
            'gpuTypeIds': GPU_TYPES, 'gpuTypePriority': 'custom', 'cloudType': CLOUD, 'supportPublicIp': True,
            'containerDiskInGb': DISK_GB, 'volumeInGb': 0, 'minRAMPerGPU': 32, 'allowedCudaVersions': ['12.8', '12.9', '13.0'],
            'ports': ['22/tcp'],   # SSH 하나만 공개 — ComfyUI 는 터널로
            'dockerStartCmd': ['bash', '-c', 'echo "$BOOT_SH" | base64 -d > /boot.sh && exec bash /boot.sh'],
            'env': {
                'BOOT_SH': b64(HERE / 'boot.sh'), 'MODELS_TXT': b64(GPU_DIR / 'models.txt'), 'IDLE_SH': b64(HERE / 'idle_guard.sh'),
                'ART_SSH_PUBKEY': pub,
                'COMFY_VERSION': cfg('GPU_COMFY_VERSION', 'v0.39.0'),
                'GGUF_COMMIT': cfg('GPU_COMFY_GGUF_COMMIT', '6ea2651e7df66d7585f6ffee804b20e92fb38b8a'),
                'GGUF_PIP': cfg('GPU_GGUF_PIP_VERSION', '0.19.0'),
                'IDLE_MIN': cfg('GPU_IDLE_STOP_MINUTES', '30'),
            },
        }
        if DATACENTERS:
            body['dataCenterIds'] = DATACENTERS
        print(f'==> 팟 만들기 ({GPU_TYPES[0]}, {CLOUD}, {"/".join(DATACENTERS) or "아무 데이터 센터"})')
        pod = call('POST', '/pods', body)
        print(f'  ok {pod.get("id")} · 시간당 {pod.get("costPerHr", "?")}달러')
    tunnel_to(pod)
    print(f'==> ComfyUI 응답 대기 — 모델(약 48GB)을 받느라 5~15분')
    t0 = time.time()
    while time.time() - t0 < 40 * 60:
        if comfy_up():
            print(f'  ok 켜짐 — COMFY_URL={URL} ({round(time.time() - t0)}초)'
                  + (' · 게임 도구 기본값과 같다' if LOCAL_PORT == PORT else ''))
            return
        if not port_open(LOCAL_PORT):
            print('  !! 터널이 끊겼다 — 다시 연다')
            tunnel_to(pod)
        time.sleep(10)
        print(f'  .. {round(time.time() - t0)}초', end='\r', flush=True)
    die('40분 안에 ComfyUI 가 응답하지 않았다. python gpu-art/runpod/gpu.py ssh tail -50 /opt/art/boot.log 로 볼 것.')


def stop():
    close_tunnel()
    ps = pods()
    if not ps:
        print('  ok 켜진 팟 없음')
    for p in ps:
        call('DELETE', f'/pods/{p["id"]}')
        print(f'  ok 지움 {p["id"]}')


def running_pod():
    live = [p for p in pods() if p.get('desiredStatus') == 'RUNNING']
    if not live:
        die('켜진 팟이 없다. 먼저 start.')
    return live[0]


def tunnel():
    tunnel_to(running_pod(), wait_min=2)


def ssh():
    pod = running_pod()
    ep = ssh_endpoint(pod) or die('팟의 SSH 주소가 아직 없다. 잠시 뒤 다시.')
    sys.exit(subprocess.call(ssh_cmd(pod, ep) + sys.argv[2:]))


def status():
    ps = pods()
    if not ps:
        print('팟: 없음(꺼짐)')
    for p in ps:
        ep = ssh_endpoint(p) if p.get('desiredStatus') == 'RUNNING' else None
        print(f'팟: {p["id"]} {p.get("desiredStatus")} 시간당 {p.get("costPerHr", "?")}달러'
              + (f' · SSH {ep[0]}:{ep[1]}' if ep else ''))
    print('터널:', f'열림 ({URL})' if port_open(LOCAL_PORT) else '닫힘 — 팟이 켜져 있으면 gpu.py tunnel')
    s = comfy_up()
    print('ComfyUI:', f'응답함 — COMFY_URL={URL} · {s["devices"][0]["name"]}' if s else f'응답 없음 ({URL})')
    old = [v for v in items(call('GET', '/networkvolumes')) if v.get('name') == OLD_VOLUME_NAME]
    if old:
        sizes = ', '.join(f'{v.get("size")}GB' for v in old)
        print(f'  !! 예전 저장 공간이 남아 값이 나간다({sizes}) — 이제 쓰지 않는다: gpu.py destroy-volume --yes')


def destroy_volume():
    if '--yes' not in sys.argv:
        die('예전 네트워크 저장 공간을 지운다(지금 구조는 쓰지 않는다). 정말이면 --yes 를 붙인다.')
    found = False
    for v in items(call('GET', '/networkvolumes')):
        if v.get('name') == OLD_VOLUME_NAME:
            call('DELETE', f'/networkvolumes/{v["id"]}')
            print(f'  ok 지움 {v["id"]}')
            found = True
    if not found:
        print('  ok 지울 저장 공간 없음')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    {'start': start, 'stop': stop, 'status': status, 'tunnel': tunnel, 'ssh': ssh,
     'url': lambda: print(URL), 'destroy-volume': destroy_volume}.get(cmd, lambda: print(__doc__))()

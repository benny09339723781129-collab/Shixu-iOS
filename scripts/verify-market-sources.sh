#!/bin/bash
# Read-only real-provider smoke on an already booted iOS 26+ iPhone simulator.
# Run after UI journeys against the installed DEBUG app. No fixtures are passed,
# no runtime is installed/booted, and no connected iPhone is accessed.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'NOT RUN: public-provider simulator smoke requires macOS and Xcode.' >&2
  exit 2
fi
python3 - <<'PY'
import json
import os
import pathlib
import re
import subprocess
import sys
import time
import uuid

# Reserve the final three seconds for stopping this simulator app: total <=140s.
deadline = time.monotonic() + 137
destination = pathlib.Path('build/market-provider-smoke.json')
destination.parent.mkdir(parents=True, exist_ok=True)
run_id = str(uuid.uuid4()).upper()
sim_id = None
launched = False
received = False
report = None

def command(arguments, maximum=12, check=True):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError('Real-provider smoke reached its 140-second deadline')
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=min(maximum, remaining), text=True)
    if check and result.returncode:
        raise RuntimeError('Simulator command failed: ' + ' '.join(arguments[:3]) + ': ' + result.stderr.strip()[:300])
    return result

try:
    inventory = json.loads(command(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']).stdout)
    booted = []
    for runtime, entries in inventory.get('devices', {}).items():
        match = re.search(r'iOS[- .](\d+)[- .](\d+)', runtime)
        if not match or int(match.group(1)) < 26:
            continue
        for entry in entries:
            if entry.get('state') == 'Booted' and entry.get('isAvailable', True) and 'iPhone' in entry.get('name', ''):
                booted.append(dict(entry, version=tuple(map(int,match.groups())), runtime=runtime))
    requested = os.environ.get('SHIXU_UI_SIMULATOR_ID')
    eligible = [item for item in booted if not requested or item['udid'] == requested]
    if not eligible:
        raise RuntimeError('No matching already booted iOS 26+ iPhone simulator; no runtime or device was created')
    simulator = max(eligible, key=lambda item: ('iPhone 17 Pro' in item['name'],item['version']))
    sim_id = simulator['udid']
    data = pathlib.Path(command(['xcrun','simctl','get_app_container',sim_id,'app.shixu.studio','data']).stdout.strip())
    if not data.is_absolute() or not data.is_dir():
        raise RuntimeError('Installed simulator app data container was not found')
    source = data / 'Library' / 'Caches' / 'market-provider-smoke.json'
    command(['xcrun','simctl','terminate',sim_id,'app.shixu.studio'],maximum=5,check=False)
    command(['xcrun','simctl','launch',sim_id,'app.shixu.studio','--market-source-smoke','--market-source-smoke-id',run_id])
    launched = True
    while time.monotonic() < deadline:
        if source.is_file():
            try:
                candidate = json.loads(source.read_text())
                if isinstance(candidate,dict) and candidate.get('runID') == run_id:
                    report = candidate
                    received = True
                    break
            except (OSError,ValueError):
                pass  # Atomic writer or an old result may still be present.
        time.sleep(min(2,max(0,deadline-time.monotonic())))
    if not received:
        raise TimeoutError('No fresh native provider result before the 140-second deadline; verify the installed app is DEBUG and has the smoke entry hook')
    report['nativeResultReceived'] = True
    report['simulator'] = {'name':simulator['name'],'runtime':simulator['runtime']}
    if report.get('fixtureMode') is not False or report.get('debug') is not True or report.get('logicalRequests') != 4:
        report['passed'] = False
        report.setdefault('failures',[]).append('Result was not a four-request Debug real-provider run')
except Exception as error:
    report = {'passed':False,'failures':[str(error)],'provider':{},'currency':{},'historyRows':{},'lastDay':{},
              'runID':run_id,'nativeResultReceived':received,'fixtureMode':False}
finally:
    # Only stop this app on this simulator; preserve all app/profile/cookie data.
    if launched and sim_id:
        try:
            subprocess.run(['xcrun','simctl','terminate',sim_id,'app.shixu.studio'],stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL,timeout=3)
        except (OSError,subprocess.TimeoutExpired):
            pass
    destination.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(report,ensure_ascii=False,indent=2))

sys.exit(0 if report.get('passed') is True else 1)
PY

#!/bin/bash
# Actual XCUITest journeys: 13-minute work budget plus bounded evidence export.
# Requires an existing Xcode + XcodeGen 2.46.0 installation. No account/signing setup.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'NOT RUN: native UI tests require macOS, Xcode and an iOS Simulator.' >&2
  exit 2
fi
for command_name in xcodegen xcodebuild xcrun python3 node; do
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "NOT RUN: missing required command: $command_name" >&2
    exit 2
  fi
done

python3 - <<'PY'
import datetime
import json
import os
import pathlib
import re
import signal
import subprocess
import sys
import time

root = pathlib.Path.cwd()
stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d-%H%M%S')
output = root / 'build' / 'ui-tests' / (stamp + '-' + str(os.getpid()))
output.mkdir(parents=True, exist_ok=False)
deadline = time.monotonic() + 780
summary = {'passed': False, 'fixtureOnly': True, 'output': str(output), 'destinations': [], 'notes': []}
results = []
video = None
video_log = None

def run(command, log_name, maximum=180, check=True):
    remaining = deadline - time.monotonic()
    if remaining < 10:
        raise TimeoutError('Overall native UI test budget exhausted')
    limit = max(1, min(maximum, remaining))
    log_path = output / log_name
    print('Running:', ' '.join(map(str, command)), flush=True)
    with log_path.open('wb') as log:
        process = subprocess.Popen(list(map(str, command)), stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = process.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGTERM)
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
            raise TimeoutError('Timed out: ' + str(command[0]) + '; log: ' + str(log_path))
    if code and check:
        print('\n'.join(log_path.read_text(errors='replace').splitlines()[-65:]), file=sys.stderr)
        raise RuntimeError('Command failed (' + str(code) + '): ' + str(command[0]) + '; log: ' + str(log_path))
    return code

def runtime_version(key):
    match = re.search(r'iOS[- .](\d+)[- .](\d+)', key)
    return tuple(map(int, match.groups())) if match else (0, 0)

def devices():
    data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j'], timeout=25))
    rows = []
    for runtime, group in data.get('devices', {}).items():
        for item in group:
            if item.get('isAvailable', True) and 'iPhone' in item.get('name', ''):
                rows.append(dict(item, runtime=runtime, version=runtime_version(runtime)))
    return rows

def boot(item):
    if item.get('state') != 'Booted':
        run(['xcrun', 'simctl', 'boot', item['udid']], 'boot-' + item['udid'] + '.log', 45)
    run(['xcrun', 'simctl', 'bootstatus', item['udid'], '-b'], 'bootstatus-' + item['udid'] + '.log', 150)

def stop_video():
    global video, video_log
    if video is not None:
        if video.poll() is None:
            os.killpg(video.pid, signal.SIGINT)
            try:
                video.wait(timeout=12)
            except subprocess.TimeoutExpired:
                os.killpg(video.pid, signal.SIGTERM)
                try:
                    video.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    os.killpg(video.pid, signal.SIGKILL)
                    video.wait()
        video = None
    if video_log is not None:
        video_log.close()
        video_log = None

def test_destination(item, label, maximum):
    global video, video_log
    boot(item)
    result = output / (label + '.xcresult')
    results.append((label, result))
    summary['destinations'].append({'label': label, 'name': item['name'], 'udid': item['udid'], 'runtime': item['runtime'], 'result': str(result)})
    video_log = (output / (label + '-recording.log')).open('wb')
    video = subprocess.Popen(['xcrun', 'simctl', 'io', item['udid'], 'recordVideo', '--codec=h264', str(output / (label + '-journeys.mp4'))], stdout=video_log, stderr=subprocess.STDOUT, start_new_session=True)
    try:
        run(['xcodebuild', 'test', '-project', 'ShixuJourney.xcodeproj', '-scheme', 'ShixuJourney',
             '-configuration', 'Debug', '-destination', 'platform=iOS Simulator,id=' + item['udid'],
             '-derivedDataPath', str(output / 'DerivedData'), '-resultBundlePath', str(result),
             '-parallel-testing-enabled', 'NO', '-maximum-concurrent-test-simulator-destinations', '1',
             '-test-timeouts-enabled', 'YES', '-maximum-test-execution-time-allowance', '100',
             'CODE_SIGNING_ALLOWED=NO', 'CODE_SIGNING_REQUIRED=NO'], label + '-xcodebuild.log', maximum)
        summary['destinations'][-1]['passed'] = True
    except Exception:
        summary['destinations'][-1]['passed'] = False
        raise
    finally:
        stop_video()

try:
    # Inspect only the dedicated public chart folder. Never include the workspace,
    # signing data, backend files, output archives or private test configuration.
    chart = root / 'Shixu' / 'Resources' / 'Chart'
    allowed = {'index.html', 'chart.js', 'lightweight-charts.standalone.production.js', 'LICENSE', 'LICENSE.txt', 'NOTICE.txt', 'LICENSE/NOTICE.txt'}
    required = {'index.html', 'chart.js', 'lightweight-charts.standalone.production.js'}
    present = {str(path.relative_to(chart)) for path in chart.rglob('*') if path.is_file()} if chart.is_dir() else set()
    if not required.issubset(present) or present - allowed:
        raise RuntimeError('Chart resource allowlist mismatch; missing=' + str(sorted(required-present)) + ', unexpected=' + str(sorted(present-allowed)))
    run(['xcodegen', '--version'], 'xcodegen-version.log', 15)
    run(['xcodebuild', '-version'], 'xcode-version.log', 15)
    run(['node', 'scripts/generate-fixtures.mjs'], 'fixtures.log', 30)
    run(['xcodegen', 'generate', '--spec', 'project.yml'], 'xcodegen.log', 45)
    available = devices()
    eligible = [item for item in available if item['version'][0] >= 26]
    if not eligible:
        raise RuntimeError('No available iPhone simulator with iOS 26 or later; no device was created or downloaded')
    requested = os.environ.get('SHIXU_UI_SIMULATOR_ID')
    if requested:
        primary = next((item for item in eligible if item['udid'] == requested), None)
        if primary is None:
            raise RuntimeError('SHIXU_UI_SIMULATOR_ID is not an available iOS 26+ iPhone')
    else:
        primary = max(eligible, key=lambda item: (item['state'] == 'Booted' and 'iPhone 17 Pro' in item['name'],
                      'iPhone 17 Pro' in item['name'], item['state'] == 'Booted', item['version']))
    small = sorted((item for item in available if 'iPhone SE' in item['name'] and item['version'][0] >= 16), key=lambda item: item['version'], reverse=True)
    test_destination(primary, 'primary', min(550, max(1, deadline-time.monotonic()-80)))
    if small and deadline - time.monotonic() >= 300:
        test_destination(small[0], 'small-iphone-se', min(300, deadline-time.monotonic()-45))
    elif small:
        summary['notes'].append('Available iPhone SE was not run because the bounded test budget had less than 300 seconds remaining')
    else:
        summary['notes'].append('No available iPhone SE runtime; no simulator/runtime was installed')
    summary['passed'] = True
except Exception as error:
    summary['error'] = str(error)
    print(str(error), file=sys.stderr, flush=True)
finally:
    stop_video()
    # Keep xcresult and its attachment manifest even when a journey fails.
    # Attachments are named 01..08 by XCTest and explicitly kept on success.
    for label, result in results:
        if not result.exists():
            continue
        attachments = output / (label + '-screenshots')
        attachments.mkdir(exist_ok=True)
        try:
            export = subprocess.run(['xcrun', 'xcresulttool', 'export', 'attachments', '--path', str(result), '--output-path', str(attachments)],
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=35, text=True)
            (output / (label + '-attachment-export.log')).write_text(export.stdout)
            count = len(list(attachments.rglob('*.png')))
            for destination in summary['destinations']:
                if destination['label'] == label:
                    destination['screenshots'] = count
                    destination['attachments'] = str(attachments)
            if export.returncode:
                summary['notes'].append(label + ': screenshot export failed; originals remain in xcresult')
                summary['passed'] = False
            elif label == 'primary' and summary['passed'] and count < 8:
                summary['error'] = 'Primary UI run exported fewer than eight screenshots'
                summary['passed'] = False
        except Exception as error:
            summary['notes'].append(label + ': attachment export error: ' + str(error))
            summary['passed'] = False
    recording = output / 'primary-journeys.mp4'
    if summary['passed'] and (not recording.exists() or recording.stat().st_size < 1024):
        summary['passed'] = False
        summary['error'] = 'The primary journey recording is missing; inspect primary-recording.log'
    (output / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(summary, ensure_ascii=False, indent=2), flush=True)

sys.exit(0 if summary['passed'] else 1)
PY

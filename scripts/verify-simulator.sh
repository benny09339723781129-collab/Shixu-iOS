#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-ipa.sh simulator
sim_id="$(xcrun simctl list devices available -j | python3 -c 'import json,sys,re;d=json.load(sys.stdin);versions=sorted(((tuple(map(int,re.findall(r"iOS-(\d+)-(\d+)",key)[0])),key) for key in d["devices"] if re.findall(r"iOS-(\d+)-(\d+)",key)),reverse=True);version,key=next((v,k) for v,k in versions if v[0]>=26 and any("iPhone" in x["name"] for x in d["devices"][k]));device=next(x for x in d["devices"][key] if "iPhone" in x["name"]);print(device["udid"]);print("Selected iOS",version,device["name"],file=sys.stderr)')"
xcrun simctl boot "$sim_id" || true
python3 -c 'import subprocess,sys;subprocess.run(["xcrun","simctl","bootstatus",sys.argv[1],"-b"],check=True,timeout=300)' "$sim_id"
xcrun simctl status_bar "$sim_id" override --time "09:41" --dataNetwork wifi --wifiMode active --wifiBars 3 --batteryState charged --batteryLevel 100
xcrun simctl install "$sim_id" build-simulator/Payload/Shixu.app
mkdir -p build/screenshots
xcrun swiftc scripts/check-chart-image.swift -o build/check-chart-image
app_data="$(xcrun simctl get_app_container "$sim_id" app.shixu.studio data)"
for screen in home market news stock research setup report portfolio settings; do
 xcrun simctl terminate "$sim_id" app.shixu.studio || true
 render_id="$(python3 -c 'import uuid;print(str(uuid.uuid4()).upper())')"
 xcrun simctl launch "$sim_id" app.shixu.studio --ui-fixtures --native-self-test --ui-screen "$screen" --ui-render-id "$render_id"
 if [[ "$screen" == stock ]]; then
  python3 - "$app_data/Library/Caches/chart-ready-$render_id.json" "$render_id" "$sim_id" <<'PY'
import json,pathlib,subprocess,sys,time
path=pathlib.Path(sys.argv[1]); deadline=time.monotonic()+30
while time.monotonic()<deadline:
    try:
        proof=json.loads(path.read_text())
        if proof.get('passed') and proof.get('runID')==sys.argv[2] and proof.get('bars',0)>0 and min(proof.get(k,0) for k in ['plotWidth','plotHeight','canvasWidth','canvasHeight'])>0:
            pathlib.Path('build/chart-render-ready.json').write_text(json.dumps(proof,indent=2)+'\n')
            break
    except (FileNotFoundError,json.JSONDecodeError):
        pass
    time.sleep(.2)
else:
    try:
        subprocess.run(['xcrun','simctl','io',sys.argv[3],'screenshot','build/screenshots/native-stock-not-ready.png'],timeout=15,check=False)
    except subprocess.TimeoutExpired:
        pass
    raise SystemExit('Stock chart did not complete a nonempty, sized render within 30 seconds')
PY
 else
  sleep 3
 fi
 if [[ "$screen" == stock ]]; then
  # WebKit's document RAF and the simulator compositor are separate. Wait on
  # actual pixels with unchanged criteria, not another fixed loading sleep.
  painted=0
  for attempt in 1 2 3 4 5 6 7 8; do
   xcrun simctl io "$sim_id" screenshot build/screenshots/native-stock.png
   if build/check-chart-image build/screenshots/native-stock.png build/chart-render-ready.json build/chart-image-check.json; then
    painted=1
    printf '%s\n' "$attempt" > build/chart-paint-attempts.txt
    break
   fi
   if [[ "$attempt" == 1 ]]; then cp build/screenshots/native-stock.png build/chart-first-not-painted.png; fi
   sleep .2
  done
  [[ "$painted" == 1 ]] || { echo 'Stock screenshot remained unpainted after bounded compositor checks' >&2; exit 1; }
 else
  xcrun simctl io "$sim_id" screenshot "build/screenshots/native-$screen.png"
 fi
done
cp "$app_data/Library/Caches/native-self-test.json" build/native-self-test.json
python3 -c 'import json; r=json.load(open("build/native-self-test.json"));print(r);assert r["passed"],r'
echo 'Native app compiled, launched and passed isolated runtime checks.'

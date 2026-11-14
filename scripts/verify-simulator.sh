#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-ipa.sh simulator
sim_id="$(xcrun simctl list devices available -j | python3 -c 'import json,sys,re;d=json.load(sys.stdin);versions=sorted(((tuple(map(int,re.findall(r"iOS-(\d+)-(\d+)",key)[0])),key) for key in d["devices"] if re.findall(r"iOS-(\d+)-(\d+)",key)),reverse=True);version,key=next((v,k) for v,k in versions if v[0]>=26 and any("iPhone" in x["name"] for x in d["devices"][k]));device=next(x for x in d["devices"][key] if "iPhone" in x["name"]);print(device["udid"]);print("Selected iOS",version,device["name"],file=sys.stderr)')"
xcrun simctl boot "$sim_id" || true
python3 -c 'import subprocess,sys;subprocess.run(["xcrun","simctl","bootstatus",sys.argv[1],"-b"],check=True,timeout=300)' "$sim_id"
xcrun simctl install "$sim_id" build-simulator/Payload/Shixu.app
mkdir -p build/screenshots
for screen in home market stock research setup report portfolio settings; do
 xcrun simctl terminate "$sim_id" app.shixu.studio || true
 xcrun simctl launch "$sim_id" app.shixu.studio --ui-fixtures --native-self-test --ui-screen "$screen"
 sleep 3
 xcrun simctl io "$sim_id" screenshot "build/screenshots/native-$screen.png"
done
app_data="$(xcrun simctl get_app_container "$sim_id" app.shixu.studio data)"
cp "$app_data/Library/Caches/native-self-test.json" build/native-self-test.json
python3 -c 'import json; r=json.load(open("build/native-self-test.json"));print(r);assert r["passed"],r'
echo 'Native app compiled, launched and passed isolated runtime checks.'

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-ipa.sh simulator
sim_id="$(xcrun simctl list devices available -j | python3 -c 'import json,sys;d=json.load(sys.stdin);print(next(x["udid"] for rows in d["devices"].values() for x in rows if "iPhone" in x["name"]))')"
xcrun simctl boot "$sim_id" || true
xcrun simctl bootstatus "$sim_id" -b
xcrun simctl install "$sim_id" build-simulator/Payload/Shixu.app
mkdir -p build/screenshots
for screen in home market stock research portfolio settings; do
 xcrun simctl terminate "$sim_id" app.shixu.studio || true
 xcrun simctl launch "$sim_id" app.shixu.studio --ui-fixtures --native-self-test --ui-screen "$screen"
 sleep 3
 xcrun simctl io "$sim_id" screenshot "build/screenshots/native-$screen.png"
done
app_data="$(xcrun simctl get_app_container "$sim_id" app.shixu.studio data)"
cp "$app_data/Library/Caches/native-self-test.json" build/native-self-test.json
python3 -c 'import json; r=json.load(open("build/native-self-test.json"));print(r);assert r["passed"],r'
echo 'Native app compiled, launched and passed isolated runtime checks.'

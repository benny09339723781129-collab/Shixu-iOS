#!/bin/bash
set -euo pipefail
if command -v xcodegen >/dev/null 2>&1 && xcodegen --version | grep -Eq '(^|[^0-9])2\.46\.0([^0-9]|$)'; then
  xcodegen --version
  exit 0
fi
tool_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/shixu-xcodegen-2.46.0"
mkdir -p "$tool_dir/bin" "$tool_dir/unpacked"
archive="$tool_dir/xcodegen.zip"
curl --fail --location --retry 2 --retry-delay 2 --connect-timeout 15 --max-time 120 \
  --proto '=https' --tlsv1.2 \
  'https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip' \
  --output "$archive"
# Fixed official 2.46.0 release asset, verified against its published SHA-256.
printf '%s  %s\n' '4d9e34b62172d645eed6457cac13fc222569974098ef4ee9c3368bedf0196806' "$archive" | shasum -a 256 -c -
ditto -x -k "$archive" "$tool_dir/unpacked"
binary="$(find "$tool_dir/unpacked" -type f -name xcodegen -print -quit)"
test -n "$binary"
install -m 755 "$binary" "$tool_dir/bin/xcodegen"
"$tool_dir/bin/xcodegen" --version
if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$tool_dir/bin" >> "$GITHUB_PATH"
else
  echo "Add $tool_dir/bin to PATH before running scripts/test-ui.sh."
fi

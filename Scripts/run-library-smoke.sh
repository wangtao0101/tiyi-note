#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
derived_data_directory="${TMPDIR:-/tmp}/tiyi-note-library-smoke"
app_path="${derived_data_directory}/Build/Products/Debug-iphonesimulator/TiyiNote.app"
smoke_token="$(date '+%Y%m%d-%H%M%S')"

device_id="$(xcrun simctl list devices booted | sed -nE \
  's/.*\(([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\).*/\1/p' \
  | head -n 1)"
if [[ -z "${device_id}" ]]; then
  device_id="$(xcrun simctl list devices available | sed -nE \
    '/iPad/ s/.*\(([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\).*/\1/p' \
    | head -n 1)"
  [[ -n "${device_id}" ]] || { print -u2 "没有可用的 iOS 模拟器"; exit 1; }
  xcrun simctl boot "${device_id}"
  open -a Simulator
  xcrun simctl bootstatus "${device_id}" -b
fi

xcodebuild \
  -project "${project_directory}/TiyiNote.xcodeproj" \
  -scheme TiyiNote \
  -configuration Debug \
  -sdk iphonesimulator \
  -derivedDataPath "${derived_data_directory}" \
  -quiet \
  CODE_SIGNING_ALLOWED=NO \
  build

xcrun simctl install "${device_id}" "${app_path}"
xcrun simctl terminate "${device_id}" com.tiyi.note >/dev/null 2>&1 || true
xcrun simctl launch "${device_id}" com.tiyi.note --library-smoke "${smoke_token}" >/dev/null

for _ in {1..30}; do
  sleep 1
  smoke_log="$(xcrun simctl spawn "${device_id}" log show \
    --last 2m \
    --style compact \
    --predicate 'process == "TiyiNote" && subsystem == "com.tiyi.note" && category == "LibrarySmoke"' \
    2>/dev/null)"
  if [[ "${smoke_log}" == *"TIYI_LIBRARY_SMOKE_PASS token=${smoke_token}"* ]]; then
    print "TIYI_LIBRARY_SMOKE_PASS token=${smoke_token}"
    exit 0
  fi
  if [[ "${smoke_log}" == *"TIYI_LIBRARY_SMOKE_FAIL token=${smoke_token}"* ]]; then
    print -u2 "${smoke_log}"
    exit 1
  fi
done

print -u2 "Library smoke timed out: ${smoke_token}"
exit 1

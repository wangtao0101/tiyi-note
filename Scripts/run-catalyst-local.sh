#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
project_directory="${script_directory:h}"
derived_data_directory="${TMPDIR:-/tmp}/tiyi-note-local-catalyst"
app_path="${derived_data_directory}/Build/Products/Debug-maccatalyst/TiyiNote.app"

xcodebuild \
  -project "${project_directory}/TiyiNote.xcodeproj" \
  -scheme TiyiNote \
  -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -derivedDataPath "${derived_data_directory}" \
  -quiet \
  CODE_SIGNING_ALLOWED=NO \
  build

# A local ad-hoc signature deliberately carries no CloudKit entitlement. The app detects this
# and keeps the local library usable instead of constructing an unavailable CKContainer.
codesign --force --deep --sign - "${app_path}"
pkill -x TiyiNote >/dev/null 2>&1 || true
if ! open -n "${app_path}"; then
  # Some macOS versions refuse LaunchServices startup for an ad-hoc Catalyst app in TMPDIR.
  # Direct launch is equivalent for this local, entitlement-free validation build.
  nohup "${app_path}/Contents/MacOS/TiyiNote" \
    >"${derived_data_directory}/TiyiNote-local.log" 2>&1 &
fi

print "Tiyi Note 已启动：${app_path}"

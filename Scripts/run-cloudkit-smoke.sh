#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
DERIVED_DATA="${TMPDIR%/}/tiyi-note-cloud-smoke"
APP_PATH="${DERIVED_DATA}/Build/Products/Debug-maccatalyst/TiyiNote.app"
SMOKE_TOKEN="$(date '+%Y%m%d-%H%M%S')"

cd "${PROJECT_DIR}"

xcodebuild \
  -project TiyiNote.xcodeproj \
  -scheme TiyiNote \
  -configuration Debug \
  -destination 'platform=macOS,variant=Mac Catalyst,arch=arm64' \
  -derivedDataPath "${DERIVED_DATA}" \
  -allowProvisioningUpdates \
  -allowProvisioningDeviceRegistration \
  -quiet \
  build

pkill -x TiyiNote >/dev/null 2>&1 || true
open -n "${APP_PATH}" --args --cloud-smoke "${SMOKE_TOKEN}"

# CKShare provisioning plus the offline-edit/permanent-delete conflict and fresh-replica checks
# can take about six minutes on Development CloudKit. Keep the watchdog bounded, but do not report
# a late PASS as a timeout while the server is still making progress.
for _ in {1..210}; do
  sleep 2
  SMOKE_LOG="$(/usr/bin/log show \
    --last 3m \
    --style compact \
    --predicate 'process == "TiyiNote" && subsystem == "com.tiyi.note" && category == "CloudSmoke"' \
    2>/dev/null)"
  if [[ "${SMOKE_LOG}" == *"TIYI_CLOUD_SMOKE_PASS token=${SMOKE_TOKEN}"* ]]; then
    print "TIYI_CLOUD_SMOKE_PASS token=${SMOKE_TOKEN}"
    exit 0
  fi
  if [[ "${SMOKE_LOG}" == *"TIYI_CLOUD_SMOKE_FAIL token=${SMOKE_TOKEN}"* ]]; then
    print -u2 "${SMOKE_LOG}"
    exit 1
  fi
done

print -u2 "CloudKit smoke timed out: ${SMOKE_TOKEN}"
exit 1

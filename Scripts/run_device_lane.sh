#!/usr/bin/env bash
# Runs MoneyUp's end-to-end journeys and the device-only crash guards on a
# connected physical iPhone. Required before any App Store submission: the
# simulator cannot reproduce device-only failures such as the 1064.1 crash.
#
# Usage: DEVELOPMENT_TEAM=<team id> Scripts/run_device_lane.sh [device-udid]
set -euo pipefail
cd "$(dirname "$0")/.."

: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to the Apple team ID used for device signing}"
DEVICE="${1:-$(xcrun devicectl list devices 2>/dev/null \
  | awk '/iPhone/ && /available|connected/ {print $3; exit}')}"
if [[ -z "${DEVICE}" ]]; then
  echo "No connected iPhone found. Connect one by cable or local network and trust this Mac." >&2
  exit 2
fi

STAMP="$(date +%Y-%m-%d)"
OUT="docs/review-evidence/${STAMP}/device-lane"
DERIVED="${TMPDIR:-/tmp}/moneyup-device-lane"
mkdir -p "${OUT}"
SIGNING=(-allowProvisioningUpdates DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" CODE_SIGN_STYLE=Automatic)

echo "== Device-only crash guards and journeys on ${DEVICE}"
xcodebuild -project MoneyUp.xcodeproj -scheme MoneyUp \
  -destination "id=${DEVICE}" -derivedDataPath "${DERIVED}" "${SIGNING[@]}" \
  -resultBundlePath "${OUT}/app-guards.xcresult" \
  -only-testing:MoneyUpTests/AppwideExperienceTests \
  -only-testing:MoneyUpTests/QuickLogFavouriteAppTests \
  -only-testing:MoneyUpTests/CrossFeatureAndStressTests \
  test | tee "${OUT}/app-guards.log" | grep -E "Test Case .*(passed|failed)|TEST (SUCCEEDED|FAILED)"

xcodebuild -project MoneyUp.xcodeproj -scheme MoneyUpColdLaunch \
  -destination "id=${DEVICE}" -derivedDataPath "${DERIVED}" "${SIGNING[@]}" \
  -parallel-testing-enabled NO \
  -resultBundlePath "${OUT}/journeys.xcresult" \
  -only-testing:MoneyUpUITests/MoneyUpJourneyTests \
  test | tee "${OUT}/journeys.log" | grep -E "Test Case .*(passed|failed)|TEST (SUCCEEDED|FAILED)"

echo "Device lane passed. Evidence: ${OUT}"

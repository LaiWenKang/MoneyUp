#!/usr/bin/env bash
set -euo pipefail
status=0
case "${REVIEW_SUITE:-full}" in
  full) entries=('MoneyUpUI26:ui26' 'MoneyUpColdLaunch:ui26-cold') ;;
  favourite) entries=('MoneyUpColdLaunch:ui26-cold') ;;
  *) echo "Unknown review suite" >&2; exit 2 ;;
esac
for entry in "${entries[@]}"; do
  bundle="$RUNNER_TEMP/${entry%%:*}.xcresult"
  prefix="$RUNNER_TEMP/${entry#*:}"
  if ! test -f "$bundle/Info.plist"; then
    printf 'Incomplete or absent result bundle: %s\n' "$bundle" >> "$RUNNER_TEMP/ui26-export-errors.log"
    status=1
    continue
  fi
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$prefix-images" 2>> "$RUNNER_TEMP/ui26-export-errors.log" || status=1
  if ! xcrun xcresulttool get test-results summary --path "$bundle" --compact > "$prefix-summary.json.tmp" 2>> "$RUNNER_TEMP/ui26-export-errors.log"; then
    status=1
  else
    mv "$prefix-summary.json.tmp" "$prefix-summary.json"
  fi
done
exit "$status"


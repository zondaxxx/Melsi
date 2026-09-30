#!/usr/bin/env bash
# Notarize and staple a signed DMG.
# Usage: packaging/macos/notarize.sh <file.dmg>
# Env: APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD (app-specific password).
set -euo pipefail

dmg="${1:?dmg required}"
: "${APPLE_ID:?}" "${APPLE_TEAM_ID:?}" "${APPLE_APP_PASSWORD:?}"

xcrun notarytool submit "$dmg" \
  --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD" \
  --wait --timeout 30m
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"

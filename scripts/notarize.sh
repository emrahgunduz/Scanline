#!/bin/zsh
# Notarizes and staples a Developer ID signed Scanline.app.
#   scripts/notarize.sh build/Release/Scanline.app
# Credentials, in order:
#   NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID   App Store Connect API key (CI)
#   NOTARY_PROFILE (default scanline-notary)             a profile saved with
#                                                        `xcrun notarytool store-credentials`
# On rejection it prints Apple's log and exits non-zero. On success it writes NOTARIZED next to the app.
set -euo pipefail
app=${1:?usage: notarize.sh path/to/Scanline.app}
[[ -d $app ]] || { echo "no app at $app" >&2; exit 1; }
out=${app:h}

# Only a Developer ID signature can be notarized.
team=$(codesign -dvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p' || true)   # unsigned: empty
if [[ -z $team || $team == "not set" ]]; then
  echo "notarize: $app is not signed with a Developer ID (ad-hoc builds can't be notarized)" >&2
  exit 1
fi

if [[ -n ${NOTARY_KEY_PATH:-} || -n ${NOTARY_KEY_ID:-} || -n ${NOTARY_ISSUER_ID:-} ]]; then
  [[ -n ${NOTARY_KEY_PATH:-} && -n ${NOTARY_KEY_ID:-} && -n ${NOTARY_ISSUER_ID:-} ]] || {
    echo "notarize: set all of NOTARY_KEY_PATH, NOTARY_KEY_ID and NOTARY_ISSUER_ID" >&2; exit 1; }
  [[ -f $NOTARY_KEY_PATH ]] || { echo "notarize: no key file at NOTARY_KEY_PATH" >&2; exit 1; }
  auth=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
else
  auth=(--keychain-profile "${NOTARY_PROFILE:-scanline-notary}")
fi

zip="$out/notarize.zip"
result="$out/notary-submit.json"
trap 'rm -f "$zip"' EXIT
rm -f "$out/NOTARIZED"
ditto -c -k --keepParent "$app" "$zip"
echo "Submitting to Apple's notary service (this can take a few minutes)…" >&2
xcrun notarytool submit "$zip" "${auth[@]}" --wait --timeout 30m --output-format json > "$result" || true
id=$(plutil -extract id raw "$result" 2>/dev/null || true)
notary_status=$(plutil -extract status raw "$result" 2>/dev/null || true)
echo "Notarization: ${notary_status:-no result} (${id:-no id})" >&2
if [[ $notary_status != Accepted ]]; then
  if [[ -n $id ]]; then
    xcrun notarytool log "$id" "${auth[@]}" "$out/notary-log.json" >/dev/null 2>&1 || true
    [[ -f $out/notary-log.json ]] && cat "$out/notary-log.json" >&2
  else
    cat "$result" >&2
  fi
  exit 1
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"
assessment=$(spctl -a -vv -t exec "$app" 2>&1)
echo "$assessment" >&2
[[ $assessment == *accepted* && $assessment == *"Notarized Developer ID"* ]] || {
  echo "notarize: Gatekeeper doesn't accept the stapled app" >&2; exit 1; }
touch "$out/NOTARIZED"

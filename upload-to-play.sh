#!/usr/bin/env bash
#
# AMI: NOTE: this has never been used. Had Claude write it thinking
# maybe I'd use it instead of manually clicking around Play Console,
# but haven't reviewed or tried it yet.
#
# Upload a signed AAB to a Play Console testing track via the Google Play Developer API.
#
# One-time setup:
#   1. Google Cloud Console -> IAM & Admin -> Service Accounts -> Create service account
#      -> Keys -> Add key -> JSON. Save it as ~/keystores/play-service-account.json (chmod 600).
#   2. Play Console -> Users and permissions -> Invite new users -> enter the service account's
#      email -> App permissions: add this app with at least "Release to testing tracks"
#      (and "View app information") -> Invite. Permissions can take a few minutes to propagate.
#   The first release of an app must be created manually in the Console; the API only works after that.
#
# Usage:
#   ./upload-to-play.sh [--track alpha|internal|beta|production] [--draft] [--notes "text"]
#                       [--project DIR] [--module NAME] [path.aab]
#     --track    Track to release to. Default: alpha (= "Closed testing" in the Console).
#     --draft    Create the release as a draft instead of rolling it out.
#     --notes    en-US release notes for this release.
#     --project, --module  As for build-and-deploy.sh: which project's (app module's) AAB to upload.
#     path.aab   Default: the app module's build/outputs/bundle/release/*.aab (output of
#                build-and-deploy.sh --release-aab --build-only).
#   The package to release comes from the AAB.
#
# Env:
#   PLAY_SERVICE_ACCOUNT_JSON  Path to the service account key. Default: ~/keystores/play-service-account.json
#
# Requires: curl, openssl, python3, bundletool (all from install-android-sdk.sh).

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SA_JSON="${PLAY_SERVICE_ACCOUNT_JSON:-$HOME/keystores/play-service-account.json}"

TRACK="alpha"
STATUS="completed"
NOTES=""
AAB=""
PROJECT=""
WANT_MODULE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --track) TRACK="$2"; shift 2 ;;
    --draft) STATUS="draft"; shift ;;
    --notes) NOTES="$2"; shift 2 ;;
    --project) PROJECT="$2"; shift 2 ;;
    --module) WANT_MODULE="$2"; shift 2 ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; exit 1 ;;
    *) AAB="$1"; shift ;;
  esac
done

if [ -z "$AAB" ]; then
  set-root "$PROJECT"
  set-module "$WANT_MODULE"
  AAB="$(ls -t "$MODDIR"/build/outputs/bundle/release/*.aab 2>/dev/null | head -1 || true)"
fi
[ -f "$AAB" ] || die "AAB not found${AAB:+: $AAB} (build it with build-and-deploy.sh --release-aab --build-only)"
[ -f "$SA_JSON" ] || die "Service account key not found: $SA_JSON"

PACKAGE="$(package-of "$AAB")"
API="https://androidpublisher.googleapis.com/androidpublisher/v3/applications/$PACKAGE"
UPLOAD_API="https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/$PACKAGE"
echo "==> Releasing $PACKAGE from $AAB"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
umask 077

# --- OAuth2: service-account JWT -> access token ----------------------------------------------
function json-get() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$@"; }
function b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

SA_EMAIL="$(json-get "$SA_JSON" client_email)"
json-get "$SA_JSON" private_key > "$TMP/key.pem"

NOW="$(date +%s)"
HEADER="$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)"
CLAIMS="$(printf '{"iss":"%s","scope":"https://www.googleapis.com/auth/androidpublisher","aud":"https://oauth2.googleapis.com/token","iat":%d,"exp":%d}' \
  "$SA_EMAIL" "$NOW" "$((NOW + 3600))" | b64url)"
SIG="$(printf '%s.%s' "$HEADER" "$CLAIMS" | openssl dgst -sha256 -sign "$TMP/key.pem" | b64url)"
JWT="$HEADER.$CLAIMS.$SIG"

echo "==> Authenticating as $SA_EMAIL..."
curl -sS -o "$TMP/token.json" -w '%{http_code}' https://oauth2.googleapis.com/token \
  --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer' \
  --data-urlencode "assertion=$JWT" > "$TMP/status"
[ "$(cat "$TMP/status")" = 200 ] || { echo "ERROR: token request failed:" >&2; cat "$TMP/token.json" >&2; exit 1; }
TOKEN="$(json-get "$TMP/token.json" access_token)"

# --- Play Developer API helpers --------------------------------------------------------------
# api <METHOD> <URL> [extra curl args...] ; response body is left in $TMP/resp.json
function api() {
  local method="$1" url="$2"; shift 2
  local status
  status="$(curl -sS -o "$TMP/resp.json" -w '%{http_code}' -X "$method" \
    -H "Authorization: Bearer $TOKEN" "$url" "$@")"
  if [ "${status:0:1}" != 2 ]; then
    echo "ERROR: $method $url -> HTTP $status" >&2
    cat "$TMP/resp.json" >&2; echo >&2
    [ -n "${EDIT_ID:-}" ] && curl -sS -o /dev/null -X DELETE -H "Authorization: Bearer $TOKEN" "$API/edits/$EDIT_ID" || true
    exit 1
  fi
}

echo "==> Opening edit..."
api POST "$API/edits" -H 'Content-Type: application/json' -d '{}'
EDIT_ID="$(json-get "$TMP/resp.json" id)"

echo "==> Uploading $AAB ($(du -h "$AAB" | cut -f1))..."
api POST "$UPLOAD_API/edits/$EDIT_ID/bundles?uploadType=media" \
  -H 'Content-Type: application/octet-stream' --data-binary "@$AAB"
VERSION_CODE="$(json-get "$TMP/resp.json" versionCode)"
echo "    versionCode $VERSION_CODE"

echo "==> Assigning versionCode $VERSION_CODE to track '$TRACK' (status: $STATUS)..."
python3 - "$TRACK" "$VERSION_CODE" "$STATUS" "$NOTES" > "$TMP/track.json" <<'PY'
import json, sys
track, vc, status, notes = sys.argv[1:5]
release = {"versionCodes": [vc], "status": status}
if notes:
    release["releaseNotes"] = [{"language": "en-US", "text": notes}]
print(json.dumps({"track": track, "releases": [release]}))
PY
api PUT "$API/edits/$EDIT_ID/tracks/$TRACK" -H 'Content-Type: application/json' --data-binary "@$TMP/track.json"

echo "==> Committing edit..."
api POST "$API/edits/$EDIT_ID:commit"

echo "==> Done. versionCode $VERSION_CODE is now $STATUS on the '$TRACK' track."
echo "    https://play.google.com/console/"

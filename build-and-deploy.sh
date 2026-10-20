#!/usr/bin/env bash
#
# Build an Android app's APK (or AAB) and deploy it to a connected device. Run it from anywhere inside the project
# (or pass --project, or copy/symlink it into <project>/.headless). It works out what each project needs:
#   - the app module: whichever one applies com.android.application (":app", or the root project);
#   - --release: a "debugRelease" build type (release code, debug-signed) if the module has one, else "release";
#     an unsigned release APK is signed with the keystore below, and -Psideload is passed if the build reads it;
#   - --release-aab: an AAB the build left unsigned is signed with the keystore below;
#   - ktlint: ktlintFormat + ktlintCheck run first if the project uses org.jlleitschuh.gradle.ktlint;
#   - the package and launcher activity come from the built APK/AAB and the device (so e.g. a ".debug"
#     applicationIdSuffix is handled).
#
# Prerequisites:
#   1. Run install-android-sdk.sh (once per VM/container).
#   2. ANDROID_HOME set, or the SDK in ~/android-sdk.
#   3. A device reachable over adb: USB, an emulator, wireless debugging (connect-adb.sh finds the port; see
#      there), or an SSH tunnel:
#        laptop$ ssh -R 15555:<phone-ip>:<phone-adb-port> <vm>
#        vm$     adb connect localhost:15555
#      Use a port outside 5554-5585 to avoid adb's emulator auto-detection.
#
# Usage: build-and-deploy.sh [flags] [-- extra gradle args]
#   (no flags)        build the debug APK, install it, launch it
#   --release         build + install + launch a release APK (see above for which)
#   --release-aab     build the Play Store bundle, then install the APKs bundletool derives from it + launch
#   --build-only      just build (combine with --release or --release-aab)
#   --no-launch       don't launch after installing
#   --project DIR     the project (default: the one containing the current directory)
#   --module NAME     the app module, when there are several (default: the only one)
#
# Env:
#   KEYSTORE, KEY_ALIAS  for signing what the build leaves unsigned. Default: ~/keystores/android-keystore.jks, key0
#   KS_PASS              its password; asked for if unset (and needed)
#   ADB_PHONE_HOST       the phone connect-adb.sh scans (see there)
#   CONNECT_TIMEOUT      seconds (counted from the start, so the build counts) to give connect-adb.sh; default 120
#
# Note: APKs installed from a keystore-signed --release / --release-aab are signed with the local keystore. If Play
# App Signing uses a different key, the Play Store cannot update over them; uninstall first or sideload the
# Play-signed universal APK from the Play Console instead. When the build signed the AAB itself, bundletool signs
# the APKs it derives with the debug key, like a debugRelease APK.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BUILD_ONLY=false
RELEASE=false
RELEASE_AAB=false
NO_LAUNCH=false
PROJECT=
WANT_MODULE=
EXTRA_GRADLE_ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --build-only)  BUILD_ONLY=true ;;
    --release)     RELEASE=true ;;
    --release-aab) RELEASE_AAB=true ;;
    --no-launch)   NO_LAUNCH=true ;;
    --project)     PROJECT="${2:?--project needs a directory}"; shift ;;
    --module)      WANT_MODULE="${2:?--module needs a name}"; shift ;;
    -h|--help)     sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --)            shift; EXTRA_GRADLE_ARGS=("$@"); break ;;
    *)             die "Unknown argument: $1 (see --help)" ;;
  esac
  shift
done
! $RELEASE || ! $RELEASE_AAB || die "--release and --release-aab don't go together"

set-root "$PROJECT"
set-module "$WANT_MODULE"
cd "$ROOT"

KEYSTORE="${KEYSTORE:-$HOME/keystores/android-keystore.jks}"
KEY_ALIAS="${KEY_ALIAS:-key0}"

TMP="$(mktemp -d)"
CONNECT_PID=
# Stops connect-adb.sh and its nmap (it runs as its own process group).
function stop-connect() {
  [ -z "$CONNECT_PID" ] || kill -- "-$CONNECT_PID" 2>/dev/null || true
  CONNECT_PID=
}
function cleanup() {
  rm -rf "$TMP"
  stop-connect # One still scanning (e.g. after a failed build) would connect later, out of the blue.
}
trap cleanup EXIT

# Find and connect to the phone's wireless debugging port while building, unless a device is already attached (a
# second one would make adb ask which to use).
if ! $BUILD_ONLY && ! adb devices 2>/dev/null | grep -q 'device$'; then
  if command -v nmap >/dev/null; then
    CONNECT_DEADLINE=$((SECONDS + ${CONNECT_TIMEOUT:-120}))
    setsid "$HEADLESS_DIR/connect-adb.sh" >"$TMP/connect.log" 2>&1 &
    CONNECT_PID=$!
  else
    echo "==> No device attached and no nmap to look for one (run install-android-sdk.sh)" >&2
  fi
fi

GRADLE_ARGS=()
TASKS=()
if grep -qs "org.jlleitschuh.gradle.ktlint" "$ROOT"/build.gradle* "$MODFILE"; then
  TASKS+=("${TASK_PREFIX}ktlintFormat" "${TASK_PREFIX}ktlintCheck")
fi
if $RELEASE_AAB; then
  VARIANT=release
  TASKS+=("${TASK_PREFIX}bundleRelease")
elif $RELEASE && has-build-type debugRelease; then
  VARIANT=debugRelease
  TASKS+=("${TASK_PREFIX}assembleDebugRelease")
elif $RELEASE; then
  VARIANT=release
  TASKS+=("${TASK_PREFIX}assembleRelease")
  # A sideloaded release build can get a versionCode below the Play upload's (see the module's build file) so the
  # Play Store build replaces it once it's published.
  ! grep -qE 'hasProperty\(.sideload.\)' "$MODFILE" || GRADLE_ARGS+=(-Psideload)
else
  VARIANT=debug
  TASKS+=("${TASK_PREFIX}assembleDebug")
fi

echo "==> Building ${TASKS[*]} in $ROOT..."
./gradlew --warning-mode all \
  ${GRADLE_ARGS[@]+"${GRADLE_ARGS[@]}"} ${EXTRA_GRADLE_ARGS[@]+"${EXTRA_GRADLE_ARGS[@]}"} "${TASKS[@]}"

function ask-password() {
  [ -f "$KEYSTORE" ] || die "Keystore not found: $KEYSTORE"
  if [ -z "${KS_PASS:-}" ]; then
    read -r -s -p "Enter keystore password for $KEYSTORE: " KS_PASS
    echo ""
  fi
  export KS_PASS
}

SIGNED_HERE=false
if $RELEASE_AAB; then
  AAB="$(newest "$MODDIR/build/outputs/bundle/release" "*.aab")"
  if ! unzip -l "$AAB" | grep -qE 'META-INF/[^/]+\.(RSA|EC|DSA)$'; then
    ask-password
    jarsigner -keystore "$KEYSTORE" -storepass:env KS_PASS "$AAB" "$KEY_ALIAS"
    SIGNED_HERE=true
  fi
  echo "==> AAB: $AAB ($(du -h "$AAB" | cut -f1))"
else
  APK="$(newest "$MODDIR/build/outputs/apk/$VARIANT" "*.apk")"
  if [[ "$APK" == *-unsigned.apk ]]; then
    ask-password
    SIGNED="${APK%-unsigned.apk}-signed.apk"
    "$(latest-build-tools)/apksigner" sign --ks "$KEYSTORE" --ks-key-alias "$KEY_ALIAS" --ks-pass env:KS_PASS \
      --out "$SIGNED" "$APK"
    APK="$SIGNED"
  fi
  echo "==> APK: $APK ($(du -h "$APK" | cut -f1))"
fi

if $BUILD_ONLY; then
  exit 0
fi

if [ -n "$CONNECT_PID" ]; then
  echo "==> Waiting for connect-adb.sh..."
  while kill -0 "$CONNECT_PID" 2>/dev/null && [ "$SECONDS" -lt "$CONNECT_DEADLINE" ]; do sleep 1; done
  if kill -0 "$CONNECT_PID" 2>/dev/null; then
    echo "connect-adb.sh found no phone within ${CONNECT_TIMEOUT:-120}s; giving up" >&2
    stop-connect
  else
    wait "$CONNECT_PID" || echo "connect-adb.sh failed" >&2
    CONNECT_PID=
  fi
  cat "$TMP/connect.log"
fi
adb devices | grep -q 'device$' || die "No ADB device connected."

if $RELEASE_AAB; then
  # Generate device-specific APKs from the AAB and install them (what the Play Store would do).
  require-bundletool
  PACKAGE="$(package-of "$AAB")"
  KS_ARGS=()
  if $SIGNED_HERE; then
    # bundletool only accepts pass:<clear> or file:<path>; use a private file to keep it off the command line.
    (umask 077; printf '%s\n' "$KS_PASS" > "$TMP/ks-pass")
    KS_ARGS=(--ks="$KEYSTORE" --ks-pass="file:$TMP/ks-pass" --ks-key-alias="$KEY_ALIAS")
  fi
  echo "==> Generating APKs from the bundle for the connected device..."
  java -jar "$BUNDLETOOL" build-apks --bundle="$AAB" --output="$TMP/app.apks" --overwrite \
    --connected-device --adb="$(command -v adb)" ${KS_ARGS[@]+"${KS_ARGS[@]}"}
  echo "==> Installing $PACKAGE..."
  java -jar "$BUNDLETOOL" install-apks --apks="$TMP/app.apks" --adb="$(command -v adb)"
else
  PACKAGE="$(package-of "$APK")"
  echo "==> Installing $PACKAGE..."
  if ! adb install "$APK"; then
    echo "==> Installation failed; uninstalling first (e.g. for a key mismatch), which drops the app's data..."
    adb uninstall "$PACKAGE" 2>/dev/null || true
    adb install "$APK"
  fi
fi

if ! $NO_LAUNCH; then
  echo "==> Launching..."
  COMPONENT="$(adb shell cmd package resolve-activity --brief -a android.intent.action.MAIN \
    -c android.intent.category.LAUNCHER "$PACKAGE" | tail -1 | tr -d '\r')"
  [[ "$COMPONENT" == */* ]] || die "Could not find $PACKAGE's launcher activity; not launching"
  adb shell am start -n "$COMPONENT"
fi

echo "==> Done."

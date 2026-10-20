# shellcheck shell=bash disable=SC2034
# Shared by build-and-deploy.sh and upload-to-play.sh: finding the project, its app module, and the SDK tools.
# Source it; it defines functions and sets ANDROID_HOME/PATH, nothing else.

export ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"

HEADLESS_DIR="$(realpath "$(dirname "${BASH_SOURCE[0]}")")"
BUNDLETOOL="$ANDROID_HOME/bundletool.jar"

function die() { echo "ERROR: $*" >&2; exit 1; }

# The Gradle project containing $1: the nearest directory at or above it with a settings.gradle(.kts).
function find-root() {
  local d
  d="$(cd "$1" 2>/dev/null && pwd)" || return 1
  while [ "$d" != / ]; do
    if [ -f "$d/settings.gradle.kts" ] || [ -f "$d/settings.gradle" ]; then echo "$d"; return 0; fi
    d="$(dirname "$d")"
  done
  return 1
}

# Sets ROOT: --project's directory if given ($1), else the project containing the current directory, else the one
# containing this script's directory (for a copy or symlink in <project>/.headless).
function set-root() {
  if [ -n "${1:-}" ]; then
    ROOT="$(find-root "$1")" || die "No Gradle project at or above $1"
  else
    ROOT="$(find-root "$PWD")" || ROOT="$(find-root "$(dirname "$0")/..")" ||
      die "Not in a Gradle project; cd into one or pass --project DIR"
  fi
}

# The build file of a module directory, if any.
function build-file() {
  local f
  for f in "$1/build.gradle.kts" "$1/build.gradle"; do [ -f "$f" ] && { echo "$f"; return 0; }; done
  return 1
}

# Sets MODULE ("" for the root project), MODDIR, MODFILE and TASK_PREFIX (":app:", or ":" for the root project).
# $1 is --module's value, if given; otherwise the one module (root or top-level) that applies
# com.android.application (not just declares it with "apply false").
function set-module() {
  local want="${1:-}" d f found=()
  if [ -n "$want" ]; then
    found=("$want")
  else
    for d in "$ROOT" "$ROOT"/*/; do
      d="${d%/}"
      f="$(build-file "$d")" || continue
      grep -E "com\.android\.application" "$f" | grep -qv "apply false" || continue
      if [ "$d" = "$ROOT" ]; then found+=(""); else found+=("${d#"$ROOT"/}"); fi
    done
    [ ${#found[@]} -gt 0 ] || die "No module in $ROOT applies com.android.application"
    [ ${#found[@]} -eq 1 ] || die "Several app modules in $ROOT (${found[*]}); pick one with --module"
  fi
  MODULE="${found[0]}"
  MODDIR="$ROOT${MODULE:+/$MODULE}"
  MODFILE="$(build-file "$MODDIR")" || die "No build.gradle(.kts) in $MODDIR"
  TASK_PREFIX=":${MODULE:+$MODULE:}"
}

# The module's buildTypes { ... } block (brace-matched), to look for custom build types in.
function build-types-block() {
  awk '!on && /buildTypes[ \t]*\{/ { on = 1 }
       on { print; n = gsub(/\{/, "{"); m = gsub(/\}/, "}"); depth += n - m; if (depth <= 0) exit }' "$MODFILE"
}

# Whether the module defines a build type named $1.
function has-build-type() {
  build-types-block | grep -qE "create\(\"$1\"\)|register\(\"$1\"\)|^[[:space:]]*$1[[:space:]]*\{"
}

# The newest file matching $2 in directory $1.
function newest() {
  local f
  f="$(ls -t "$1"/$2 2>/dev/null | head -1)"
  [ -n "$f" ] || die "Nothing matching $2 in $1"
  echo "$f"
}

function latest-build-tools() {
  local v
  v="$(ls "$ANDROID_HOME/build-tools" 2>/dev/null | sort -V | tail -1)"
  [ -n "$v" ] || die "No build-tools in $ANDROID_HOME; run install-android-sdk.sh"
  echo "$ANDROID_HOME/build-tools/$v"
}

function require-bundletool() {
  [ -f "$BUNDLETOOL" ] || die "bundletool not found at $BUNDLETOOL; run install-android-sdk.sh"
}

# The package name of an APK ($1) or AAB ($1 ending in .aab).
function package-of() {
  case "$1" in
    *.aab) require-bundletool; java -jar "$BUNDLETOOL" dump manifest --bundle="$1" --xpath=/manifest/@package ;;
    *) "$(latest-build-tools)/aapt2" dump packagename "$1" ;;
  esac
}

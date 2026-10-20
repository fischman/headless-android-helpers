#!/usr/bin/env bash
#
# Install Android SDK command-line tools for headless builds.
# Run once per VM/container.
#
# Usage: install-android-sdk.sh [--emulator]
#   --emulator  also install the emulator/image/libraries/AVD
#               (emulator -avd p8 -no-window -no-audio; needs /dev/kvm)
#
# Env: ANDROID_HOME, where to install (default ~/android-sdk); AVD_NAME, the AVD's name (default p8).

set -euo pipefail

CMDLINE_TOOLS_BUILD=15859902 # https://developer.android.com/studio#command-line-tools-only
PLATFORM="platforms;android-37.0"
BUILD_TOOLS="build-tools;37.0.0"
NDK="ndk;30.0.16248370"
BUNDLETOOL_VERSION=1.18.3 # https://github.com/google/bundletool/releases
SYSTEM_IMAGE="system-images;android-37.0;google_apis;x86_64"

EMULATOR=false
for arg in "$@"; do
  case "$arg" in
    --emulator) EMULATOR=true ;;
    -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown argument: $arg (see --help)" >&2; exit 1 ;;
  esac
done

# System packages; curl, openssl and python3 are for upload-to-play.sh.
APT=(default-jdk-headless unzip curl nmap openssl python3)
# What the emulator links against, including its bundled Qt/WebEngine.
$EMULATOR && APT+=(libx11-6 libx11-xcb1 libgl1 libpulse0 libnss3 libxcomposite1 libxcursor1 libxdamage1 libxi6
  libxtst6 libxrandr2 libxkbfile1 libdrm2 libgbm1 libasound2t64 libxkbcommon0)
[ "$(id -u)" -eq 0 ] || SUDO=sudo
${SUDO:-} apt-get update
${SUDO:-} apt-get install -y --no-install-recommends "${APT[@]}"

ANDROID_HOME="${ANDROID_HOME:-$HOME/android-sdk}"
echo "Installing Android SDK to $ANDROID_HOME"

mkdir -p "$ANDROID_HOME"
cd "$ANDROID_HOME"

# Command-line tools, as the SDK package "cmdline-tools;latest" in
# cmdline-tools/latest/ (which has a package.xml). The zip's tools,
# which lag behind, only bootstrap that, and replace a
# cmdline-tools/latest/ that an older script unzipped by hand
# (sdkmanager would install next to it, as latest-2/).
ZIP="commandlinetools-linux-${CMDLINE_TOOLS_BUILD}_latest.zip"
if [ ! -f cmdline-tools/latest/package.xml ]; then
  [ -f "$ZIP" ] || curl -fSL -o "$ZIP" "https://dl.google.com/android/repository/$ZIP"
  rm -rf cmdline-tools-bootstrap cmdline-tools/latest cmdline-tools/latest-[0-9]*
  unzip -qo "$ZIP" -d cmdline-tools-bootstrap
  yes | cmdline-tools-bootstrap/cmdline-tools/bin/sdkmanager --sdk_root="$ANDROID_HOME" --licenses > /dev/null 2>&1 || true
  cmdline-tools-bootstrap/cmdline-tools/bin/sdkmanager --sdk_root="$ANDROID_HOME" "cmdline-tools;latest"
  rm -rf cmdline-tools-bootstrap
fi
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"

# Licenses (also lets Gradle download anything else a project pins). Redundant in bootstrap runs.
yes | "$SDKMANAGER" --licenses > /dev/null 2>&1 || true

# SDK packages (and updates to the command-line tools).
PACKAGES=("cmdline-tools;latest" "platform-tools" "$PLATFORM" "$BUILD_TOOLS" "$NDK")
$EMULATOR && PACKAGES+=("emulator" "$SYSTEM_IMAGE")
"$SDKMANAGER" "${PACKAGES[@]}"

# bundletool (build-and-deploy.sh --release-aab installs an AAB's APKs with it).
if [ ! -f bundletool.jar ] || ! java -jar bundletool.jar version 2>/dev/null | grep -qx "$BUNDLETOOL_VERSION"; then
  curl -fSL -o bundletool.jar \
    "https://github.com/google/bundletool/releases/download/$BUNDLETOOL_VERSION/bundletool-all-$BUNDLETOOL_VERSION.jar"
fi

# An AVD for the emulator.
AVD_NAME="${AVD_NAME:-p8}"
AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"
if $EMULATOR && ! "$AVDMANAGER" list avd -c | grep -qx "$AVD_NAME"; then
  # "no" means not a custom HW profile; use pixel_8 defaults below,
  # and then modify by editing config.ini.
  echo no | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$SYSTEM_IMAGE" -d pixel_8
  CONFIG="$("$AVDMANAGER" list avd | awk -v n="$AVD_NAME" '$1 == "Name:" { m = $2 == n } m && $1 == "Path:" { print $2 }')/config.ini"
  sed -i -e '/^disk.dataPartition.size=/d' -e '/^hw.ramSize=/d' "$CONFIG"
  printf 'disk.dataPartition.size=6G\nhw.ramSize=6144\n' >> "$CONFIG"
fi

# ANDROID_HOME and PATH for new shells (once).
if ! grep -qs "^export ANDROID_HOME=$ANDROID_HOME\$" ~/.bashrc; then
  echo "Adding ANDROID_HOME and its PATH to ~/.bashrc"
  {
    echo "export ANDROID_HOME=$ANDROID_HOME"
    echo "export PATH=\$ANDROID_HOME/platform-tools:\$ANDROID_HOME/cmdline-tools/latest/bin:\$ANDROID_HOME/emulator:\$PATH"
  } >> ~/.bashrc
fi
echo "Done. source ~/.bashrc to be ready to rock."

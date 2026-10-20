#!/bin/bash
#
# Find the phone's wireless debugging port (it changes each time wireless debugging is turned on) and connect adb to
# it, so there's no fiddling with the phone or copying ports and pairing codes. Scans the phone's ephemeral ports and
# connects to the first one where adbd answers. Relies on ~/.android/adbkey (in the host or container) already being
# authorized on the phone. build-and-deploy.sh runs this in the background while building.
#
# Env: ADB_PHONE_HOST, the phone's address (default 192.168.50.67).

set -eu -o pipefail

HOST="${ADB_PHONE_HOST:-192.168.50.67}"

probe() {  # probe IP PORT: prints adbd's 4-byte reply, if any
  timeout 1 bash -c 'exec 3<>/dev/tcp/$0/$1 || exit 1
    printf "CNXN\x01\x00\x00\x01\x00\x00\x10\x00\x07\x00\x00\x00\x32\x02\x00\x00\xbc\xb1\xa7\xb1host::\x00" >&3
    head -c4 <&3' "$1" "$2" 2>/dev/null
}


exec 3< <(nmap -v -n -Pn -sT --unprivileged --max-retries 1 --max-rtt-timeout 300ms --min-parallelism 10 -p 32768-60999 "$HOST" 2>/dev/null)
pid=$!
while read -r line <&3; do
  [[ $line =~ Discovered\ open\ port\ ([0-9]+) ]] || continue
  port="${BASH_REMATCH[1]}"
  [[ $(probe "$HOST" "$port") =~ ^(STLS|CNXN|AUTH)$ ]] || continue
  adb connect "$HOST:$port"
  kill $pid 2>/dev/null
  break
done
exec 3<&-

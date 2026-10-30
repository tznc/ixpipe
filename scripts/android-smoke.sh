#!/usr/bin/env bash
# Installs the ixpipe APK on a running emulator, checks the embedded BEAM
# boots and renders, taps "New workflow" on the home screen and checks the
# canvas opens. Saves screenshots and logcat to the output directory.
# Modelled on baguette's scripts/android-smoke.sh.
#
#   scripts/android-smoke.sh ixpipe.apk [OUT_DIR]
set -euo pipefail

APK=$1
OUT=${2:-android-smoke}
PKG=${PKG:-dev.baguette.ixpipe}
mkdir -p "$OUT"
ADB_BIN=$(command -v adb)
adb() { timeout 90 "$ADB_BIN" "$@"; }

timeout 300 "$ADB_BIN" wait-for-device
adb shell settings put global hide_error_dialogs 1 || true
adb shell am broadcast -a android.intent.action.CLOSE_SYSTEM_DIALOGS >/dev/null || true
adb install -r -g "$APK"
adb shell am wait-for-broadcast-idle || sleep 5
adb logcat -c
"$ADB_BIN" logcat >"$OUT/logcat.txt" 2>&1 &
logcat=$!
trap 'adb exec-out screencap -p >"$OUT/final.png" || true; kill "$logcat" 2>/dev/null || true' EXIT
adb shell am start -n "$PKG/.MainActivity"

failures=0
wait_for() {
  local deadline=$((SECONDS + $2))
  while ((SECONDS < deadline)); do
    if grep -Eq "$1" "$OUT/logcat.txt"; then return 0; fi
    sleep 1
  done
  echo "FAIL: no logcat line matching /$1/ within $2 s"
  failures=$((failures + 1))
  return 1
}
shot() { adb exec-out screencap -p >"$OUT/$1.png"; }
# tap <label>: taps the centre the host logged for an aria-labelled control.
tap() {
  local at
  at=$(grep -Eo "baguette: bounds $1 [0-9]+ [0-9]+" "$OUT/logcat.txt" | tail -1 | grep -Eo '[0-9]+ [0-9]+$')
  if [[ -z $at ]]; then
    echo "FAIL: no bounds logged for $1"
    failures=$((failures + 1))
    return 1
  fi
  echo "tap $1 at $at"
  # shellcheck disable=SC2086
  adb shell input tap $at
}

wait_for 'baguette: release at' 120
wait_for 'baguette: first frame from Elixir' 120
wait_for 'baguette: bounds New workflow [0-9]+ [0-9]+' 30
sleep 2
shot home
tap "New workflow"
# The canvas's toolbar: its controls report bounds once it renders.
wait_for 'baguette: bounds Run workflow [0-9]+ [0-9]+' 30
sleep 2
shot canvas

# Known gap: baguette ships only its own NIF as a jniLib, so Explorer (and
# exqlite) have no Android build in the APK. Report it; don't fail on it yet.
if grep -Eq 'baguette: no lib.* in the app|on_load function for module .*(Explorer|Exqlite)' "$OUT/logcat.txt"; then
  echo "WARN: third-party NIFs are missing on Android (Explorer/exqlite); running a workflow will fail"
fi

if adb shell pidof "$PKG" >/dev/null; then echo "app still running"; else
  echo "FAIL: the app exited"
  failures=$((failures + 1))
fi
grep -E 'baguette|beam|ixpipe|FATAL|AndroidRuntime' "$OUT/logcat.txt" | tail -40 || true
if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "PASS: ixpipe boots on Android and opens the canvas"

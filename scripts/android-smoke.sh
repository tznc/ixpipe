#!/usr/bin/env bash
# Installs the ixpipe APK on a running emulator and proves the engine runs
# there: the embedded BEAM boots and renders, the canvas opens, and a
# workflow that reads a CSV, sorts it and writes it to CSV (Explorer) and
# SQLite (ixpipe_sqlite) runs from the Run workflow button and leaves the
# right files behind; a swipe scrolls the canvas. Fails if any NIF is missing
# from the APK, or the host reports an unknown icon or an unsupported class.
# Saves screenshots (home, canvas, run, scrolled) and logcat to the output
# directory.
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
# as_app <command>: a shell command as the app, in its data directory.
as_app() { adb shell "run-as $PKG sh -c '$1'"; }

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
fail() {
  echo "FAIL: $1"
  failures=$((failures + 1))
}
# wait_for <regex> <seconds> [from line]: waits for a logcat line, counting
# only lines after `from` (so a relaunch doesn't match the first launch).
wait_for() {
  local deadline=$((SECONDS + $2)) from=${3:-0}
  while ((SECONDS < deadline)); do
    # Not `tail | grep -q`: grep exits on the first match, tail dies of
    # SIGPIPE, and pipefail turns the match into a failure.
    if grep -Eq "$1" < <(tail -n +$((from + 1)) "$OUT/logcat.txt"); then return 0; fi
    sleep 1
  done
  fail "no logcat line matching /$1/ within $2 s"
  return 1
}
lines() { wc -l <"$OUT/logcat.txt"; }
shot() { adb exec-out screencap -p >"$OUT/$1.png"; }
# tap <label>: taps the centre the host logged for an aria-labelled control.
tap() {
  local at
  at=$(grep -Eo "baguette: bounds $1 [0-9]+ [0-9]+" "$OUT/logcat.txt" | tail -1 | grep -Eo '[0-9]+ [0-9]+$')
  if [[ -z $at ]]; then
    fail "no bounds logged for $1"
    return 1
  fi
  echo "tap $1 at $at"
  local width
  width=$(adb shell wm size | tr -d '\r' | grep -Eo '[0-9]+x[0-9]+' | tail -1 | cut -dx -f1)
  if ((${at% *} >= width)); then
    fail "$1 is off screen (x ${at% *}, screen ${width} px wide)"
    return 1
  fi
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

# Every NIF in the release must have its Android build in the APK.
if grep -E 'baguette: no lib.* in the app|on_load function for module|failed to load NIF' "$OUT/logcat.txt"; then
  fail "a NIF is missing from the APK or did not load"
fi

# The workflows home the app made (~/ixpipe; HOME is the release's tmp when
# Android sets none).
home=$(as_app "find /data/data/$PKG -type d -name ixpipe -not -path \"*/lib/*\" 2>/dev/null" | tr -d '\r' | head -1)
echo "workflows home: ${home:-none}"
if [[ -z $home ]]; then
  fail "the app made no workflows home"
else
  as_app "cat > $home/orders.csv" <<'CSV'
id,customer_id,amount
1,10,50
2,20,5
3,10,30
4,30,12
CSV
  as_app "cat > $home/smoke.yaml" <<YAML
nodes:
  - {id: orders, tool: input_csv, config: {path: $home/orders.csv}, position: {x: 40, y: 40}}
  - {id: sorted, tool: sort, inputs: {in: orders}, config: {by: [amount], desc: true}, position: {x: 320, y: 40}}
  - {id: to_csv, tool: output_csv, inputs: {in: sorted}, config: {path: $home/sorted.csv}, position: {x: 600, y: 40}}
  - {id: to_sqlite, tool: output_sqlite, inputs: {in: sorted}, config: {path: $home/sorted.sqlite, table: sorted}, position: {x: 600, y: 260}}
YAML
  as_app "test -s $home/smoke.yaml" || fail "could not write the workflow onto the device"

  # Relaunch, so the home screen lists the new workflow.
  adb shell am force-stop "$PKG"
  from=$(lines)
  adb shell am start -n "$PKG/.MainActivity"
  if wait_for 'baguette: bounds Open smoke.yaml [0-9]+ [0-9]+' 120 "$from"; then
    sleep 2
    tap "Open smoke.yaml"
    from=$(lines)
    wait_for 'baguette: bounds Run workflow [0-9]+ [0-9]+' 30 "$from"
    sleep 2
    tap "Run workflow"
    deadline=$((SECONDS + 60))
    until as_app "test -s $home/sorted.csv && test -s $home/sorted.sqlite" 2>/dev/null; do
      if ((SECONDS > deadline)); then break; fi
      sleep 2
    done
    sleep 2
    shot run

    # A horizontal swipe across the canvas scrolls it: the nodes' controls
    # report new bounds. (A pan locks to its first axis, so keep it level.)
    at=$(grep -Eo "baguette: bounds Select sorted [0-9]+ [0-9]+" "$OUT/logcat.txt" | tail -1 | grep -Eo '[0-9]+ [0-9]+$' || true)
    if [[ -z $at ]]; then
      fail "no bounds logged for Select sorted"
    else
      read -r x y <<<"$at"
      before=$(grep -Eo "baguette: bounds Select to_csv [0-9]+ [0-9]+" "$OUT/logcat.txt" | tail -1 || true)
      from=$(lines)
      adb shell input swipe "$x" "$((y + 60))" "$((x - 240))" "$((y + 60))" 600
      sleep 3
      after=$(tail -n +$((from + 1)) "$OUT/logcat.txt" | grep -Eo "baguette: bounds Select to_csv [0-9]+ [0-9]+" | tail -1 || true)
      echo "before swipe: ${before:-none}; after: ${after:-none}"
      if [[ -z $after || $after == "$before" ]]; then
        fail "a swipe did not scroll the canvas"
      fi
      shot scrolled
    fi
    csv=$(as_app "cat $home/sorted.csv" 2>/dev/null | tr -d '\r' || true)
    echo "sorted.csv:"
    echo "$csv"
    expected=$'id,customer_id,amount\n1,10,50\n3,10,30\n4,30,12\n2,20,5'
    [[ $csv == "$expected" ]] || fail "the workflow's CSV output is not the sorted input"
    magic=$(as_app "head -c 15 $home/sorted.sqlite" 2>/dev/null || true)
    [[ $magic == "SQLite format 3" ]] || fail "the workflow wrote no SQLite database"
  fi
fi

# Icons and classes that render on the desktop render here too.
if grep -E 'baguette: (unknown icon|unsupported class)' "$OUT/logcat.txt"; then
  fail "the host could not draw an icon or class it draws on the desktop"
fi

if adb shell pidof "$PKG" >/dev/null; then echo "app still running"; else
  fail "the app exited"
fi
grep -E 'baguette|beam|ixpipe|FATAL|AndroidRuntime' "$OUT/logcat.txt" | tail -60 || true
if ((failures > 0)); then
  echo "$failures check(s) failed"
  exit 1
fi
echo "PASS: ixpipe runs a CSV to CSV and SQLite workflow on Android"

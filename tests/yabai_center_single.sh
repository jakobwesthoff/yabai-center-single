#!/usr/bin/env bash
#
# Usage: tests/yabai_center_single.sh
#
# Runs bin/yabai_center_single against a fake yabai and checks the padding it
# leaves behind and the lines it logs. The fake keeps its state in files, so a
# test can change the windows of a space between runs, make a padding write
# hang the way a busy yabai does, or make single calls fail.
#
# Every test runs in its own subshell with errexit, so any failing step fails
# the test. The whole suite takes under a minute: the hang test holds a pass
# for 11 s on purpose, and every retry waits 1 s.

set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
script="$repo/bin/yabai_center_single"

# =========================================================
# Fake yabai
# =========================================================

# Every test gets a fresh directory holding the fake's state, the stubs on
# PATH, a HOME for the log file and the script's lock and pause files.
# getconf is stubbed because the script takes its state directory from it.
setup() {
    test_dir=$(mktemp -d)
    export FAKE_YABAI="$test_dir/yabai"
    export HOME="$test_dir/home"
    log_file="$HOME/Library/Logs/yabai_center_single.log"
    mkdir -p "$FAKE_YABAI/padding" "$test_dir/bin" "$test_dir/state" "$HOME/Library/Logs"
    : > "$log_file"

    cat > "$test_dir/bin/getconf" <<EOF
#!/usr/bin/env bash
echo "$test_dir/state/"
EOF

    cat > "$test_dir/bin/yabai" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
dir=$FAKE_YABAI
echo "$*" >> "$dir/calls"

# Takes a one-shot fault: the file is removed and its content returned.
take() {
    [ -e "$dir/$1" ] || return 1
    cat "$dir/$1"
    rm "$dir/$1"
}

global() {
    cat "$dir/global" 2>/dev/null || echo 12
}

case "$*" in
    "-m config left_padding" | "-m config right_padding" | \
    "-m config top_padding" | "-m config bottom_padding")
        global
        ;;
    "-m config --space "*)
        # An empty answer with exit 0 is what the yabai client prints when
        # the daemon closes the socket without replying. The fault names the
        # setting it hits.
        if [ "$(cat "$dir/fail-next-space-read" 2>/dev/null)" = "$5" ]; then
            rm "$dir/fail-next-space-read"
            exit 0
        fi
        cat "$dir/padding/$4.$5" 2>/dev/null || global
        ;;
    "-m query --displays")
        cat "$dir/displays.json"
        ;;
    "-m query --spaces --space "*)
        jq --argjson index "$5" '.[] | select(.index == $index)' "$dir/spaces.json"
        ;;
    "-m query --spaces")
        if [ -e "$dir/slow-next-query" ]; then
            sleep "$(take slow-next-query)"
        fi
        # "fail-queries" fails every query, "fail-next-query" the next one.
        # Its mode is "error" (exit 1, nothing on stdout) or "empty" (exit 0,
        # nothing on stdout).
        mode=$(take fail-next-query || cat "$dir/fail-queries" 2>/dev/null || true)
        case "$mode" in
            error) echo "fake yabai: query failed" >&2; exit 1 ;;
            empty) exit 0 ;;
        esac
        cat "$dir/spaces.json"
        ;;
    "-m signal --list")
        if take fail-next-signal-list > /dev/null; then
            exit 0
        fi
        cat "$dir/signals.json" 2>/dev/null \
            || echo '[{"label":"center_single_window_created","action":"yabai_center_single 2080"}]'
        ;;
    "-m space "*" --padding "*)
        # While the hang file exists, a write blocks like a relayout that
        # waits on an unresponsive application.
        if [ -e "$dir/hang" ]; then
            touch "$dir/hanging"
            while [ -e "$dir/hang" ]; do sleep 0.1; done
        fi
        if [ "$(take fail-next-write || true)" = "$3" ]; then
            echo "fake yabai: padding write failed" >&2
            exit 1
        fi
        # yabai rejects a padding with an empty or non-numeric side.
        if ! [[ "$5" =~ ^abs:[0-9]+:[0-9]+:[0-9]+:[0-9]+$ ]]; then
            echo "fake yabai: invalid padding $5" >&2
            exit 1
        fi
        IFS=: read -r _ top bottom left right <<< "$5"
        echo "$top" > "$dir/padding/$3.top_padding"
        echo "$bottom" > "$dir/padding/$3.bottom_padding"
        echo "$left" > "$dir/padding/$3.left_padding"
        echo "$right" > "$dir/padding/$3.right_padding"
        ;;
    *)
        echo "fake yabai: unexpected call: $*" >&2
        exit 1
        ;;
esac
EOF
    chmod +x "$test_dir/bin/getconf" "$test_dir/bin/yabai"
    export PATH="$test_dir/bin:$PATH"

    echo '[{"index":1,"frame":{"x":0,"y":0,"w":3360,"h":1418}}]' > "$FAKE_YABAI/displays.json"
}

# Background jobs of a test go first, so nothing writes into the directory
# while it is removed. A fake still blocked on the hang file ends on its own
# once the file is gone.
teardown() {
    local jobs
    jobs=$(jobs -p)
    if [ -n "$jobs" ]; then
        # shellcheck disable=SC2086 # one pid per word
        kill $jobs 2>/dev/null || true
    fi
    wait 2>/dev/null || true
    rm -rf "$test_dir"
}

# Space 1 on a 3360 pt display, holding the given window ids as tiles.
# 2080 pt centered on 3360 pt leaves 640 pt on each side.
set_tiles() {
    local first=$1 last=${2:-$1}
    cat > "$FAKE_YABAI/spaces.json" <<EOF
[{"index":1,"id":5,"display":1,"type":"bsp","is-native-fullscreen":false,
  "first-window":$first,"last-window":$last}]
EOF
}

side_padding() {
    local space=${1:-1}
    echo "$(yabai -m config --space "$space" left_padding):$(yabai -m config --space "$space" right_padding)"
}

wait_for_file() {
    local tries=0
    while [ ! -e "$1" ]; do
        tries=$((tries + 1))
        if [ "$tries" -gt 100 ]; then
            echo "waited 10 s for $1" >&2
            return 1
        fi
        sleep 0.1
    done
}

count_lines() {
    rg -c -- "$1" "$log_file" || true
}

# =========================================================
# Tests
# =========================================================

test_single_tile_is_centered() {
    set_tiles 100
    "$script" 2080
    [ "$(side_padding)" = "640:640" ]
}

test_second_tile_restores_global_padding() {
    set_tiles 100
    "$script" 2080
    [ "$(side_padding)" = "640:640" ]
    set_tiles 100 200
    "$script" 2080
    [ "$(side_padding)" = "12:12" ]
}

# Two displays and three spaces: a lone tile on the wide display is centered,
# a lone tile on a display narrower than <max-width> is not, and an empty
# space keeps the global padding.
test_spaces_on_several_displays() {
    cat > "$FAKE_YABAI/displays.json" <<'EOF'
[{"index":1,"frame":{"x":0,"y":0,"w":3360,"h":1418}},
 {"index":2,"frame":{"x":3360,"y":0,"w":1296,"h":2304}}]
EOF
    cat > "$FAKE_YABAI/spaces.json" <<'EOF'
[{"index":1,"id":5,"display":1,"type":"bsp","is-native-fullscreen":false,"first-window":100,"last-window":100},
 {"index":2,"id":6,"display":2,"type":"bsp","is-native-fullscreen":false,"first-window":200,"last-window":200},
 {"index":3,"id":7,"display":1,"type":"bsp","is-native-fullscreen":false,"first-window":0,"last-window":0}]
EOF
    "$script" 2080
    [ "$(side_padding 1)" = "640:640" ]
    [ "$(side_padding 2)" = "12:12" ]
    [ "$(side_padding 3)" = "12:12" ]
}

# The hang test blocks the first pass for 11 s. A second event that arrives
# meanwhile must still be applied once the hang ends. The 11 s is longer than
# a 10 s lock wait, so a waiting instance that gave up after 10 s would lose
# the second event and fail this test.
test_event_during_hanging_pass_is_not_lost() {
    set_tiles 100
    touch "$FAKE_YABAI/hang"
    "$script" 2080 2>/dev/null &
    local first_run=$!
    wait_for_file "$FAKE_YABAI/hanging"

    set_tiles 100 200
    "$script" 2080 2>/dev/null &
    local second_run=$!

    sleep 11
    rm "$FAKE_YABAI/hang"
    wait "$first_run" || true
    wait "$second_run" || true
    [ "$(side_padding)" = "12:12" ]
}

# A pass that hangs is visible in the log while it hangs, and the watchdog
# behind that line ends with the pass: the stderr capture returns only once
# every process holding the pipe has exited, so a watchdog sleep left behind
# would hold it for 30 s. An event right after the hang is still applied.
test_hanging_pass_is_logged_while_it_hangs() {
    set_tiles 100
    touch "$FAKE_YABAI/hang"
    ( sleep 4; rm "$FAKE_YABAI/hang" ) &

    local started=$SECONDS
    local stderr
    stderr=$("$script" 2080 2>&1 >/dev/null) || true
    [ $((SECONDS - started)) -lt 10 ]
    [ "$(count_lines 'a pass has been running for 3 s')" = 1 ]
    [ "$(count_lines 'a pass took [0-9]+ s')" = 1 ]
    [ "$(side_padding)" = "640:640" ]

    set_tiles 100 200
    "$script" 2080
    [ "$(side_padding)" = "12:12" ]
}

# yabai answers a query with an error or with nothing. The event that started
# the run must still end up applied.
test_failed_query_is_retried() {
    local mode
    for mode in error empty; do
        set_tiles 100
        echo "$mode" > "$FAKE_YABAI/fail-next-query"
        "$script" 2080
        [ "$(side_padding)" = "640:640" ]
        set_tiles 100 200
        "$script" 2080
        [ "$(side_padding)" = "12:12" ]
    done
}

# A padding write that fails is repeated in another pass, and the spaces after
# it are written in the same pass.
test_failed_write_is_retried() {
    cat > "$FAKE_YABAI/spaces.json" <<'EOF'
[{"index":1,"id":5,"display":1,"type":"bsp","is-native-fullscreen":false,"first-window":100,"last-window":100},
 {"index":2,"id":6,"display":1,"type":"bsp","is-native-fullscreen":false,"first-window":200,"last-window":200}]
EOF
    echo 1 > "$FAKE_YABAI/fail-next-write"
    "$script" 2080
    [ "$(side_padding 1)" = "640:640" ]
    [ "$(side_padding 2)" = "640:640" ]
    # Space 2 was written once, in the first pass.
    [ "$(rg -c -- '-m space 2 --padding' "$FAKE_YABAI/calls")" = 1 ]
}

# An empty answer to a per-space read counts as a failure, not as a padding.
# The top padding is read only for the write, so an empty one would end up in
# the padding yabai is asked to set.
test_empty_space_read_is_retried() {
    set_tiles 100
    echo top_padding > "$FAKE_YABAI/fail-next-space-read"
    "$script" 2080 2>/dev/null
    [ "$(side_padding)" = "640:640" ]
}

test_run_gives_up_after_five_failed_passes() {
    set_tiles 100
    echo error > "$FAKE_YABAI/fail-queries"
    local status=0
    "$script" 2080 2>/dev/null || status=$?
    [ "$status" -ne 0 ]
    [ "$(rg -c -- '-m query --spaces' "$FAKE_YABAI/calls")" = 5 ]
    [ "$(count_lines 'giving up after 5 failed passes')" = 1 ]
}

test_slow_pass_is_logged() {
    set_tiles 100
    echo 3.5 > "$FAKE_YABAI/slow-next-query"
    "$script" 2080
    [ "$(count_lines 'a pass took [0-9]+ s')" = 1 ]
}

# Events during a pause change nothing, and resume applies what they missed.
test_pause_holds_padding_until_resume() {
    set_tiles 100
    "$script" pause >/dev/null
    "$script" 2080
    [ "$(side_padding)" = "12:12" ]
    "$script" resume >/dev/null
    [ "$(side_padding)" = "640:640" ]
}

# pause started during a hanging pass waits for that pass, and no pass writes
# after pause returns.
test_pause_waits_for_running_pass() {
    set_tiles 100
    touch "$FAKE_YABAI/hang"
    "$script" 2080 2>/dev/null &
    wait_for_file "$FAKE_YABAI/hanging"

    "$script" pause >/dev/null &
    local pause_run=$!
    sleep 1
    kill -0 "$pause_run"

    rm "$FAKE_YABAI/hang"
    wait "$pause_run"
    [ "$(side_padding)" = "640:640" ]
    set_tiles 100 200
    "$script" 2080
    [ "$(side_padding)" = "640:640" ]
}

# "pause <space>" records the space by id, and resume puts the global padding
# back on all four sides of that space before it centers again.
test_resume_restores_paused_space() {
    set_tiles 100 200
    "$script" pause 1 >/dev/null
    yabai -m space 1 --padding abs:50:50:50:50
    "$script" resume >/dev/null
    [ "$(yabai -m config --space 1 top_padding)" = 12 ]
    [ "$(side_padding)" = "12:12" ]
}

# refresh survives one failed read of the signal list.
test_refresh_retries_signal_list() {
    set_tiles 100
    touch "$FAKE_YABAI/fail-next-signal-list"
    "$script" refresh
    [ "$(side_padding)" = "640:640" ]
}

# No centering signal registered means centering is off: refresh exits at
# once and writes nothing.
test_refresh_without_signals_is_off() {
    set_tiles 100
    echo '[]' > "$FAKE_YABAI/signals.json"
    "$script" refresh
    [ "$(side_padding)" = "12:12" ]
    ! rg -q -- '--padding' "$FAKE_YABAI/calls"
}

# =========================================================
# Runner
# =========================================================

failures=0
for test_name in $(declare -F | awk '$3 ~ /^test_/ { print $3 }'); do
    # errexit is ignored throughout a subshell that is an "if" condition, so
    # the subshell runs on its own and its status is taken afterwards.
    set +e
    (
        set -e
        setup
        trap teardown EXIT
        "$test_name"
    )
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo "ok   $test_name"
    else
        echo "FAIL $test_name"
        failures=$((failures + 1))
    fi
done

if [ "$failures" -ne 0 ]; then
    echo "$failures test(s) failed"
    exit 1
fi

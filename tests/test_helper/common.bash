# Shared setup for the bats tests: a fresh fake yabai, HOME and state
# directory per test, and small helpers to read what the script left
# behind.

# bats-support and bats-assert come from Homebrew's bats-core tap, which
# installs them below $(brew --prefix)/lib. bats searches BATS_LIB_PATH in
# order and sets it to /usr/lib/bats when the caller sets nothing, so
# Homebrew's directory goes last: libraries installed some other way and
# named in BATS_LIB_PATH win.
BATS_LIB_PATH="$BATS_LIB_PATH:${HOMEBREW_PREFIX:-$(brew --prefix)}/lib"
bats_load_library bats-support
bats_load_library bats-assert

# shellcheck disable=SC2034 # read by the .bats files that load this one
script="$BATS_TEST_DIRNAME/../bin/yabai_center_single"

# Everything a test touches lives in its own BATS_TEST_TMPDIR, which bats
# removes afterwards. getconf is stubbed because the script takes its state
# directory from it, and HOME because the log file lives below it.
setup() {
    export FAKE_YABAI="$BATS_TEST_TMPDIR/yabai"
    export HOME="$BATS_TEST_TMPDIR/home"
    log_file="$HOME/Library/Logs/yabai_center_single.log"
    mkdir -p "$FAKE_YABAI/padding" "$BATS_TEST_TMPDIR/bin" "$BATS_TEST_TMPDIR/state" \
        "$HOME/Library/Logs"
    : > "$log_file"

    ln -s "$BATS_TEST_DIRNAME/test_helper/fake-yabai" "$BATS_TEST_TMPDIR/bin/yabai"
    printf '#!/usr/bin/env bash\necho "%s/state/"\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/bin/getconf"
    chmod +x "$BATS_TEST_TMPDIR/bin/getconf"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"

    echo '[{"index":1,"frame":{"x":0,"y":0,"w":3360,"h":1418}}]' > "$FAKE_YABAI/displays.json"
}

# A test's background runs are stopped before bats removes the directory
# they write into. A fake still blocked on the hang file ends on its own
# once the file is gone.
teardown() {
    local jobs
    jobs=$(jobs -p)
    if [ -n "$jobs" ]; then
        # shellcheck disable=SC2086 # one pid per word
        kill $jobs 2>/dev/null || true
    fi
    wait 2>/dev/null || true
}

# Space 1 on the 3360 pt display, holding the given window ids as tiles.
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

# grep -c prints 0 and fails when nothing matches; the count is what the
# tests compare.
count_log_lines() {
    grep -cE -- "$1" "$log_file" || true
}

count_calls() {
    grep -cE -- "$1" "$FAKE_YABAI/calls" || true
}

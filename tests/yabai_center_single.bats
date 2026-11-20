#!/usr/bin/env bats
#
# Runs bin/yabai_center_single against a fake yabai (test_helper/fake-yabai)
# and checks the padding it leaves behind and the lines it logs.
#
# The suite takes under a minute: one test holds a pass for 11 s on
# purpose, and every retry of the script waits 1 s.
#
# Runs that go to the background close fd 3 (`3>&-`). bats waits until
# every process holding that descriptor has exited, so a background run
# would otherwise block the test until it ends.

# shellcheck disable=SC2154 # script and log_file come from test_helper/common
load test_helper/common

@test "a single tile is centered" {
    set_tiles 100
    run "$script" 2080
    assert_success
    assert_equal "$(side_padding)" "640:640"
}

@test "a second tile restores the global padding" {
    set_tiles 100
    run "$script" 2080
    assert_equal "$(side_padding)" "640:640"

    set_tiles 100 200
    run "$script" 2080
    assert_success
    assert_equal "$(side_padding)" "12:12"
}

# A lone tile on the wide display is centered, a lone tile on a display
# narrower than <max-width> is not, and an empty space keeps the global
# padding.
@test "spaces on several displays" {
    cat > "$FAKE_YABAI/displays.json" <<'EOF'
[{"index":1,"frame":{"x":0,"y":0,"w":3360,"h":1418}},
 {"index":2,"frame":{"x":3360,"y":0,"w":1296,"h":2304}}]
EOF
    cat > "$FAKE_YABAI/spaces.json" <<'EOF'
[{"index":1,"id":5,"display":1,"type":"bsp","is-native-fullscreen":false,"first-window":100,"last-window":100},
 {"index":2,"id":6,"display":2,"type":"bsp","is-native-fullscreen":false,"first-window":200,"last-window":200},
 {"index":3,"id":7,"display":1,"type":"bsp","is-native-fullscreen":false,"first-window":0,"last-window":0}]
EOF
    run "$script" 2080
    assert_success
    assert_equal "$(side_padding 1)" "640:640"
    assert_equal "$(side_padding 2)" "12:12"
    assert_equal "$(side_padding 3)" "12:12"
}

# The first pass hangs for 11 s, and a second event arrives meanwhile. It
# must still be applied once the hang ends. The 11 s is longer than a 10 s
# lock wait, so a waiting instance that gave up after 10 s would lose the
# second event and fail this test.
@test "an event during a hanging pass is not lost" {
    set_tiles 100
    touch "$FAKE_YABAI/hang"
    "$script" 2080 3>&- 2>/dev/null &
    local first_run=$!
    wait_for_file "$FAKE_YABAI/hanging"

    set_tiles 100 200
    "$script" 2080 3>&- 2>/dev/null &
    local second_run=$!

    sleep 11
    rm "$FAKE_YABAI/hang"
    wait "$first_run" || true
    wait "$second_run" || true
    assert_equal "$(side_padding)" "12:12"
}

# A pass that hangs shows in the log while it hangs, and the watchdog
# behind that line ends with the pass: the stderr capture returns only once
# every process holding the pipe has exited, so a watchdog sleep left behind
# would hold it for 30 s. An event right after the hang is still applied.
@test "a hanging pass is logged while it hangs" {
    set_tiles 100
    touch "$FAKE_YABAI/hang"
    ( sleep 4; rm "$FAKE_YABAI/hang" ) 3>&- &

    local started=$SECONDS
    local stderr
    stderr=$("$script" 2080 3>&- 2>&1 >/dev/null) || true
    assert [ $((SECONDS - started)) -lt 10 ]
    assert_equal "$(count_log_lines 'a pass has been running for 3 s')" 1
    assert_equal "$(count_log_lines 'a pass took [0-9]+ s')" 1
    assert_equal "$(side_padding)" "640:640"

    set_tiles 100 200
    run "$script" 2080
    assert_success
    assert_equal "$(side_padding)" "12:12"
}

# yabai answers a query with an error or with nothing. The event that
# started the run must still end up applied.
@test "a failed query is retried" {
    local mode
    for mode in error empty; do
        set_tiles 100
        echo "$mode" > "$FAKE_YABAI/fail-next-query"
        run "$script" 2080
        assert_success
        assert_equal "$(side_padding)" "640:640"

        set_tiles 100 200
        run "$script" 2080
        assert_equal "$(side_padding)" "12:12"
    done
}

# A padding write that fails is repeated in another pass, and the spaces
# after it are written in the same pass.
@test "a failed write is retried" {
    cat > "$FAKE_YABAI/spaces.json" <<'EOF'
[{"index":1,"id":5,"display":1,"type":"bsp","is-native-fullscreen":false,"first-window":100,"last-window":100},
 {"index":2,"id":6,"display":1,"type":"bsp","is-native-fullscreen":false,"first-window":200,"last-window":200}]
EOF
    echo 1 > "$FAKE_YABAI/fail-next-write"
    run "$script" 2080
    assert_success
    assert_equal "$(side_padding 1)" "640:640"
    assert_equal "$(side_padding 2)" "640:640"
    # Space 2 was written once, in the first pass.
    assert_equal "$(count_calls '^-m space 2 --padding ')" 1
}

# An empty answer to a per-space read counts as a failure, not as a padding.
# The top padding is read only for the write, so an empty one would end up
# in the padding yabai is asked to set.
@test "an empty per-space read is retried" {
    set_tiles 100
    echo top_padding > "$FAKE_YABAI/fail-next-space-read"
    run "$script" 2080
    assert_success
    assert_equal "$(side_padding)" "640:640"
}

@test "a run gives up after five failed passes" {
    set_tiles 100
    echo error > "$FAKE_YABAI/fail-queries"
    run "$script" 2080
    assert_failure
    assert_equal "$(count_calls '^-m query --spaces$')" 5
    assert_equal "$(count_log_lines 'giving up after 5 failed passes')" 1
}

@test "a slow pass is logged" {
    set_tiles 100
    echo 3.5 > "$FAKE_YABAI/slow-next-query"
    run "$script" 2080
    assert_success
    assert_equal "$(count_log_lines 'a pass took [0-9]+ s')" 1
}

# Events during a pause change nothing, and resume applies what they missed.
@test "pause holds the padding until resume" {
    set_tiles 100
    run "$script" pause
    assert_success
    run "$script" 2080
    assert_equal "$(side_padding)" "12:12"

    run "$script" resume
    assert_success
    assert_equal "$(side_padding)" "640:640"
}

# pause started during a hanging pass waits for that pass, and no pass
# writes after pause returns.
@test "pause waits for a running pass" {
    set_tiles 100
    touch "$FAKE_YABAI/hang"
    "$script" 2080 3>&- 2>/dev/null &
    wait_for_file "$FAKE_YABAI/hanging"

    "$script" pause 3>&- >/dev/null &
    local pause_run=$!
    sleep 1
    assert kill -0 "$pause_run"

    rm "$FAKE_YABAI/hang"
    wait "$pause_run"
    assert_equal "$(side_padding)" "640:640"

    set_tiles 100 200
    run "$script" 2080
    assert_equal "$(side_padding)" "640:640"
}

# "pause <space>" records the space by id, and resume puts the global
# padding back on all four sides of that space before it centers again.
@test "resume restores the paused space" {
    set_tiles 100 200
    run "$script" pause 1
    assert_success
    yabai -m space 1 --padding abs:50:50:50:50

    run "$script" resume
    assert_success
    assert_equal "$(yabai -m config --space 1 top_padding)" 12
    assert_equal "$(side_padding)" "12:12"
}

@test "refresh survives one failed read of the signal list" {
    set_tiles 100
    touch "$FAKE_YABAI/fail-next-signal-list"
    run "$script" refresh
    assert_success
    assert_equal "$(side_padding)" "640:640"
}

# No centering signal registered means centering is off: refresh exits at
# once and writes nothing.
@test "refresh without centering signals changes nothing" {
    set_tiles 100
    echo '[]' > "$FAKE_YABAI/signals.json"
    run "$script" refresh
    assert_success
    assert_equal "$(side_padding)" "12:12"
    assert_equal "$(count_calls ' --padding ')" 0
}

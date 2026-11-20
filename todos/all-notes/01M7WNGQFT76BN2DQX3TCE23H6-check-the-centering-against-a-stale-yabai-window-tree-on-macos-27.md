---
title: "Check the centering against a stale yabai window tree on macOS 27"
kind: investigation
component: script
horizon: someday
origin: review
tags: [yabai]
---
# Check the centering against a stale yabai window tree on macOS 27

`bin/yabai_center_single` counts the tiles of a space from yabai's own
window tree (`first-window` and `last-window` of `yabai -m query
--spaces`). yabai v7.1.25 does not support macOS 27, and on 27 it may keep
windows in that tree that are gone, or miss windows that are there. The
script then sets the padding yabai's tree asks for, which is wrong on
screen. Whether this happens on 27 has not been observed.

## Background

Found in the 2026-11-20 adversarial review of the script. v7.1.25 detects
the OS by exact major version, so on 27 it skips what it reserves for
macOS 15 and 26, among it the subscription to notification 804
(window destroyed) for every window: "Subscribe to all windows because
of window_destroyed" in `update_window_notifications`. Read in the
v7.1.25 source, not reproduced.

A missed destroy leaves a stale tile, so a lone window keeps the global
padding. The opposite case, two windows on screen with the single-window
padding, would need a missed creation, and no source evidence for that
was found. The case that triggered the review (two Zen browser windows
with single-window padding) was correct again by the time it was
inspected, so it is open which of the two causes it had: a lost event,
which the script handles since that review, or yabai's tree.

## How to check

When a padding looks wrong, compare these with the windows on screen
before changing the script:

    yabai -m query --spaces --space <n> | jq '{"first-window","last-window",windows}'
    yabai -m query --windows --space <n> | jq '[.[] | {id, app, "is-floating", "is-visible"}]'

If yabai lists one tile while two windows are tiled on screen, or the
other way round, the cause is yabai's tree and not the script. Record
the result here.

## Revisit when

A space shows the wrong padding again, or yabai ships a release with
upstream commit `b2dc8b4` ("Tahoe fixes should also apply to Golden
Gate"), after which this todo can be closed once the check passes.

## Relations

- Relates to: dotfiles todo 01M7J4X3H0ERBVAJYBJ81PW2ZW (Run a yabai build that supports macOS 27)

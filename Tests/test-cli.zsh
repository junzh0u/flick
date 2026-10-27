#!/usr/bin/env zsh
# Tests the command line's argument handling. Anything past it acts on the
# frontmost window, which needs Accessibility and a real session, so every case
# here must fail before that point.
#
#   Tests/test-cli.zsh

emulate -L zsh

[[ $OSTYPE == darwin* ]] || { print "not macOS"; exit 77 }
(( $+commands[swift] )) || { print "no swift"; exit 77 }

cd ${0:A:h:h}
local failures=0

assert_eq() {
    local label=$1 want=$2 got=$3
    if [[ $got == $want ]]; then
        print "  ok: $label"
    else
        print "  FAIL: $label\n    want: $want\n    got:  $got"
        (( ++failures ))
    fi
}

swift build --product Flick &>/dev/null || { print "build failed"; exit 1 }
local bin=$(swift build --show-bin-path)/Flick

local usage="flick: usage: flick
       flick fill [--dry-run] [--duration SECONDS]
       flick tile [--dry-run] [--duration SECONDS] left|right|top|bottom
       flick pair [--dry-run] [--duration SECONDS] left|right
       flick display [--dry-run] previous|next
       flick minimize [--dry-run]
       flick probe X Y
       flick launch-at-login [on|off]"

print "commands:"
local out
out=$($bin maximize 2>&1)
assert_eq "unknown command exits 1" 1 $?
assert_eq "unknown command prints usage" $usage "$out"
out=$($bin tile --dry-run 2>&1)
assert_eq "tile without a side prints usage" $usage "$out"
out=$($bin tile --dry-run middle 2>&1)
assert_eq "tile with an unknown side names it" "flick: unknown argument middle
${usage#flick: }" "$out"
$bin tile left right &>/dev/null
assert_eq "tile takes one side" 1 $?
out=$($bin pair --dry-run top 2>&1)
assert_eq "pair takes only left or right" "flick: unknown argument top
${usage#flick: }" "$out"
out=$($bin display 2>&1)
assert_eq "display without a direction prints usage" $usage "$out"
$bin display sideways &>/dev/null
assert_eq "display with an unknown direction exits 1" 1 $?
$bin probe 1 &>/dev/null
assert_eq "probe needs X and Y" 1 $?
out=$($bin launch-at-login maybe 2>&1)
assert_eq "launch-at-login takes on or off" $usage "$out"
$bin launch-at-login on off &>/dev/null
assert_eq "launch-at-login takes one setting" 1 $?

print "options:"
out=$($bin fill --bogus 2>&1)
assert_eq "unknown option names it" "flick: unknown argument --bogus
${usage#flick: }" "$out"
$bin display next --duration 1 &>/dev/null
assert_eq "display rejects --duration" 1 $?
$bin minimize --duration 1 &>/dev/null
assert_eq "minimize rejects --duration" 1 $?
out=$($bin fill --duration 2>&1)
assert_eq "missing duration explains" "flick: --duration needs a number of seconds" "$out"
$bin tile --duration soon left &>/dev/null
assert_eq "non-numeric duration exits 1" 1 $?
$bin fill --duration -1 &>/dev/null
assert_eq "negative duration exits 1" 1 $?

(( failures == 0 ))

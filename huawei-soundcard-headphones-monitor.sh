#!/bin/bash
set -e

# [COMMENTS]
#
# Looks like there is some weird hardware design, because from my prospective, the interesting widgets are:
# 0x01 - Audio Function Group
# 0x10 - Headphones DAC (really both devices connected here)
# 0x11 - Speaker DAC
# 0x16 - Headphones Jack
# 0x17 - Internal Speaker
#
# And:
#
# widgets 0x16 and 0x17 simply should be connected to different DACs 0x10 and 0x11, but Internal Speaker 0x17 ignores the connection select command and use the value from Headphones Jack 0x16.
# Headphone Jack 0x16 is controlled with some weird stuff so it should be enabled with GPIO commands for Audio Group 0x01.
# Internal Speaker 0x17 is coupled with Headphone Jack 0x16 so it should be explicitly disabled with EAPD/BTL Enable command.
#

# ensures script can run only once at a time
pidof -o %PPID -x "$0" >/dev/null && {
    echo "Script $0 already running"
    exit 1
}

function move_output() {
    hda-verb "$hw_dev" 0x16 0x701 "$1" >/dev/null 2>&1
}

function move_output_to_speaker() {
    move_output 0x0001
}

function move_output_to_headphones() {
    move_output 0x0000
}

function switch_to_speaker() {
    move_output_to_speaker

    # enable speaker
    hda-verb "$hw_dev" 0x17 0x70C 0x0002 >/dev/null 2>&1

    # disable headphones
    hda-verb "$hw_dev" 0x1 0x715 0x2 >/dev/null 2>&1

    # mute headphones
    amixer -c"${card_index}" set Headphone mute >/dev/null 2>&1 || true
}

function switch_to_headphones() {
    move_output_to_headphones

    # disable speaker
    hda-verb "$hw_dev" 0x17 0x70C 0x0000 >/dev/null 2>&1

    # pin output mode
    hda-verb "$hw_dev" 0x1 0x717 0x2 >/dev/null 2>&1
    # pin enable
    hda-verb "$hw_dev" 0x1 0x716 0x2 >/dev/null 2>&1
    # clear pin value
    hda-verb "$hw_dev" 0x1 0x715 0x0 >/dev/null 2>&1
    
    # unmute headphones
    amixer -c"${card_index}" set Headphone unmute >/dev/null 2>&1 || true
}

function get_sound_card_index() {
    # searching card id via awk
    awk '/sof-hda-dsp|sofhdadsp/ {print $1; exit}' /proc/asound/cards || true
}

function jack_plugged() {
    # Reading headphone pin state 0x16 (Headphones Jack)
    local out
    out="$(hda-verb "$hw_dev" 0x16 0xF09 0 2>/dev/null)" || return 1

    # Get latest hex-value like 0x8XXXXXXX
    local val
    val="$(printf '%s\n' "$out" | grep -Eo '0x[0-9a-fA-F]+' | tail -n1)"

    # If not hex = no jack
    [ -n "$val" ] || return 1

    # Check high-order bit presence detect
    # shell: "(( val & 0x80000000 ))" doesnt work with string
    local num=$(( val ))
    if (( num & 0x80000000 )); then
    return 0   # Jack in
    else
    return 1   # Jack out
    fi
}

sleep 2 # allows audio system to initialise first

card_index="$(get_sound_card_index)"
if [ -z "$card_index" ]; then
    echo "sof-hda-dsp card is not found in /proc/asound/cards"
    exit 1
fi

hw_dev="/dev/snd/hwC${card_index}D0"

if [ ! -e "$hw_dev" ]; then
    echo "Device node $hw_dev not found"
    exit 1
fi

old_status=0

while true; do
    # Jack plugged = sound to headphones, not plugged = speaker
    if jack_plugged; then
    status=1
    move_output_to_headphones
    else
    status=2
    move_output_to_speaker
    fi

    if [ "$status" -ne "$old_status" ]; then
    case "$status" in
        1)
        echo "Headphones connected"
        switch_to_headphones
        ;;
        2)
        echo "Headphones disconnected"
        switch_to_speaker
        ;;
    esac
    old_status=$status
    fi

    sleep .3
done
#!/bin/bash

set -o emacs

# make CTRL-C arrive as a normal character to readline (so our binding can handle it)
# we re-apply this before every read because readline restores terminal modes after each input
apply_tty_settings() {
    stty -echoctl -isig intr undef
}

apply_tty_settings

# never die on SIGINT (belt + suspenders)
trap '' SIGINT

# restore terminal when on finally exit
trap 'stty sane; stty "$OLD_STTY" 2>/dev/null || true' EXIT

OLD_STTY=$(stty -g)

bind '"\C-c": kill-whole-line'

while true; do
    apply_tty_settings
    read -r -e -p "User: " user_message_content
    status=$?

    if [ "$status" -ne 0 ]; then
        exit 0
    fi

    if [ -z "$user_message_content" ]; then
        continue
    fi

    echo "Assistant: $user_message_content"
done

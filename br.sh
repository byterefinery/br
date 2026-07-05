#!/bin/bash

# Enable standard readline editing mode
set -o emacs

# READLINE BINDINGS:
# Ctrl+K then Ctrl+J: Insert literal newline
bind '"\C-k\C-j": "\C-v\C-j"'
# Ctrl+J: Accept input (Send)
bind '"\C-j": accept-line'
# Alt+Enter: Insert literal newline (ESC + Return/LineFeed)
bind '"\e\r": "\C-v\C-j"'
bind '"\e\n": "\C-v\C-j"'
# Enter: Accept input (Return, Ctrl+M, or LineFeed)
bind '"\r": accept-line'
bind '"\C-m": accept-line'
bind '"\n": accept-line'

# MAIN LOOP
while true; do
    # -p: prompt
    # -d $'\r': delimiter to capture embedded newlines
    # -e: enable readline
    # -r: raw input
    read -p "User: " -d $'\r' -e -r message

    # Break loop on EOF (Ctrl+D) to prevent infinite empty loops
    [[ -z "$message" ]] && break

    echo "Assistant: $message"
done

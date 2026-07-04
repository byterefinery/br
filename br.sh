#!/usr/bin/env bash

# trap for CTRL-C (SIGINT) to clear partial input and re-prompt cleanly
trap '
    user_message_content=""
    echo " [IGNORE THIS MESSAGE]"
    echo -n "User: "
    # Continue to next read
' SIGINT


while true; do
    echo -n "User: "

    # read user input
    if read -r user_message_content; then
        # read succeeds, ENTER pressed
        echo "Assistant: $user_message_content"
    else
        # read failed, likely CTRL-D (EOF)
        break
    fi
done

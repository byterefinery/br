#!/usr/bin/env bash

# Enable standard readline editing mode
set -o emacs

# READLINE BINDINGS
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

# Set default values first
export BASE_URL="${BASE_URL:-http://localhost:8080/v1}" # OAI compatible API
export API_KEY="${API_KEY:-}"                           # sk-...
export MODEL_NAME="${MODEL_NAME:-}"                     # ORG/MODEL
export MODEL_INPUT="${MODEL_INPUT:-text}"               # text,image
export MODEL_STREAM="${MODEL_STREAM:-true}"             # true or false

# Global conversation history as array of role-content pairs
CONVERSATION=()

read_env_vars() {
    local config_file=""

    # Determine which config file to use
    if [[ -f ".env" ]]; then
        config_file=".env"
    elif [[ -f "$HOME/.config/br/config" ]]; then
        config_file="$HOME/.config/br/config"
    else
        echo "Warning: default values are used instead of config files." >&2
        echo "" >&2
    fi

    # Load from file if a valid path was found
    if [[ -n "$config_file" ]]; then
        # 'set -a' automatically exports variables assigned in the sourced file
        set -a
        # shellcheck disable=SC1090
        source "$config_file"
        set +a
    fi

    # Mask the API_KEY based on its length so it doesn't leak
    local masked_api_key
    if [[ -n "$API_KEY" ]]; then
        masked_api_key="${API_KEY//?/*}" # Replaces every character with an asterisk
    else
        masked_api_key="(empty)"
    fi

    local model_name_val="${MODEL_NAME:-(empty)}"
    local model_input_val="${MODEL_INPUT:-text}"

    # Parse MODEL_STREAM as boolean (case-insensitive, supports true/false, yes/no, 1/0)
    local model_stream_val="${MODEL_STREAM:-true}"
    case "$model_stream_val" in
        [tT][rR][uU][eE]|[yY][eE][sS]|[yY]|1) model_stream_val="true" ;;
        *) model_stream_val="false" ;;
    esac
    export MODEL_STREAM="$model_stream_val"

    # Print the active configuration
    echo "Configuration:"
    echo "  BASE_URL     : $BASE_URL"
    echo "  API_KEY      : $masked_api_key"
    echo "  MODEL_NAME   : $model_name_val"
    echo "  MODEL_INPUT  : $model_input_val"
    echo "  MODEL_STREAM : $model_stream_val"
}

oai_make_request() {
    local user_message="$1"

    # Add user message to conversation
    CONVERSATION+=("user" "$user_message")

    # Build messages array using jq
    local messages_json="[]"
    for ((i=0; i<${#CONVERSATION[@]}; i+=2)); do
        local role="${CONVERSATION[i]}"
        local content="${CONVERSATION[i+1]}"
        messages_json=$(echo "$messages_json" | jq --arg role "$role" --arg content "$content" '. + [{"role": $role, "content": $content}]')
    done

    # Build request body
    local request_body
    request_body=$(jq -n \
        --arg model "$MODEL_NAME" \
        --argjson messages "$messages_json" \
        --argjson stream "$MODEL_STREAM" \
        '{model: $model, messages: $messages, stream: $stream}')

    local response_content=""

    # Build curl headers
    local curl_args=()
    curl_args+=("-H" "Content-Type: application/json")
    if [[ -n "$API_KEY" ]]; then
        curl_args+=("-H" "Authorization: Bearer $API_KEY")
    fi

    if [[ "$MODEL_STREAM" == "true" ]]; then
        # Streaming mode
        while IFS= read -r line; do
            # Skip empty lines
            [[ -z "$line" ]] && continue

            # Check for [DONE]
            [[ "$line" == "data: [DONE]" ]] && break

            # Extract data after "data: "
            if [[ "$line" =~ ^data:\ (.+)$ ]]; then
                local json_data="${BASH_REMATCH[1]}"

                # Extract content from delta
                local content
                content=$(echo "$json_data" | jq -r '.choices[0].delta.content // empty')
                if [[ -n "$content" ]]; then
                    printf "%s" "$content"
                    response_content+="$content"
                fi
            fi
        done < <(curl -s -N "$BASE_URL/chat/completions" "${curl_args[@]}" -d "$request_body")

        echo  # Final newline after streaming
    else
        # Non-streaming mode
        local response
        response=$(curl -s "$BASE_URL/chat/completions" "${curl_args[@]}" -d "$request_body")

        response_content=$(echo "$response" | jq -r '.choices[0].message.content')
        echo "$response_content"
    fi

    # Add assistant response to conversation
    CONVERSATION+=("assistant" "$response_content")
}

main() {
    # Initialize the environment before entering the loop
    read_env_vars

    # Main loop
    while true; do
        echo

        # -p: prompt
        # -d $'\r': delimiter to capture embedded newlines
        # -e: enable readline
        # -r: raw input
        read -p "User: " -d $'\r' -e -r message

        # Break loop on EOF (Ctrl+D) to prevent infinite empty loops
        [[ -z "$message" ]] && break

        echo
        echo -n "Assistant: "
        oai_make_request "$message"
    done
}

main
exit 0

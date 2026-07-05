#!/usr/bin/env bash

# Flag parsing
USE_COLOR=true
SHOW_HELP=false

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            SHOW_HELP=true
            ;;
        --no-color)
            USE_COLOR=false
            ;;
        --color)
            USE_COLOR=true
            ;;
    esac
done

if [[ "$SHOW_HELP" == "true" ]]; then
    cat <<EOF
Usage: br.sh [OPTIONS]

A Bash-based interactive AI agent with tool-calling capabilities.

Options:
  -h, --help       Show this help message and exit
      --color      Enable colored output (default)
      --no-color   Disable colored output

Environment Variables:
  BR_BASE_URL      Base URL of the OpenAI-compatible API (default: http://localhost:8080/v1)
  BR_API_KEY       API key for authentication
  BR_MODEL_NAME    Model name to use
  BR_MODEL_INPUT   Model input type (default: text)
  BR_MODEL_STREAM  Enable streaming (default: true)
  BR_TIMEOUT       Request timeout in seconds (default: 60)
  BR_RETRIES       Maximum number of retries on failure (default: 100)
EOF
    exit 0
fi

# Color setup
if [[ "$USE_COLOR" == "true" ]]; then
    COLOR_DIM=$'\033[90m'
    COLOR_RESET=$'\033[0m'
    JQ_COLOR_FLAG="-C"
else
    COLOR_DIM=""
    COLOR_RESET=""
    JQ_COLOR_FLAG=""
fi

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
export BR_BASE_URL="${BR_BASE_URL:-http://localhost:8080/v1}" # OAI compatible API
export BR_API_KEY="${BR_API_KEY:-}"                           # sk-...
export BR_MODEL_NAME="${BR_MODEL_NAME:-}"                     # ORG/MODEL
export BR_MODEL_INPUT="${BR_MODEL_INPUT:-text}"               # text,image
export BR_MODEL_STREAM="${BR_MODEL_STREAM:-true}"             # true or false
export BR_TIMEOUT="${BR_TIMEOUT:-60}"                         # Timeout in seconds
export BR_RETRIES="${BR_RETRIES:-100}"                        # Max retries

# Global conversation history as array of JSON strings
CONVERSATION=()

# Global session headers for smart HTTP routing
CONVERSATION_ID=""
SESSION_AFFINITY=""

# Global state for retry logic
GLOBAL_RETRY_COUNT=1
GLOBAL_RETRY_DELAY=2

# Print configuration and session headers
print_config_and_headers() {
    local masked_api_key
    if [[ -n "$BR_API_KEY" ]]; then
        masked_api_key="${BR_API_KEY//?/*}"
    else
        masked_api_key="(empty)"
    fi

    local model_name_val="${BR_MODEL_NAME:-(empty)}"
    local model_input_val="${BR_MODEL_INPUT:-text}"
    local model_stream_val="${BR_MODEL_STREAM:-true}"
    local timeout_val="${BR_TIMEOUT:-60}"
    local retries_val="${BR_RETRIES:-100}"

    echo "Configuration:"
    echo "  BR_BASE_URL     : $BR_BASE_URL"
    echo "  BR_API_KEY      : $masked_api_key"
    echo "  BR_MODEL_NAME   : $model_name_val"
    echo "  BR_MODEL_INPUT  : $model_input_val"
    echo "  BR_MODEL_STREAM : $model_stream_val"
    echo "  BR_TIMEOUT      : $timeout_val"
    echo "  BR_RETRIES      : $retries_val"
    echo "Headers:"
    echo "  X-Conversation-Id  : $CONVERSATION_ID"
    echo "  X-Session-Affinity : $SESSION_AFFINITY"
}

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

    # Parse BR_MODEL_STREAM as boolean (case-insensitive, supports true/false, yes/no, 1/0)
    local model_stream_val="${BR_MODEL_STREAM:-true}"
    case "$model_stream_val" in
        [tT][rR][uU][eE]|[yY][eE][sS]|[yY]|1) model_stream_val="true" ;;
        *) model_stream_val="false" ;;
    esac
    export BR_MODEL_STREAM="$model_stream_val"

    # Validate timeout and retries as integers
    if ! [[ "$BR_TIMEOUT" =~ ^[0-9]+$ ]]; then
        export BR_TIMEOUT=60
    fi
    if ! [[ "$BR_RETRIES" =~ ^[0-9]+$ ]]; then
        export BR_RETRIES=100
    fi

    # Print the active configuration and headers
    print_config_and_headers
}

get_tools_json() {
    cat <<'EOF'
[
  {
    "type": "function",
    "function": {
      "name": "read_file",
      "description": "Read the contents of a file. Optionally specify a 1-based line range. If append_loc is true, each line is prefixed with its line number (e.g. \"1→ ...\").",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "Path to the file"},
          "start_line": {"type": "integer", "description": "First line to read, 1-based (default: 1)"},
          "end_line": {"type": "integer", "description": "Last line to read, 1-based inclusive (default: end of file)"},
          "append_loc": {"type": "boolean", "description": "Prefix each line with its line number"}
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "write_file",
      "description": "Write content to a file, creating it (including parent directories) if it does not exist. May use with edit_file for more complex edits.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "Path of the file to write"},
          "content": {"type": "string", "description": "Content to write"}
        },
        "required": ["path", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "edit_file",
      "description": "Edit a file by applying a list of line-based changes. Each change targets a 1-based inclusive line range and has a mode: \"replace\" (replace lines with content), \"delete\" (remove lines, content must be empty string), \"append\" (insert content after line_end). Set line_start to -1 to target the end of file (line_end is ignored in that case). Changes must not overlap. They are applied in reverse line order automatically.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": {"type": "string", "description": "Path to the file to edit"},
          "changes": {
            "type": "array",
            "description": "List of changes to apply",
            "items": {
              "type": "object",
              "properties": {
                "mode": {"type": "string", "description": "\"replace\", \"delete\", or \"append\""},
                "line_start": {"type": "integer", "description": "First line of the range (1-based); use -1 for end of file"},
                "line_end": {"type": "integer", "description": "Last line of the range (1-based, inclusive); ignored when line_start is -1"},
                "content": {"type": "string", "description": "Content to insert; must be empty string for delete mode"}
              },
              "required": ["mode", "line_start", "line_end", "content"]
            }
          }
        },
        "required": ["path", "changes"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "exec_shell_command",
      "description": "Execute a shell command and return its output (stdout and stderr combined).",
      "parameters": {
        "type": "object",
        "properties": {
          "command": {"type": "string", "description": "Shell command to execute"},
          "timeout": {"type": "integer", "description": "Timeout in seconds (default 10, max 60)"},
          "max_output_size": {"type": "integer", "description": "Maximum output size in bytes (default 16384)"}
        },
        "required": ["command"]
      }
    }
  }
]
EOF
}

read_file() {
    local args_json="$1"

    local path start_line end_line append_loc
    path=$(echo "$args_json" | jq -r '.path // empty')
    if [[ -z "$path" ]]; then
        echo "Error: 'path' is required for read_file"
        return 1
    fi
    start_line=$(echo "$args_json" | jq -r '.start_line // 1')
    end_line=$(echo "$args_json" | jq -r '.end_line // empty')
    append_loc=$(echo "$args_json" | jq -r '.append_loc // false')

    if [[ ! -f "$path" ]]; then
        echo "Error: File not found: $path"
        return 1
    fi

    local total_lines
    total_lines=$(wc -l < "$path")
    if [[ -s "$path" ]] && [[ "$(tail -c 1 "$path" | wc -l)" -eq 0 ]]; then
        total_lines=$((total_lines + 1))
    fi

    if [[ -z "$end_line" ]] || [[ "$end_line" -gt "$total_lines" ]]; then
        end_line=$total_lines
    fi

    if [[ "$start_line" -lt 1 ]]; then
        start_line=1
    fi

    if [[ "$start_line" -gt "$end_line" ]]; then
        echo ""
        return 0
    fi

    local content
    content=$(sed -n "${start_line},${end_line}p" "$path")

    if [[ "$append_loc" == "true" ]]; then
        local i=$start_line
        if [[ -n "$content" ]]; then
            while IFS= read -r line; do
                echo "${i}→ ${line}"
                ((i++))
            done <<< "$content"
        fi
    else
        echo "$content"
    fi
}

write_file() {
    local args_json="$1"

    local path content
    path=$(echo "$args_json" | jq -r '.path // empty')
    if [[ -z "$path" ]]; then
        echo "Error: 'path' is required for write_file"
        return 1
    fi
    content=$(echo "$args_json" | jq -r '.content // empty')

    local dir
    dir=$(dirname "$path")
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir" || { echo "Error: Failed to create directory $dir"; return 1; }
    fi

    printf "%s" "$content" > "$path" || { echo "Error: Failed to write to $path"; return 1; }
    echo "Successfully wrote to $path"
}

edit_file() {
    local args_json="$1"

    local path changes
    path=$(echo "$args_json" | jq -r '.path // empty')
    if [[ -z "$path" ]]; then
        echo "Error: 'path' is required for edit_file"
        return 1
    fi
    changes=$(echo "$args_json" | jq -c '.changes // empty')

    if [[ ! -f "$path" ]]; then
        echo "Error: File not found: $path"
        return 1
    fi

    mapfile -t lines < "$path"

    local num_changes
    num_changes=$(echo "$changes" | jq 'length')

    # Sort changes by line_start descending to apply from bottom to top
    local sorted_changes
    sorted_changes=$(echo "$changes" | jq -c 'sort_by(-.line_start)')

    for ((c=0; c<num_changes; c++)); do
        local mode line_start line_end content
        mode=$(echo "$sorted_changes" | jq -r ".[$c].mode")
        line_start=$(echo "$sorted_changes" | jq -r ".[$c].line_start")
        line_end=$(echo "$sorted_changes" | jq -r ".[$c].line_end")
        content=$(echo "$sorted_changes" | jq -r ".[$c].content")

        if [[ "$line_start" -eq -1 ]]; then
            if [[ "$mode" == "append" ]]; then
                local -a new_lines
                mapfile -t new_lines <<< "$content"
                lines+=("${new_lines[@]}")
            fi
            continue
        fi

        local idx_start=$((line_start - 1))
        local idx_end=$((line_end - 1))
        local total_lines=${#lines[@]}

        if [[ "$idx_start" -lt 0 ]]; then idx_start=0; fi
        if [[ "$idx_end" -ge "$total_lines" ]]; then idx_end=$((total_lines - 1)); fi

        case "$mode" in
            "replace")
                local -a new_lines
                mapfile -t new_lines <<< "$content"
                local -a temp=("${lines[@]:0:idx_start}" "${new_lines[@]}" "${lines[@]:idx_end+1}")
                lines=("${temp[@]}")
                ;;
            "delete")
                local -a temp=("${lines[@]:0:idx_start}" "${lines[@]:idx_end+1}")
                lines=("${temp[@]}")
                ;;
            "append")
                local -a new_lines
                mapfile -t new_lines <<< "$content"
                local insert_idx=$((idx_end + 1))
                local -a temp=("${lines[@]:0:insert_idx}" "${new_lines[@]}" "${lines[@]:insert_idx}")
                lines=("${temp[@]}")
                ;;
            *)
                echo "Error: Unknown mode $mode"
                return 1
                ;;
        esac
    done

    if [[ ${#lines[@]} -eq 0 ]]; then
        > "$path"
    else
        local IFS=$'\n'
        echo "${lines[*]}" > "$path"
    fi
    echo "Successfully edited $path"
}

exec_shell_command() {
    local args_json="$1"

    local command timeout max_output_size
    command=$(echo "$args_json" | jq -r '.command // empty')
    if [[ -z "$command" ]]; then
        echo "Error: 'command' is required for exec_shell_command"
        return 1
    fi
    timeout=$(echo "$args_json" | jq -r '.timeout // 10')
    max_output_size=$(echo "$args_json" | jq -r '.max_output_size // 16384')

    if [[ "$timeout" -gt 60 ]]; then
        timeout=60
    fi

    local output
    output=$(timeout "$timeout" bash -c "$command" 2>&1)
    local exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
        echo "Error: Command timed out after ${timeout} seconds."
        return 1
    fi

    if [[ ${#output} -gt $max_output_size ]]; then
        output="${output:0:$max_output_size}... [truncated]"
    fi

    echo "$output"
}

execute_tool() {
    local tool_name="$1"
    local args_json="$2"

    # Validate JSON arguments before dispatching
    local jq_err
    if ! jq_err=$(echo "$args_json" | jq empty 2>&1); then
        echo "Error: Invalid JSON arguments: $jq_err"
        return 1
    fi

    case "$tool_name" in
        "read_file")         read_file "$args_json" ;;
        "write_file")        write_file "$args_json" ;;
        "edit_file")         edit_file "$args_json" ;;
        "exec_shell_command") exec_shell_command "$args_json" ;;
        *)
            echo "Error: Unknown tool $tool_name"
            return 1
            ;;
    esac
}

oai_make_request() {
    local user_message="$1"

    # Append user message to conversation history
    local user_msg_json
    user_msg_json=$(jq -n --arg content "$user_message" '{role: "user", content: $content}')
    CONVERSATION+=("$user_msg_json")

    local tools_json
    tools_json=$(get_tools_json)

    while true; do
        # Build messages array from history
        local messages_json="[]"
        for msg in "${CONVERSATION[@]}"; do
            messages_json=$(echo "$messages_json" | jq --argjson msg "$msg" '. + [$msg]')
        done

        # Construct API request body
        local request_body
        request_body=$(jq -n \
            --arg model "$BR_MODEL_NAME" \
            --argjson messages "$messages_json" \
            --argjson stream "$BR_MODEL_STREAM" \
            --argjson tools "$tools_json" \
            '{model: $model, messages: $messages, stream: $stream, tools: $tools}')

        # Prepare HTTP headers
        local curl_args=()
        curl_args+=("-H" "Content-Type: application/json")
        curl_args+=("-H" "X-Conversation-Id: $CONVERSATION_ID")
        curl_args+=("-H" "X-Session-Affinity: $SESSION_AFFINITY")
        if [[ -n "$BR_API_KEY" ]]; then
            curl_args+=("-H" "Authorization: Bearer $BR_API_KEY")
        fi

        local request_successful=false

        # Retry loop for communication failures
        while [[ "$request_successful" == "false" ]]; do
            local reasoning_content=""
            local reasoning_started=false
            local response_content=""
            local has_tool_calls=false
            local -a current_tool_calls=()
            local api_error=""
            local curl_exit_code=0
            local http_code="000"
            local err_detail=""
            local INTERRUPTED=false

            if [[ "$BR_MODEL_STREAM" == "true" ]]; then
                # Streaming Mode
                local tmp_pipe=$(mktemp -u)
                mkfifo "$tmp_pipe"

                curl -s -N -w "\n%{http_code}" --max-time "$BR_TIMEOUT" "$BR_BASE_URL/chat/completions" "${curl_args[@]}" -d "$request_body" > "$tmp_pipe" &
                local CURL_PID=$!

                local DONE_RECEIVED=false
                exec 3< "$tmp_pipe"
                while true; do
                    # Check for ESC key (Interrupt)
                    if IFS= read -t 0.001 -n 1 key 2>/dev/null; then
                        if [[ "$key" == $'\e' ]]; then
                            INTERRUPTED=true
                            break
                        fi
                    fi

                    # Check for data from curl
                    if IFS= read -t 0.01 -r line <&3; then
                        : # Data received
                    elif [[ -n "$line" ]]; then
                        : # EOF with partial line
                    else
                        # No data from curl
                        if ! kill -0 "$CURL_PID" 2>/dev/null; then
                            break # curl exited
                        fi
                        continue
                    fi

                    [[ -z "$line" ]] && continue
                    if [[ "$line" == "data: [DONE]" ]]; then
                        DONE_RECEIVED=true
                        break
                    fi

                    if [[ "$line" =~ ^data:\ (.+)$ ]]; then
                        local json_data="${BASH_REMATCH[1]}"

                        # Check for API error
                        local err_msg
                        err_msg=$(echo "$json_data" | jq -r '.error.message // empty')
                        if [[ -n "$err_msg" ]]; then
                            api_error="$err_msg"
                            break
                        fi

                        # Process reasoning content
                        local reasoning_delta
                        reasoning_delta=$(echo "$json_data" | jq -j '.choices[0].delta.reasoning_content // empty'; printf x)
                        reasoning_delta="${reasoning_delta%x}"
                        if [[ -n "$reasoning_delta" ]]; then
                            if [[ "$reasoning_started" == "false" ]]; then
                                printf "%s[THINK]" "${COLOR_DIM}"
                                reasoning_started=true
                            fi
                            printf "%s" "$reasoning_delta"
                            reasoning_content+="$reasoning_delta"
                        fi

                        # Process response content
                        local content
                        content=$(echo "$json_data" | jq -j '.choices[0].delta.content // empty'; printf x)
                        content="${content%x}"
                        if [[ -n "$content" ]]; then
                            if [[ "$reasoning_started" == "true" ]]; then
                                printf "[/THINK]%s\n\n" "${COLOR_RESET}"
                                reasoning_started=false
                                # Strip leading newlines to avoid excessive blank lines
                                while [[ "$content" =~ ^$'\n' ]]; do
                                    content="${content:1}"
                                done
                            fi
                            if [[ -n "$content" ]]; then
                                printf "%s" "$content"
                                response_content+="$content"
                            fi
                        fi

                        # Process tool calls (accumulate fragments by index)
                        local tc_count
                        tc_count=$(echo "$json_data" | jq -r '(.choices[0].delta.tool_calls // []) | length')
                        if [[ "$tc_count" -gt 0 ]]; then
                            if [[ "$reasoning_started" == "true" ]]; then
                                printf "[/THINK]%s\n\n" "${COLOR_RESET}"
                                reasoning_started=false
                            fi
                            has_tool_calls=true
                            for ((i=0; i<tc_count; i++)); do
                                local idx
                                idx=$(echo "$json_data" | jq -r ".choices[0].delta.tool_calls[$i].index")

                                if [[ -z "${current_tool_calls[$idx]}" ]]; then
                                    current_tool_calls[$idx]="{}"
                                fi

                                local delta_tc
                                delta_tc=$(echo "$json_data" | jq -c ".choices[0].delta.tool_calls[$i]")
                                current_tool_calls[$idx]=$(echo "${current_tool_calls[$idx]}" "$delta_tc" | jq -s '
                                    .[0] as $base | .[1] as $delta |
                                    $base |
                                    if $delta.id then .id = $delta.id else . end |
                                    if $delta.type then .type = $delta.type else . end |
                                    if $delta.function then
                                        .function = (
                                            (.function // {}) |
                                            if $delta.function.name then .name = $delta.function.name else . end |
                                            if $delta.function.arguments then
                                                .arguments = ((.arguments // "") + $delta.function.arguments)
                                            else . end
                                        )
                                    else . end
                                ')
                            done
                        fi
                    elif [[ "$line" =~ ^[0-9]{3}$ ]]; then
                        http_code="$line"
                    fi
                done
                exec 3<&-
                rm -f "$tmp_pipe"

                if [[ "$INTERRUPTED" == "true" ]]; then
                    kill "$CURL_PID" 2>/dev/null
                    wait "$CURL_PID" 2>/dev/null
                    printf "\n%s[INTERRUPTED]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
                    unset 'CONVERSATION[-1]' # Remove the user message since it wasn't processed
                    return 0
                fi

                if [[ "$DONE_RECEIVED" == "true" || -n "$api_error" ]]; then
                    kill "$CURL_PID" 2>/dev/null
                    wait "$CURL_PID" 2>/dev/null
                    curl_exit_code=0
                else
                    wait "$CURL_PID" 2>/dev/null
                    curl_exit_code=$?
                fi

            else
                # Non-Streaming Mode
                local response_file=$(mktemp)
                curl -s -w "\n%{http_code}" --max-time "$BR_TIMEOUT" "$BR_BASE_URL/chat/completions" "${curl_args[@]}" -d "$request_body" > "$response_file" &
                local CURL_PID=$!

                while kill -0 "$CURL_PID" 2>/dev/null; do
                    if IFS= read -t 0.1 -n 1 key 2>/dev/null; then
                        if [[ "$key" == $'\e' ]]; then
                            INTERRUPTED=true
                            kill "$CURL_PID" 2>/dev/null
                            break
                        fi
                    fi
                done
                wait "$CURL_PID" 2>/dev/null
                curl_exit_code=$?

                if [[ "$INTERRUPTED" == "true" ]]; then
                    rm -f "$response_file"
                    printf "\n%s[INTERRUPTED]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
                    unset 'CONVERSATION[-1]' # Remove the user message since it wasn't processed
                    return 0
                fi

                local response_raw
                response_raw=$(cat "$response_file")
                rm -f "$response_file"

                http_code=$(echo "$response_raw" | tail -n 1)
                local response
                response=$(echo "$response_raw" | sed '$d')

                if [[ -n "$response" ]]; then
                    local error_msg
                    error_msg=$(echo "$response" | jq -r '.error.message // empty' 2>/dev/null)
                    if [[ -n "$error_msg" ]]; then
                        api_error="$error_msg"
                    else
                        local message_json
                        message_json=$(echo "$response" | jq -c '.choices[0].message // empty' 2>/dev/null)
                        if [[ -n "$message_json" ]]; then
                            response_content=$(echo "$message_json" | jq -j '.content // empty'; printf x)
                            response_content="${response_content%x}"
                            reasoning_content=$(echo "$message_json" | jq -j '.reasoning_content // empty'; printf x)
                            reasoning_content="${reasoning_content%x}"

                            local tc_count
                            tc_count=$(echo "$message_json" | jq '(.tool_calls // []) | length')
                            if [[ "$tc_count" -gt 0 ]]; then
                                has_tool_calls=true
                                for ((i=0; i<tc_count; i++)); do
                                    local tc_json
                                    tc_json=$(echo "$message_json" | jq -c ".tool_calls[$i]")
                                    current_tool_calls[$i]="$tc_json"
                                done
                            fi
                        fi
                    fi
                fi
            fi

            # Determine if we should retry based on curl exit code and HTTP status
            local should_retry=false
            if [[ $curl_exit_code -ne 0 ]]; then
                should_retry=true
                err_detail="Connection failed (curl exit code $curl_exit_code)"
            elif [[ "$http_code" =~ ^5 ]]; then
                should_retry=true
                err_detail="Server error (HTTP $http_code)"
            elif [[ -n "$api_error" ]]; then
                if [[ "$http_code" =~ ^4 ]]; then
                    should_retry=false
                    err_detail="Client error (HTTP $http_code): $api_error"
                else
                    should_retry=true
                    err_detail="API Error: $api_error"
                fi
            fi

            # Execute retry wait if needed
            if [[ "$should_retry" == "true" ]]; then
                if [[ $GLOBAL_RETRY_COUNT -gt $BR_RETRIES ]]; then
                    echo -e "\n[Max retries ($BR_RETRIES) reached. Aborting request.]"
                    return 1
                fi

                echo -e "\n[Error communicating with LLM server: $err_detail]"
                echo "[Retry $GLOBAL_RETRY_COUNT/$BR_RETRIES in ${GLOBAL_RETRY_DELAY}s...]"

                sleep "$GLOBAL_RETRY_DELAY"

                # Exponential backoff
                GLOBAL_RETRY_DELAY=$((GLOBAL_RETRY_DELAY * 2))
                if [[ $GLOBAL_RETRY_DELAY -gt 128 ]]; then
                    GLOBAL_RETRY_DELAY=2
                fi
                GLOBAL_RETRY_COUNT=$((GLOBAL_RETRY_COUNT + 1))
                continue
            fi

            # Abort on fatal client error
            if [[ "$should_retry" == "false" && -n "$api_error" ]]; then
                echo -e "\nAPI Error: $api_error"
                return 1
            fi

            # Reset retry state on success
            request_successful=true
            GLOBAL_RETRY_COUNT=1
            GLOBAL_RETRY_DELAY=2
        done

        # Close reasoning tag if stream ended while still in THINK block
        if [[ "$reasoning_started" == "true" ]]; then
            printf "[/THINK]%s\n\n" "${COLOR_RESET}"
        fi

        # Handle non-streaming output display
        if [[ "$BR_MODEL_STREAM" == "false" ]]; then
            if [[ -n "$reasoning_content" ]]; then
                printf "%s[THINK]" "${COLOR_DIM}"
                printf "%s" "$reasoning_content"
                printf "[/THINK]%s\n\n" "${COLOR_RESET}"
            fi
            # Strip leading newlines from response_content
            while [[ "$response_content" =~ ^$'\n' ]]; do
                response_content="${response_content:1}"
            done
            if [[ -n "$response_content" ]]; then
                printf "%s" "$response_content"
            fi
        fi

        if [[ "$has_tool_calls" == "true" ]]; then
            # Ensure exactly one blank line between text and tool calls
            if [[ -n "$response_content" ]]; then
                if [[ "$response_content" != *$'\n' ]]; then
                    printf "\n\n"
                elif [[ "$response_content" != *$'\n\n' ]]; then
                    printf "\n"
                fi
            fi

            # Format accumulated tool calls
            local final_tool_calls="[]"
            for tc in "${current_tool_calls[@]}"; do
                final_tool_calls=$(echo "$final_tool_calls" | jq --argjson tc "$tc" '. + [$tc]')
            done

            # Append assistant message with tool_calls to history
            local assistant_msg
            if [[ -n "$response_content" ]]; then
                assistant_msg=$(jq -n --arg content "$response_content" --argjson tool_calls "$final_tool_calls" '{role: "assistant", content: $content, tool_calls: $tool_calls}')
            else
                assistant_msg=$(jq -n --argjson tool_calls "$final_tool_calls" '{role: "assistant", tool_calls: $tool_calls}')
            fi

            if [[ -n "$reasoning_content" ]]; then
                assistant_msg=$(echo "$assistant_msg" | jq --arg rc "$reasoning_content" '. + {reasoning_content: $rc}')
            fi

            CONVERSATION+=("$assistant_msg")

            # Execute each tool call sequentially
            local tc_length
            tc_length=$(echo "$final_tool_calls" | jq 'length')
            for ((i=0; i<tc_length; i++)); do
                local tc_id func_name args_json tc_json
                tc_id=$(echo "$final_tool_calls" | jq -r ".[$i].id")
                func_name=$(echo "$final_tool_calls" | jq -r ".[$i].function.name")
                args_json=$(echo "$final_tool_calls" | jq -r ".[$i].function.arguments")
                tc_json=$(echo "$final_tool_calls" | jq -c ".[$i]")

                printf "%s[TOOL_CALL]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
                echo "$tc_json" | jq $JQ_COLOR_FLAG .
                printf "%s[/TOOL_CALL]%s\n\n" "${COLOR_DIM}" "${COLOR_RESET}"

                printf "%s[TOOL_RESPONSE]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
                printf "%s" "${COLOR_DIM}"
                local tool_output
                local tool_exit=0
                tool_output=$(execute_tool "$func_name" "$args_json" 2>&1) || tool_exit=$?

                if [[ $tool_exit -ne 0 ]]; then
                    if [[ "$tool_output" != Error:* ]]; then
                        echo "Error: $tool_output"
                        tool_output="Error: $tool_output"
                    else
                        echo "$tool_output"
                    fi
                else
                    echo "$tool_output"
                fi
                printf "%s[/TOOL_RESPONSE]%s\n\n" "${COLOR_DIM}" "${COLOR_RESET}"

                # Append tool response to history for next API call
                local tool_msg
                tool_msg=$(jq -n \
                    --arg role "tool" \
                    --arg content "$tool_output" \
                    --arg tool_call_id "$tc_id" \
                    '{role: $role, content: $content, tool_call_id: $tool_call_id}')
                CONVERSATION+=("$tool_msg")
            done

            # Loop again to send tool results back to LLM
            continue
        else
            # No tool calls: append final assistant message and finish request
            local assistant_msg
            assistant_msg=$(jq -n --arg content "$response_content" '{role: "assistant", content: $content}')
            if [[ -n "$reasoning_content" ]]; then
                assistant_msg=$(echo "$assistant_msg" | jq --arg rc "$reasoning_content" '. + {reasoning_content: $rc}')
            fi
            CONVERSATION+=("$assistant_msg")
            printf "\n"
            break
        fi
    done
}

main() {
    # Initialize session headers first so they are available for read_env_vars
    CONVERSATION_ID=$(uuidgen)
    SESSION_AFFINITY=$(uuidgen)

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

        # Handle exit commands
        if [[ "$message" == "/exit" || "$message" == "/quit" ]]; then
            break
        fi

        # Handle session reset commands
        if [[ "$message" == "/new" || "$message" == "/clear" ]]; then
            echo "Previous session closed."
            CONVERSATION=()
            CONVERSATION_ID=$(uuidgen)
            SESSION_AFFINITY=$(uuidgen)
            print_config_and_headers
            continue
        fi

        echo
        echo -n "Assistant: "
        oai_make_request "$message"
    done
}

main
exit 0

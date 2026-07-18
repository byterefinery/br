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
  BR_TIMEOUT       Request timeout in seconds (default: 600)
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

# Save terminal state for restoration on exit
OLD_STTY=$(stty -g 2>/dev/null || true)

# Enable standard readline editing mode (emacs) so UP/DOWN navigate history
set -o emacs

# READLINE BINDINGS
bind '"\C-k\C-j": "\C-v\C-j"'
bind '"\C-j": accept-line'
bind '"\e\r": "\C-v\C-j"'
bind '"\e\n": "\C-v\C-j"'
bind '"\r": accept-line'
bind '"\C-m": accept-line'
bind '"\n": accept-line'

# CTRL+C clears the current input line instead of sending SIGINT
bind '"\C-c": kill-whole-line'

# Apply TTY settings: disable signal generation on CTRL+C so readline handles it
# Re-applied before every read because readline restores terminal modes after each input
apply_tty_settings() {
    stty -echoctl -isig intr undef 2>/dev/null || true
}

apply_tty_settings

# Ignore SIGINT as extra protection (stty intr undef already prevents it)
trap '' SIGINT

# Restore terminal state on exit
trap 'stty sane; stty "$OLD_STTY" 2>/dev/null || true' EXIT

# Set default values first
export BR_BASE_URL="${BR_BASE_URL:-http://localhost:8080/v1}"
export BR_API_KEY="${BR_API_KEY:-}"
export BR_MODEL_NAME="${BR_MODEL_NAME:-}"
export BR_MODEL_INPUT="${BR_MODEL_INPUT:-text}"
export BR_MODEL_STREAM="${BR_MODEL_STREAM:-true}"
export BR_TIMEOUT="${BR_TIMEOUT:-600}"
export BR_RETRIES="${BR_RETRIES:-100}"

# Session/Conversation state (global associative arrays)
declare -A SESSIONS    # SESSIONS[name]=session_uuid
declare -A CONVS       # CONVS["session|conv"]=conv_uuid
declare -A MSGS        # MSGS["session|conv"]="[json array of messages]"

CUR_SESSION_NAME=""
CUR_CONV_NAME=""

# Global conversation history as array of JSON strings (reflects current conv)
CONVERSATION=()

# Global session headers for smart HTTP routing
SESSION_AFFINITY=""
CONVERSATION_ID=""

# Global state for retry logic
GLOBAL_RETRY_COUNT=1
GLOBAL_RETRY_DELAY=2

# Generate lowercase UUID
gen_uuid() {
    uuidgen | tr '[:upper:]' '[:lower:]'
}

# Print configuration and session headers
print_config_and_headers() {
    local masked_api_key
    if [[ -n "$BR_API_KEY" ]]; then
        masked_api_key="${BR_API_KEY//?/*}"
    else
        masked_api_key="(empty)"
    fi

    echo "Configuration:"
    echo "  BR_BASE_URL     : $BR_BASE_URL"
    echo "  BR_API_KEY      : $masked_api_key"
    echo "  BR_MODEL_NAME   : ${BR_MODEL_NAME:-(empty)}"
    echo "  BR_MODEL_INPUT  : ${BR_MODEL_INPUT:-text}"
    echo "  BR_MODEL_STREAM : ${BR_MODEL_STREAM:-true}"
    echo "  BR_TIMEOUT      : ${BR_TIMEOUT:-600}"
    echo "  BR_RETRIES      : ${BR_RETRIES:-100}"
    echo "Headers:"
    echo "  X-Session-Affinity : $SESSION_AFFINITY (${CUR_SESSION_NAME:-(none)})"
    echo "  X-Conversation-Id  : $CONVERSATION_ID (${CUR_CONV_NAME:-(none)})"
}

read_env_vars() {
    local config_file=""
    if [[ -f ".env" ]]; then
        config_file=".env"
    elif [[ -f "$HOME/.config/br/config" ]]; then
        config_file="$HOME/.config/br/config"
    else
        echo "Warning: default values are used instead of config files." >&2
        echo "" >&2
    fi
    if [[ -n "$config_file" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$config_file"
        set +a
    fi
    local model_stream_val="${BR_MODEL_STREAM:-true}"
    case "$model_stream_val" in
        [tT][rR][uU][eE]|[yY][eE][sS]|[yY]|1) model_stream_val="true" ;;
        *) model_stream_val="false" ;;
    esac
    export BR_MODEL_STREAM="$model_stream_val"
    if ! [[ "$BR_TIMEOUT" =~ ^[0-9]+$ ]]; then export BR_TIMEOUT=600; fi
    if ! [[ "$BR_RETRIES" =~ ^[0-9]+$ ]]; then export BR_RETRIES=100; fi
    br_info
}

get_tools_json() {
    cat <<'EOF'
[
  {
    "type": "function",
    "function": {
      "name": "read_file",
      "description": "Read the contents of a file. Optionally specify a 1-based line range.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Path to the file" },
          "start_line": { "type": "integer", "description": "First line to read (1-based)" },
          "end_line": { "type": "integer", "description": "Last line to read (1-based, inclusive)" },
          "append_loc": { "type": "boolean", "description": "Prefix each line with its line number" }
        },
        "required": ["path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "write_file",
      "description": "Write content to a file, creating parent directories if needed.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Path of the file to write" },
          "content": { "type": "string", "description": "Content to write" }
        },
        "required": ["path", "content"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "edit_file",
      "description": "Edit a file using line-based changes.",
      "parameters": {
        "type": "object",
        "properties": {
          "path": { "type": "string", "description": "Path to the file" },
          "changes": {
            "type": "array",
            "items": {
              "type": "object",
              "properties": {
                "mode": { "type": "string", "description": "\"replace\", \"delete\", or \"append\"" },
                "line_start": { "type": "integer", "description": "Start line (1-based). Use -1 for end of file" },
                "line_end": { "type": "integer", "description": "End line (1-based)" },
                "content": { "type": "string", "description": "Content to insert (empty string for delete)" }
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
      "description": "Execute a shell command.",
      "parameters": {
        "type": "object",
        "properties": {
          "command": { "type": "string", "description": "Shell command to run" },
          "timeout": { "type": "integer", "description": "Timeout in seconds (default: 10)" },
          "max_output_size": { "type": "integer", "description": "Max output size in bytes (default: 16384)" }
        },
        "required": ["command"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "agent_skills_system",
      "description": "Learn how the Agent Skills System works and the correct way to use skill tools.",
      "parameters": { "type": "object", "properties": {} }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "list_skills",
      "description": "List all available skills. Returns name, description, and path for each skill.",
      "parameters": { "type": "object", "properties": {} }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "load_skill",
      "description": "Load a skill's `.agents/skills/<skill_name>/SKILL.md` into context. Use after checking with `list_skills`.",
      "parameters": {
        "type": "object",
        "properties": {
          "skill_name": {
            "type": "string",
            "description": "Skill directory name `<skill_name>` under `.agents/skills/` (e.g. 'pdf-processing')"
          }
        },
        "required": ["skill_name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "list_skill_files",
      "description": "List all files inside a specific skill directory (including `scripts/`, `references/`, and `assets/`). Returns full paths under `.agents/skills/<skill_name>/`. Use this to explore what resources a skill contains.",
      "parameters": {
        "type": "object",
        "properties": {
          "skill_name": {
            "type": "string",
            "description": "Skill directory name `<skill_name>` under `.agents/skills/<skill_name>/` (e.g. 'pdf-processing')"
          }
        },
        "required": ["skill_name"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "read_skill_resource",
      "description": "Read a file from a skill's `references/`, `scripts/`, or `assets/` directory. `resource_path` is relative to the skill root `.agents/skills/<skill_name>/<resource_path>`.",
      "parameters": {
        "type": "object",
        "properties": {
          "skill_name": { "type": "string", "description": "Skill directory name `<skill_name>`" },
          "resource_path": { "type": "string", "description": "Relative path (e.g. 'references/01-api.md' or 'scripts/pdf-processing.sh')" }
        },
        "required": ["skill_name", "resource_path"]
      }
    }
  },
  {
    "type": "function",
    "function": {
      "name": "exec_skill_scripts",
      "description": "Execute a script `<skill_name>` (e.g. 'pdf-processing.sh') from a skill's `.agents/skills/<skill_name>/scripts/<script_name>` directory. Use this instead of `exec_shell_command` for skill scripts.",
      "parameters": {
        "type": "object",
        "properties": {
          "skill_name": { "type": "string", "description": "Skill directory name `<skill_name>`" },
          "script_name": { "type": "string", "description": "Script name `<skill_name>` (e.g. 'pdf-processing.sh') relative to the skill's `.agents/skills/<skill_name>/scripts/` directory" },
          "args": {
            "type": "array",
            "items": { "type": "string" },
            "description": "Optional arguments to pass to the script `.agents/skills/<skill_name>/scripts/<script_name>`"
          }
        },
        "required": ["skill_name", "script_name"]
      }
    }
  }
]
EOF
}

init_conversation() {
    CONVERSATION=()
}

# Helper functions

# Validate name: non-empty, no spaces, no pipe
is_valid_name() {
    local name="$1"
    [[ -z "$name" ]] && return 1
    [[ "$name" == *" "* ]] && return 1
    [[ "$name" == *"|"* ]] && return 1
    return 0
}

# Resolve id-or-name to internal name key
get_sess_name() {
    local arg="$1"
    if [[ -n "${SESSIONS[$arg]+x}" ]]; then echo "$arg"; return 0; fi
    for name in "${!SESSIONS[@]}"; do
        if [[ "${SESSIONS[$name]}" == "$arg" ]]; then echo "$name"; return 0; fi
    done
    return 1
}

get_conv_name() {
    local sess="$1" arg="$2"
    if [[ -n "${CONVS["$sess|$arg"]+x}" ]]; then echo "$arg"; return 0; fi
    for key in "${!CONVS[@]}"; do
        if [[ "$key" == "$sess|"* ]]; then
            local conv="${key#$sess|}"
            if [[ "${CONVS[$key]}" == "$arg" ]]; then echo "$conv"; return 0; fi
        fi
    done
    return 1
}

count_convs_in_session() {
    local sess="$1" count=0
    for key in "${!CONVS[@]}"; do
        [[ "$key" == "${sess}|"* ]] && ((count++))
    done
    echo "$count"
}

count_msgs_in_conv() {
    local key="$1|$2"
    printf '%s' "${MSGS[$key]:-[]}" | jq 'length'
}

# Sync in-memory CONVERSATION array to MSGS for current pointers
br_sync_msgs() {
    [[ -z "$CUR_SESSION_NAME" || -z "$CUR_CONV_NAME" ]] && return 0
    local key="${CUR_SESSION_NAME}|${CUR_CONV_NAME}"
    if [[ ${#CONVERSATION[@]} -gt 0 ]]; then
        MSGS[$key]=$(printf '%s\n' "${CONVERSATION[@]}" | jq -s '.')
    else
        MSGS[$key]="[]"
    fi
}

# Load MSGS for current pointers into CONVERSATION array
br_load_msgs() {
    CONVERSATION=()
    [[ -z "$CUR_SESSION_NAME" || -z "$CUR_CONV_NAME" ]] && return 0
    local key="${CUR_SESSION_NAME}|${CUR_CONV_NAME}"
    local msgs_json="${MSGS[$key]:-[]}"
    local count
    count=$(printf '%s' "$msgs_json" | jq 'length')
    for ((i=0; i<count; i++)); do
        CONVERSATION+=("$(printf '%s' "$msgs_json" | jq -c ".[$i]")")
    done
}

# Update SESSION_AFFINITY/CONVERSATION_ID from current pointers
br_update_headers() {
    if [[ -n "$CUR_SESSION_NAME" ]] && [[ -n "${SESSIONS[$CUR_SESSION_NAME]+x}" ]]; then
        SESSION_AFFINITY="${SESSIONS[$CUR_SESSION_NAME]}"
    else
        SESSION_AFFINITY=""
    fi
    if [[ -n "$CUR_CONV_NAME" ]] && [[ -n "${CONVS["$CUR_SESSION_NAME|$CUR_CONV_NAME"]+x}" ]]; then
        CONVERSATION_ID="${CONVS[${CUR_SESSION_NAME}|${CUR_CONV_NAME}]}"
    else
        CONVERSATION_ID=""
    fi
}

# Check if current session and conversation are valid
br_check_current() {
    if [[ -z "$CUR_SESSION_NAME" ]] || [[ -z "${SESSIONS[$CUR_SESSION_NAME]+x}" ]]; then
        printf "%s[ERROR] No active session. Use /session new or /session resume. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
        return 1
    fi
    if [[ -z "$CUR_CONV_NAME" ]] || [[ -z "${CONVS["$CUR_SESSION_NAME|$CUR_CONV_NAME"]+x}" ]]; then
        printf "%s[ERROR] No active conversation. Use /session conv new or /session conv resume. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
        return 1
    fi
    return 0
}

# /info
br_info() {
    print_config_and_headers
    echo "Session:"
    if [[ -n "$CUR_SESSION_NAME" ]] && [[ -n "${SESSIONS[$CUR_SESSION_NAME]+x}" ]]; then
        echo "  Name: $CUR_SESSION_NAME"
        echo "  ID  : ${SESSIONS[$CUR_SESSION_NAME]}"
        echo "  Convs: $(count_convs_in_session "$CUR_SESSION_NAME")"
    else
        echo "  (no current session)"
    fi
    echo "Conversation:"
    if [[ -n "$CUR_CONV_NAME" ]] && [[ -n "${CONVS["$CUR_SESSION_NAME|$CUR_CONV_NAME"]+x}" ]]; then
        echo "  Name: $CUR_CONV_NAME"
        echo "  ID  : ${CONVS[${CUR_SESSION_NAME}|${CUR_CONV_NAME}]}"
        echo "  Msgs: $(count_msgs_in_conv "$CUR_SESSION_NAME" "$CUR_CONV_NAME")"
    else
        echo "  (no current conversation)"
    fi
    printf "%s[INFO] Type /help to see all commands and examples. [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
}

# Session commands

br_session_ls() {
    if [[ ${#SESSIONS[@]} -eq 0 ]]; then
        printf "%s[INFO] No sessions. [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
        return 0
    fi
    printf "%s%-40s %-40s %-6s%s\n" "${COLOR_DIM}" "NAME" "ID" "CONVS" "${COLOR_RESET}"
    for name in "${!SESSIONS[@]}"; do
        local marker=" "
        [[ "$name" == "$CUR_SESSION_NAME" ]] && marker="*"
        printf "%s %-39s %-40s %-6s\n" "$marker" "$name" "${SESSIONS[$name]}" "$(count_convs_in_session "$name")"
    done
}

br_session_new() {
    local name id
    id=$(gen_uuid)
    name="${1:-${id: -12}}" # default to last 12 chars of UUID
    if ! is_valid_name "$name"; then
        printf "%s[ERROR] Invalid session name (no spaces or '|'). [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
        return 1
    fi
    if [[ -n "${SESSIONS[$name]+x}" ]]; then
        printf "%s[ERROR] Session '%s' already exists. [/ERROR]%s\n" "${COLOR_DIM}" "$name" "${COLOR_RESET}"
        return 1
    fi
    br_sync_msgs
    SESSIONS[$name]="$id"
    CUR_SESSION_NAME="$name"
    CUR_CONV_NAME=""
    CONVERSATION=()
    br_update_headers
    printf "%s[INFO] Created and switched to session '%s' (id: %s). No current conversation. [/INFO]%s\n" "${COLOR_DIM}" "$name" "$id" "${COLOR_RESET}"
}

br_session_clear() {
    local sess
    if [[ -z "$1" ]]; then
        sess="$CUR_SESSION_NAME"
    else
        sess=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
    fi
    if [[ -z "$sess" ]]; then
        printf "%s[ERROR] No current session. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    local -a to_remove=()
    for key in "${!CONVS[@]}"; do
        [[ "$key" == "${sess}|"* ]] && to_remove+=("$key")
    done
    for key in "${to_remove[@]}"; do
        unset "CONVS[$key]"
        unset "MSGS[$key]"
    done
    if [[ "$sess" == "$CUR_SESSION_NAME" ]]; then
        CUR_CONV_NAME=""
        CONVERSATION=()
        br_update_headers
        printf "%s[INFO] Cleared all conversations in current session '%s'. No current conversation. [/INFO]%s\n" "${COLOR_DIM}" "$sess" "${COLOR_RESET}"
    else
        printf "%s[INFO] Cleared all conversations in session '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$sess" "${COLOR_RESET}"
    fi
}

br_session_mv() {
    local old new
    if [[ $# -eq 1 ]]; then
        [[ -z "$CUR_SESSION_NAME" ]] && { printf "%s[ERROR] No current session. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1; }
        old="$CUR_SESSION_NAME"; new="$1"
    elif [[ $# -eq 2 ]]; then
        old=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
        new="$2"
    else
        printf "%s[ERROR] Usage: /session mv <new> | <old> <new>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -n "${SESSIONS[$new]+x}" ]]; then
        printf "%s[ERROR] Session '%s' already exists. [/ERROR]%s\n" "${COLOR_DIM}" "$new" "${COLOR_RESET}"
        return 1
    fi
    if ! is_valid_name "$new"; then
        printf "%s[ERROR] Invalid session name. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    br_sync_msgs
    SESSIONS[$new]="${SESSIONS[$old]}"
    unset "SESSIONS[$old]"
    # Move conv entries
    local -a keys_to_move=()
    for key in "${!CONVS[@]}"; do
        [[ "$key" == "${old}|"* ]] && keys_to_move+=("$key")
    done
    for key in "${keys_to_move[@]}"; do
        local conv="${key#${old}|}"
        local new_key="${new}|${conv}"
        CONVS[$new_key]="${CONVS[$key]}"
        MSGS[$new_key]="${MSGS[$key]}"
        unset "CONVS[$key]"
        unset "MSGS[$key]"
    done
    if [[ "$old" == "$CUR_SESSION_NAME" ]]; then
        CUR_SESSION_NAME="$new"
    fi
    br_update_headers
    printf "%s[INFO] Renamed session '%s' -> '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$old" "$new" "${COLOR_RESET}"
}

br_session_cp() {
    local old new
    if [[ $# -eq 1 ]]; then
        [[ -z "$CUR_SESSION_NAME" ]] && { printf "%s[ERROR] No current session. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1; }
        old="$CUR_SESSION_NAME"; new="$1"
    elif [[ $# -eq 2 ]]; then
        old=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
        new="$2"
    else
        printf "%s[ERROR] Usage: /session cp <new> | <old> <new>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -n "${SESSIONS[$new]+x}" ]]; then
        printf "%s[ERROR] Session '%s' already exists. [/ERROR]%s\n" "${COLOR_DIM}" "$new" "${COLOR_RESET}"
        return 1
    fi
    if ! is_valid_name "$new"; then
        printf "%s[ERROR] Invalid session name. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    br_sync_msgs
    local new_id=$(gen_uuid)
    SESSIONS[$new]="$new_id"
    for key in "${!CONVS[@]}"; do
        if [[ "$key" == "${old}|"* ]]; then
            local conv="${key#${old}|}"
            local new_key="${new}|${conv}"
            local new_conv_id=$(gen_uuid)
            CONVS[$new_key]="$new_conv_id"
            MSGS[$new_key]="${MSGS[$key]}"
        fi
    done
    br_update_headers
    printf "%s[INFO] Copied session '%s' -> '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$old" "$new" "${COLOR_RESET}"
}

br_session_rm() {
    local name
    if [[ -z "$1" ]]; then
        name="$CUR_SESSION_NAME"
    else
        name=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
    fi
    if [[ -z "$name" ]]; then
        printf "%s[ERROR] No current session. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    br_sync_msgs
    unset "SESSIONS[$name]"
    local -a to_remove=()
    for key in "${!CONVS[@]}"; do
        [[ "$key" == "${name}|"* ]] && to_remove+=("$key")
    done
    for key in "${to_remove[@]}"; do
        unset "CONVS[$key]"
        unset "MSGS[$key]"
    done
    if [[ "$name" == "$CUR_SESSION_NAME" ]]; then
        CUR_SESSION_NAME=""
        CUR_CONV_NAME=""
        CONVERSATION=()
        br_update_headers
        printf "%s[INFO] Removed current session '%s'. No current session/conversation. Use /session resume or /session new. [/INFO]%s\n" "${COLOR_DIM}" "$name" "${COLOR_RESET}"
    else
        br_update_headers
        printf "%s[INFO] Removed session '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$name" "${COLOR_RESET}"
    fi
}

# Serialize single session to JSON
br_dump_session_json() {
    local name="$1"
    local id="${SESSIONS[$name]}"
    local convs_json="[]"
    for key in "${!CONVS[@]}"; do
        if [[ "$key" == "${name}|"* ]]; then
            local conv="${key#${name}|}"
            local conv_obj
            conv_obj=$(jq -n \
                --arg name "$conv" \
                --arg id "${CONVS[$key]}" \
                --argjson msgs "${MSGS[$key]:-[]}" \
                '{name: $name, id: $id, messages: $msgs}')
            convs_json=$(printf '%s\n%s' "$convs_json" "$conv_obj" | jq -s '.')
        fi
    done
    jq -n --arg name "$name" --arg id "$id" --argjson convs "$convs_json" \
        '{name: $name, id: $id, conversations: $convs}'
}

br_session_dump() {
    local name
    if [[ -z "$1" ]]; then
        name="$CUR_SESSION_NAME"
    else
        name=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
    fi
    if [[ -z "$name" ]]; then
        printf "%s[ERROR] No current session. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    br_sync_msgs
    br_dump_session_json "$name" | jq $JQ_COLOR_FLAG .
}

br_session_resume() {
    local name
    if [[ -z "$1" ]]; then
        printf "%s[ERROR] Usage: /session resume <id-or-name>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    name=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
    br_sync_msgs
    CUR_SESSION_NAME="$name"
    CUR_CONV_NAME=""
    CONVERSATION=()
    br_update_headers
    printf "%s[INFO] Resumed session '%s'. No current conversation set. [/INFO]%s\n" "${COLOR_DIM}" "$name" "${COLOR_RESET}"
}

br_session_save() {
    if [[ $# -eq 1 ]]; then
        local file="$1"
        local sessions_json="[]"
        for sname in "${!SESSIONS[@]}"; do
            local sjson=$(br_dump_session_json "$sname")
            sessions_json=$(printf '%s\n%s' "$sessions_json" "$sjson" | jq -s '.')
        done
        jq -n --argjson sessions "$sessions_json" '{sessions: $sessions}' > "$file"
        printf "%s[INFO] Saved %d session(s) to '%s'. [/INFO]%s\n" "${COLOR_DIM}" "${#SESSIONS[@]}" "$file" "${COLOR_RESET}"
    elif [[ $# -eq 2 ]]; then
        local name file
        name=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
        file="$2"
        br_sync_msgs
        br_dump_session_json "$name" | jq . > "$file"
        printf "%s[INFO] Saved session '%s' to '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$name" "$file" "${COLOR_RESET}"
    else
        printf "%s[ERROR] Usage: /session save <file> | <id-or-name> <file>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
}

br_session_load() {
    if [[ $# -eq 1 ]]; then
        local file="$1"
        [[ ! -f "$file" ]] && { printf "%s[ERROR] File not found: %s. [/ERROR]%s\n" "${COLOR_DIM}" "$file" "${COLOR_RESET}"; return 1; }
        br_sync_msgs
        local data=$(cat "$file")
        local count=0
        local n=$(printf '%s' "$data" | jq '.sessions | length')
        for ((i=0; i<n; i++)); do
            local sname=$(printf '%s' "$data" | jq -r ".sessions[$i].name")
            local sid=$(printf '%s' "$data" | jq -r ".sessions[$i].id")
            SESSIONS[$sname]="$sid"
            local cn=$(printf '%s' "$data" | jq ".sessions[$i].conversations | length")
            for ((j=0; j<cn; j++)); do
                local cname=$(printf '%s' "$data" | jq -r ".sessions[$i].conversations[$j].name")
                local cid=$(printf '%s' "$data" | jq -r ".sessions[$i].conversations[$j].id")
                local cmsgs=$(printf '%s' "$data" | jq -c ".sessions[$i].conversations[$j].messages")
                local key="${sname}|${cname}"
                CONVS[$key]="$cid"
                MSGS[$key]="$cmsgs"
            done
            ((count++))
        done
        br_sync_msgs; br_load_msgs; br_update_headers
        printf "%s[INFO] Loaded %d session(s) from '%s'. Same-name sessions replaced. [/INFO]%s\n" "${COLOR_DIM}" "$count" "$file" "${COLOR_RESET}"
    elif [[ $# -eq 2 ]]; then
        local file="$1" name="$2"
        [[ ! -f "$file" ]] && { printf "%s[ERROR] File not found: %s. [/ERROR]%s\n" "${COLOR_DIM}" "$file" "${COLOR_RESET}"; return 1; }
        if ! is_valid_name "$name"; then
            printf "%s[ERROR] Invalid session name. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
        fi
        br_sync_msgs
        local data=$(cat "$file")
        local sjson
        if [[ "$(printf '%s' "$data" | jq -r 'has("sessions")')" == "true" ]]; then
            sjson=$(printf '%s' "$data" | jq -c '.sessions[0]')
        else
            sjson=$(printf '%s' "$data" | jq -c '.')
        fi
        SESSIONS[$name]=$(printf '%s' "$sjson" | jq -r '.id')
        # Remove existing convs for this session
        local -a to_remove=()
        for key in "${!CONVS[@]}"; do
            [[ "$key" == "${name}|"* ]] && to_remove+=("$key")
        done
        for key in "${to_remove[@]}"; do
            unset "CONVS[$key]"; unset "MSGS[$key]"
        done
        local cn=$(printf '%s' "$sjson" | jq '.conversations | length')
        for ((j=0; j<cn; j++)); do
            local cname=$(printf '%s' "$sjson" | jq -r ".conversations[$j].name")
            local cid=$(printf '%s' "$sjson" | jq -r ".conversations[$j].id")
            local cmsgs=$(printf '%s' "$sjson" | jq -c ".conversations[$j].messages")
            local key="${name}|${cname}"
            CONVS[$key]="$cid"; MSGS[$key]="$cmsgs"
        done
        br_sync_msgs; br_load_msgs; br_update_headers
        printf "%s[INFO] Loaded session into '%s' from '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$name" "$file" "${COLOR_RESET}"
    else
        printf "%s[ERROR] Usage: /session load <file> | <file> <name>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
}

# Conversation commands

br_conv_ls() {
    local sess
    if [[ -z "$1" ]]; then
        sess="$CUR_SESSION_NAME"
    else
        sess=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
    fi
    if [[ -z "$sess" ]]; then
        printf "%s[ERROR] No current session. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    local -a convs_in_sess=()
    for key in "${!CONVS[@]}"; do
        [[ "$key" == "${sess}|"* ]] && convs_in_sess+=("${key#${sess}|}")
    done
    if [[ ${#convs_in_sess[@]} -eq 0 ]]; then
        printf "%s[INFO] No conversations in session '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$sess" "${COLOR_RESET}"
        return 0
    fi
    printf "%s%-40s %-40s %-6s%s\n" "${COLOR_DIM}" "NAME" "ID" "MSGS" "${COLOR_RESET}"
    for conv in "${convs_in_sess[@]}"; do
        local marker=" "
        [[ "$sess" == "$CUR_SESSION_NAME" && "$conv" == "$CUR_CONV_NAME" ]] && marker="*"
        printf "%s %-39s %-40s %-6s\n" "$marker" "$conv" "${CONVS[${sess}|${conv}]}" "$(count_msgs_in_conv "$sess" "$conv")"
    done
}

br_conv_new() {
    local sess name id
    if [[ $# -eq 0 ]]; then
        sess="$CUR_SESSION_NAME"; id=$(gen_uuid); name="${id: -12}"
    elif [[ $# -eq 1 ]]; then
        sess="$CUR_SESSION_NAME"; name="$1"; id=$(gen_uuid)
    elif [[ $# -eq 2 ]]; then
        sess=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
        name="$2"; id=$(gen_uuid)
    else
        printf "%s[ERROR] Usage: /session conv new [sess] [conv]. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -z "$sess" ]]; then
        printf "%s[ERROR] No current session. Specify session or set one. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if ! is_valid_name "$name"; then
        printf "%s[ERROR] Invalid conv name (no spaces or '|'). [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -n "${CONVS["$sess|$name"]+x}" ]]; then
        printf "%s[ERROR] Conversation '%s' already exists in session '%s'. [/ERROR]%s\n" "${COLOR_DIM}" "$name" "$sess" "${COLOR_RESET}"; return 1
    fi
    br_sync_msgs
    local key="${sess}|${name}"
    CONVS[$key]="$id"
    MSGS[$key]="[]"
    CUR_SESSION_NAME="$sess"
    CUR_CONV_NAME="$name"
    CONVERSATION=()
    br_update_headers
    printf "%s[INFO] Created and switched to conversation '%s' (id: %s) in session '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$name" "$id" "$sess" "${COLOR_RESET}"
}

br_conv_rm() {
    local sess name
    if [[ $# -eq 0 ]]; then
        sess="$CUR_SESSION_NAME"; name="$CUR_CONV_NAME"
    elif [[ $# -eq 1 ]]; then
        sess="$CUR_SESSION_NAME"; name=$(get_conv_name "$sess" "$1") || { printf "%s[ERROR] Conversation '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
    elif [[ $# -eq 2 ]]; then
        sess=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
        name=$(get_conv_name "$sess" "$2") || { printf "%s[ERROR] Conversation '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$2" "${COLOR_RESET}"; return 1; }
    else
        printf "%s[ERROR] Usage: /session conv rm [sess] [conv]. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -z "$sess" ]]; then
        printf "%s[ERROR] No session specified. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -z "$name" ]]; then
        printf "%s[ERROR] No conversation specified. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    br_sync_msgs
    local key="${sess}|${name}"
    unset "CONVS[$key]"; unset "MSGS[$key]"
    if [[ "$sess" == "$CUR_SESSION_NAME" && "$name" == "$CUR_CONV_NAME" ]]; then
        CUR_CONV_NAME=""
        CONVERSATION=()
        br_update_headers
        printf "%s[INFO] Removed current conversation '%s' from session '%s'. No current conversation. [/INFO]%s\n" "${COLOR_DIM}" "$name" "$sess" "${COLOR_RESET}"
    else
        printf "%s[INFO] Removed conversation '%s' from session '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$name" "$sess" "${COLOR_RESET}"
    fi
}

br_conv_mv() {
    local src_sess src_conv dst_sess dst_conv
    if [[ $# -eq 1 ]]; then
        src_sess="$CUR_SESSION_NAME"; src_conv="$CUR_CONV_NAME"
        dst_sess="$CUR_SESSION_NAME"; dst_conv="$1"
    elif [[ $# -eq 2 ]]; then
        src_sess="$CUR_SESSION_NAME"; src_conv=$(get_conv_name "$src_sess" "$1") || { printf "%s[ERROR] Conversation '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
        dst_sess="$CUR_SESSION_NAME"; dst_conv="$2"
    elif [[ $# -eq 4 ]]; then
        src_sess=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
        src_conv=$(get_conv_name "$src_sess" "$2") || { printf "%s[ERROR] Conversation '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$2" "${COLOR_RESET}"; return 1; }
        dst_sess=$(get_sess_name "$3") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$3" "${COLOR_RESET}"; return 1; }
        dst_conv="$4"
    else
        printf "%s[ERROR] Usage: /session conv mv <new> | <old> <new> | <s1> <c1> <s2> <c2>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -z "$src_sess" || -z "$src_conv" ]]; then
        printf "%s[ERROR] No current conversation. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -n "${CONVS["$dst_sess|$dst_conv"]+x}" ]]; then
        printf "%s[ERROR] Conversation '%s' already exists in '%s'. [/ERROR]%s\n" "${COLOR_DIM}" "$dst_conv" "$dst_sess" "${COLOR_RESET}"; return 1
    fi
    if ! is_valid_name "$dst_conv"; then
        printf "%s[ERROR] Invalid conv name. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    br_sync_msgs
    local src_key="${src_sess}|${src_conv}"
    local dst_key="${dst_sess}|${dst_conv}"
    CONVS[$dst_key]="${CONVS[$src_key]}"
    MSGS[$dst_key]="${MSGS[$src_key]}"
    unset "CONVS[$src_key]"; unset "MSGS[$src_key]"
    if [[ "$src_sess" == "$CUR_SESSION_NAME" && "$src_conv" == "$CUR_CONV_NAME" ]]; then
        CUR_SESSION_NAME="$dst_sess"; CUR_CONV_NAME="$dst_conv"
        br_load_msgs
    fi
    br_update_headers
    printf "%s[INFO] Moved conversation '%s' (session '%s') -> '%s' (session '%s'). [/INFO]%s\n" "${COLOR_DIM}" "$src_conv" "$src_sess" "$dst_conv" "$dst_sess" "${COLOR_RESET}"
}

br_conv_cp() {
    local src_sess src_conv dst_sess dst_conv
    if [[ $# -eq 1 ]]; then
        src_sess="$CUR_SESSION_NAME"; src_conv="$CUR_CONV_NAME"
        dst_sess="$CUR_SESSION_NAME"; dst_conv="$1"
    elif [[ $# -eq 2 ]]; then
        src_sess="$CUR_SESSION_NAME"; src_conv=$(get_conv_name "$src_sess" "$1") || { printf "%s[ERROR] Conversation '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
        dst_sess="$CUR_SESSION_NAME"; dst_conv="$2"
    elif [[ $# -eq 4 ]]; then
        src_sess=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
        src_conv=$(get_conv_name "$src_sess" "$2") || { printf "%s[ERROR] Conversation '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$2" "${COLOR_RESET}"; return 1; }
        dst_sess=$(get_sess_name "$3") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$3" "${COLOR_RESET}"; return 1; }
        dst_conv="$4"
    else
        printf "%s[ERROR] Usage: /session conv cp <new> | <old> <new> | <s1> <c1> <s2> <c2>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -z "$src_sess" || -z "$src_conv" ]]; then
        printf "%s[ERROR] No current conversation. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -n "${CONVS["$dst_sess|$dst_conv"]+x}" ]]; then
        printf "%s[ERROR] Conversation '%s' already exists in '%s'. [/ERROR]%s\n" "${COLOR_DIM}" "$dst_conv" "$dst_sess" "${COLOR_RESET}"; return 1
    fi
    if ! is_valid_name "$dst_conv"; then
        printf "%s[ERROR] Invalid conv name. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    br_sync_msgs
    local src_key="${src_sess}|${src_conv}"
    local dst_key="${dst_sess}|${dst_conv}"
    CONVS[$dst_key]=$(gen_uuid)
    MSGS[$dst_key]="${MSGS[$src_key]}"
    br_update_headers
    printf "%s[INFO] Copied conversation '%s' (session '%s') -> '%s' (session '%s'). [/INFO]%s\n" "${COLOR_DIM}" "$src_conv" "$src_sess" "$dst_conv" "$dst_sess" "${COLOR_RESET}"
}

br_conv_resume() {
    local sess name
    if [[ $# -eq 1 ]]; then
        sess="$CUR_SESSION_NAME"; name=$(get_conv_name "$sess" "$1") || { printf "%s[ERROR] Conversation '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
    elif [[ $# -eq 2 ]]; then
        sess=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
        name=$(get_conv_name "$sess" "$2") || { printf "%s[ERROR] Conversation '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$2" "${COLOR_RESET}"; return 1; }
    else
        printf "%s[ERROR] Usage: /session conv resume <conv> | <sess> <conv>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -z "$sess" ]]; then
        printf "%s[ERROR] No current session. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    br_sync_msgs
    CUR_SESSION_NAME="$sess"; CUR_CONV_NAME="$name"
    br_load_msgs
    br_update_headers
    printf "%s[INFO] Resumed conversation '%s' in session '%s' (%d messages). [/INFO]%s\n" "${COLOR_DIM}" "$name" "$sess" "$(count_msgs_in_conv "$sess" "$name")" "${COLOR_RESET}"
}

br_conv_clear() {
    local sess name
    if [[ $# -eq 0 ]]; then
        sess="$CUR_SESSION_NAME"; name="$CUR_CONV_NAME"
    elif [[ $# -eq 1 ]]; then
        sess="$CUR_SESSION_NAME"; name=$(get_conv_name "$sess" "$1") || { printf "%s[ERROR] Conversation '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
    elif [[ $# -eq 2 ]]; then
        sess=$(get_sess_name "$1") || { printf "%s[ERROR] Session '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
        name=$(get_conv_name "$sess" "$2") || { printf "%s[ERROR] Conversation '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$2" "${COLOR_RESET}"; return 1; }
    else
        printf "%s[ERROR] Usage: /session conv clear [sess] [conv]. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -z "$sess" ]]; then
        printf "%s[ERROR] No current session. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ -z "$name" ]]; then
        printf "%s[ERROR] No current conversation. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    MSGS["${sess}|${name}"]="[]"
    if [[ "$sess" == "$CUR_SESSION_NAME" && "$name" == "$CUR_CONV_NAME" ]]; then
        CONVERSATION=()
    fi
    printf "%s[INFO] Cleared messages of conversation '%s' in session '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$name" "$sess" "${COLOR_RESET}"
}

br_conv_save() {
    local sess="$CUR_SESSION_NAME"
    if [[ -z "$sess" ]]; then
        printf "%s[ERROR] No current session. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ $# -eq 1 ]]; then
        local file="$1"
        br_sync_msgs
        br_dump_session_json "$sess" | jq . > "$file"
        printf "%s[INFO] Saved all conversations of session '%s' to '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$sess" "$file" "${COLOR_RESET}"
    elif [[ $# -eq 2 ]]; then
        local name file="$2"
        name=$(get_conv_name "$sess" "$1") || { printf "%s[ERROR] Conversation '%s' does not exist. [/ERROR]%s\n" "${COLOR_DIM}" "$1" "${COLOR_RESET}"; return 1; }
        br_sync_msgs
        local key="${sess}|${name}"
        jq -n --arg name "$name" --arg id "${CONVS[$key]}" --argjson msgs "${MSGS[$key]:-[]}" \
            '{name: $name, id: $id, messages: $msgs}' | jq . > "$file"
        printf "%s[INFO] Saved conversation '%s' (session '%s') to '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$name" "$sess" "$file" "${COLOR_RESET}"
    else
        printf "%s[ERROR] Usage: /session conv save <file> | <conv> <file>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
}

br_conv_load() {
    local sess="$CUR_SESSION_NAME"
    if [[ -z "$sess" ]]; then
        printf "%s[ERROR] No current session. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
    if [[ $# -eq 1 ]]; then
        local file="$1"
        [[ ! -f "$file" ]] && { printf "%s[ERROR] File not found: %s. [/ERROR]%s\n" "${COLOR_DIM}" "$file" "${COLOR_RESET}"; return 1; }
        br_sync_msgs
        local data=$(cat "$file")
        local count=0
        if [[ "$(printf '%s' "$data" | jq -r 'has("conversations")')" == "true" ]]; then
            local n=$(printf '%s' "$data" | jq '.conversations | length')
            for ((j=0; j<n; j++)); do
                local cname=$(printf '%s' "$data" | jq -r ".conversations[$j].name")
                local cid=$(printf '%s' "$data" | jq -r ".conversations[$j].id")
                local cmsgs=$(printf '%s' "$data" | jq -c ".conversations[$j].messages")
                CONVS["${sess}|${cname}"]="$cid"
                MSGS["${sess}|${cname}"]="$cmsgs"
                ((count++))
            done
        elif [[ "$(printf '%s' "$data" | jq -r 'has("messages")')" == "true" ]]; then
            local cname=$(printf '%s' "$data" | jq -r '.name')
            CONVS["${sess}|${cname}"]=$(printf '%s' "$data" | jq -r '.id')
            MSGS["${sess}|${cname}"]=$(printf '%s' "$data" | jq -c '.messages')
            count=1
        else
            printf "%s[ERROR] Unrecognized file format. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
        fi
        br_sync_msgs; br_load_msgs; br_update_headers
        printf "%s[INFO] Loaded %d conversation(s) into session '%s' from '%s'. Same-name convs replaced. [/INFO]%s\n" "${COLOR_DIM}" "$count" "$sess" "$file" "${COLOR_RESET}"
    elif [[ $# -eq 2 ]]; then
        local file="$1" name="$2"
        [[ ! -f "$file" ]] && { printf "%s[ERROR] File not found: %s. [/ERROR]%s\n" "${COLOR_DIM}" "$file" "${COLOR_RESET}"; return 1; }
        if ! is_valid_name "$name"; then
            printf "%s[ERROR] Invalid conv name. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
        fi
        local data=$(cat "$file")
        local cid cmsgs
        if [[ "$(printf '%s' "$data" | jq -r 'has("messages")')" == "true" ]]; then
            cid=$(printf '%s' "$data" | jq -r '.id')
            cmsgs=$(printf '%s' "$data" | jq -c '.messages')
        else
            local n=$(printf '%s' "$data" | jq '.conversations | length')
            if [[ "$n" -ge 1 ]]; then
                cid=$(printf '%s' "$data" | jq -r ".conversations[0].id")
                cmsgs=$(printf '%s' "$data" | jq -c ".conversations[0].messages")
            else
                printf "%s[ERROR] No conversations in file. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
            fi
        fi
        CONVS["${sess}|${name}"]="$cid"
        MSGS["${sess}|${name}"]="$cmsgs"
        br_sync_msgs; br_load_msgs; br_update_headers
        printf "%s[INFO] Loaded conversation into '%s' (session '%s') from '%s'. [/INFO]%s\n" "${COLOR_DIM}" "$name" "$sess" "$file" "${COLOR_RESET}"
    else
        printf "%s[ERROR] Usage: /session conv load <file> | <file> <conv>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; return 1
    fi
}

# Dispatchers

br_handle_session_conv() {
    local sub="$1"; shift || true
    case "$sub" in
        ls)     br_conv_ls "$@" ;;
        new)    br_conv_new "$@" ;;
        rm)     br_conv_rm "$@" ;;
        mv)     br_conv_mv "$@" ;;
        cp)     br_conv_cp "$@" ;;
        resume) br_conv_resume "$@" ;;
        save)   br_conv_save "$@" ;;
        load)   br_conv_load "$@" ;;
        clear)  br_conv_clear "$@" ;;
        "")     printf "%s[INFO] Usage: /session conv <ls|new|rm|mv|cp|resume|save|load|clear> ... [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}" ;;
        *)      printf "%s[ERROR] Unknown /session conv sub-command: %s. [/ERROR]%s\n" "${COLOR_DIM}" "$sub" "${COLOR_RESET}" ;;
    esac
}

br_handle_session() {
    local sub="$1"; shift || true
    case "$sub" in
        ls)     br_session_ls "$@" ;;
        new)    br_session_new "$@" ;;
        clear)  br_session_clear "$@" ;;
        mv)     br_session_mv "$@" ;;
        cp)     br_session_cp "$@" ;;
        rm)     br_session_rm "$@" ;;
        dump)   br_session_dump "$@" ;;
        resume) br_session_resume "$@" ;;
        save)   br_session_save "$@" ;;
        load)   br_session_load "$@" ;;
        conv)   br_handle_session_conv "$@" ;;
        "")     printf "%s[INFO] Usage: /session <ls|new|clear|mv|cp|rm|dump|resume|save|load|conv> ... [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}" ;;
        *)      printf "%s[ERROR] Unknown /session sub-command: %s. [/ERROR]%s\n" "${COLOR_DIM}" "$sub" "${COLOR_RESET}" ;;
    esac
}

# /conv is an independent command limited to current session
br_handle_conv() {
    local sub="$1"; shift || true
    case "$sub" in
        ls)     br_conv_ls "$CUR_SESSION_NAME" ;;
        new)    br_conv_new "$@" ;;
        rm)
            if [[ $# -eq 0 ]]; then br_conv_rm
            else br_conv_rm "$CUR_SESSION_NAME" "$1"; fi ;;
        mv)
            if [[ $# -eq 1 || $# -eq 2 ]]; then br_conv_mv "$@"
            else printf "%s[ERROR] Usage: /conv mv <new> | <old> <new>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; fi ;;
        cp)
            if [[ $# -eq 1 || $# -eq 2 ]]; then br_conv_cp "$@"
            else printf "%s[ERROR] Usage: /conv cp <new> | <old> <new>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; fi ;;
        resume)
            if [[ $# -eq 1 ]]; then br_conv_resume "$CUR_SESSION_NAME" "$1"
            else printf "%s[ERROR] Usage: /conv resume <name>. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"; fi ;;
        save)   br_conv_save "$@" ;;
        load)   br_conv_load "$@" ;;
        clear)
            if [[ $# -eq 0 ]]; then br_conv_clear
            else br_conv_clear "$CUR_SESSION_NAME" "$1"; fi ;;
        "")     printf "%s[INFO] Usage: /conv <ls|new|rm|mv|cp|resume|save|load|clear> ... [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}" ;;
        *)      printf "%s[ERROR] Unknown /conv sub-command: %s. [/ERROR]%s\n" "${COLOR_DIM}" "$sub" "${COLOR_RESET}" ;;
    esac
}

# Tool implementations (unchanged)

read_file() {
    local args_json="$1"
    local path start_line end_line append_loc
    path=$(printf '%s' "$args_json" | jq -r '.path // empty')
    if [[ -z "$path" ]]; then echo "Error: 'path' is required for read_file"; return 1; fi
    start_line=$(printf '%s' "$args_json" | jq -r '.start_line // 1')
    end_line=$(printf '%s' "$args_json" | jq -r '.end_line // empty')
    append_loc=$(printf '%s' "$args_json" | jq -r '.append_loc // false')
    if [[ ! -f "$path" ]]; then echo "Error: File not found: $path"; return 1; fi
    local total_lines
    total_lines=$(wc -l < "$path")
    if [[ -s "$path" ]] && [[ "$(tail -c 1 "$path" | wc -l)" -eq 0 ]]; then
        total_lines=$((total_lines + 1))
    fi
    if [[ -z "$end_line" ]] || [[ "$end_line" -gt "$total_lines" ]]; then end_line=$total_lines; fi
    if [[ "$start_line" -lt 1 ]]; then start_line=1; fi
    if [[ "$start_line" -gt "$end_line" ]]; then echo ""; return 0; fi
    local content
    content=$(sed -n "${start_line},${end_line}p" "$path")
    if [[ "$append_loc" == "true" ]]; then
        local i=$start_line
        if [[ -n "$content" ]]; then
            while IFS= read -r line; do echo "${i}-> ${line}"; ((i++)); done <<< "$content"
        fi
    else
        echo "$content"
    fi
}

write_file() {
    local args_json="$1"
    local path content
    path=$(printf '%s' "$args_json" | jq -r '.path // empty')
    if [[ -z "$path" ]]; then echo "Error: 'path' is required for write_file"; return 1; fi
    content=$(printf '%s' "$args_json" | jq -r '.content // empty')
    local dir
    dir=$(dirname "$path")
    if [[ ! -d "$dir" ]]; then mkdir -p "$dir" || { echo "Error: Failed to create directory $dir"; return 1; }; fi
    printf "%s" "$content" > "$path" || { echo "Error: Failed to write to $path"; return 1; }
    echo "Successfully wrote to $path"
}

edit_file() {
    local args_json="$1"
    local path changes
    path=$(printf '%s' "$args_json" | jq -r '.path // empty')
    if [[ -z "$path" ]]; then echo "Error: 'path' is required for edit_file"; return 1; fi
    changes=$(printf '%s' "$args_json" | jq -c '.changes // empty')
    if [[ -z "$changes" || "$changes" == "null" ]]; then echo "Error: 'changes' is required for edit_file"; return 1; fi
    if [[ ! -f "$path" ]]; then echo "Error: File not found: $path"; return 1; fi
    mapfile -t lines < "$path"
    local num_changes
    num_changes=$(printf '%s' "$changes" | jq 'length')
    local sorted_changes
    sorted_changes=$(printf '%s' "$changes" | jq -c 'sort_by(-.line_start)')
    for ((c=0; c<num_changes; c++)); do
        local mode line_start line_end content
        mode=$(printf '%s' "$sorted_changes" | jq -r ".[$c].mode")
        line_start=$(printf '%s' "$sorted_changes" | jq -r ".[$c].line_start")
        line_end=$(printf '%s' "$sorted_changes" | jq -r ".[$c].line_end")
        content=$(printf '%s' "$sorted_changes" | jq -r ".[$c].content")
        if [[ "$line_start" -eq -1 ]]; then
            if [[ "$mode" == "append" ]]; then
                local -a new_lines; mapfile -t new_lines <<< "$content"; lines+=("${new_lines[@]}")
            fi
            continue
        fi
        local idx_start=$((line_start - 1)) idx_end=$((line_end - 1)) total_lines=${#lines[@]}
        if [[ "$idx_start" -lt 0 ]]; then idx_start=0; fi
        if [[ "$idx_end" -ge "$total_lines" ]]; then idx_end=$((total_lines - 1)); fi
        case "$mode" in
            "replace")
                local -a new_lines; mapfile -t new_lines <<< "$content"
                local -a temp=("${lines[@]:0:idx_start}" "${new_lines[@]}" "${lines[@]:idx_end+1}")
                lines=("${temp[@]}") ;;
            "delete")
                local -a temp=("${lines[@]:0:idx_start}" "${lines[@]:idx_end+1}")
                lines=("${temp[@]}") ;;
            "append")
                local -a new_lines; mapfile -t new_lines <<< "$content"
                local insert_idx=$((idx_end + 1))
                local -a temp=("${lines[@]:0:insert_idx}" "${new_lines[@]}" "${lines[@]:insert_idx}")
                lines=("${temp[@]}") ;;
            *) echo "Error: Unknown mode $mode"; return 1 ;;
        esac
    done
    if [[ ${#lines[@]} -eq 0 ]]; then > "$path"; else local IFS=$'\n'; echo "${lines[*]}" > "$path"; fi
    echo "Successfully edited $path"
}

exec_shell_command() {
    local args_json="$1"
    local command timeout max_output_size
    command=$(printf '%s' "$args_json" | jq -r '.command // empty')
    if [[ -z "$command" ]]; then echo "Error: 'command' is required for exec_shell_command"; return 1; fi
    timeout=$(printf '%s' "$args_json" | jq -r '.timeout // 10')
    max_output_size=$(printf '%s' "$args_json" | jq -r '.max_output_size // 16384')
    if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then timeout=10; fi
    if [[ "$timeout" -gt 60 ]]; then timeout=60; fi
    if ! [[ "$max_output_size" =~ ^[0-9]+$ ]]; then max_output_size=16384; fi
    local output
    output=$(timeout "$timeout" bash -c "$command" 2>&1)
    local exit_code=$?
    if [[ $exit_code -eq 124 ]]; then echo "Error: Command timed out after ${timeout} seconds."; return 1; fi
    if [[ ${#output} -gt $max_output_size ]]; then output="${output:0:$max_output_size}... [truncated]"; fi
    echo "$output"
}

agent_skills_system() {
    cat <<'EOF'
# Agent Skills System
Skills are self-contained packages that give you specialized capabilities. They follow progressive disclosure - only load what you need for the current task.

## Strict Rules (Must Follow)
Always use the dedicated skill tools to interact with skills:
- `list_skills` - list all available skills
- `load_skill` - load a skill
- `list_skill_files` - list all skill's files
- `read_skill_resource` - read a file from a skill's `references/`, `scripts/`, or `assets/` directory
- `exec_skill_script` - execute skill's script

## Directory Structure
Each skill lives in `.agents/skills/<skill_name>/` and contains:
- `SKILL.md` - Main file with instructions (required)
- `references/` - Documents you can read when needed using `read_skill_resource`
- `scripts/` - Scripts you can run using `exec_skill_script`
- `assets/` - Templates and other files - never read or run them

## How to Work With Skills
1. Call `list_skills` to discover skills.
2. Call `load_skill(skill_name)` when a skill matches the task.
3. Call `list_skill_files(skill_name)` to explore the skill's contents.
4. Read files from `references/` using `read_skill_resource` only when instructed by `SKILL.md`.
5. Run scripts from `scripts/` using `exec_skill_script` only if `.agents/skills/<skill_name>/scripts/` exist.
6. Do not read anything from `assets/`.
7. Do not read anything from `scripts/`.
8. Always follow the instructions in `.agents/skills/<skill_name>/SKILL.md`.
EOF
}

list_skills() {
    local skills_dir=".agents/skills"
    if [[ ! -d "$skills_dir" ]]; then echo "[]"; return 0; fi
    local -a skill_jsons=()
    while IFS= read -r -d '' skill_file; do
        local skill_dir skill_name
        skill_dir=$(dirname "$skill_file")
        skill_name=$(basename "$skill_dir")
        local frontmatter
        frontmatter=$(awk '/^---[[:space:]]*$/ { if (in_fm) exit; in_fm = 1; next } in_fm { print }' "$skill_file" 2>/dev/null)
        local name desc
        name=$(printf '%s' "$frontmatter" | grep '^name:' | head -1 | sed 's/^name:[[:space:]]*//' | sed "s/^['\"]//;s/['\"]$//" | tr -d '\r')
        desc=$(printf '%s' "$frontmatter" | grep '^description:' | head -1 | sed 's/^description:[[:space:]]*//' | sed "s/^['\"]//;s/['\"]$//" | tr -d '\r')
        [[ -z "$name" ]] && name="$skill_name"
        [[ -z "$desc" ]] && desc="(no description)"
        skill_jsons+=($(jq -c -n --arg name "$name" --arg desc "$desc" --arg path "$skill_dir" '{"name": $name, "description": $desc, "skill_path": $path}'))
    done < <(find "$skills_dir" -mindepth 2 -name "SKILL.md" -print0 2>/dev/null)
    if [[ ${#skill_jsons[@]} -eq 0 ]]; then echo "[]"; else printf '%s\n' "${skill_jsons[@]}" | jq -s '.'; fi
}

list_skill_files() {
    local args_json="$1"
    local skill_name
    skill_name=$(printf '%s' "$args_json" | jq -r '.skill_name // empty')
    if [[ -z "$skill_name" ]]; then echo "Error: 'skill_name' is required for list_skill_files"; return 1; fi
    if [[ "$skill_name" == *..* ]]; then echo "Error: Path traversal is not allowed"; return 1; fi
    local skill_dir=".agents/skills/$skill_name"
    if [[ ! -d "$skill_dir" ]]; then echo "Error: Skill directory not found: $skill_name (looked for $skill_dir)"; return 1; fi
    find "$skill_dir" -type f | sort
}

load_skill() {
    local args_json="$1"
    local skill_name
    skill_name=$(printf '%s' "$args_json" | jq -r '.skill_name // empty')
    if [[ -z "$skill_name" ]]; then echo "Error: 'skill_name' is required for load_skill"; return 1; fi
    if [[ "$skill_name" == *..* ]]; then echo "Error: Path traversal is not allowed"; return 1; fi
    local skill_path=".agents/skills/$skill_name/SKILL.md"
    if [[ ! -f "$skill_path" ]]; then echo "Error: Skill not found: $skill_name (looked for $skill_path)"; return 1; fi
    cat "$skill_path"
}

read_skill_resource() {
    local args_json="$1"
    local skill_name resource_path
    skill_name=$(printf '%s' "$args_json" | jq -r '.skill_name // empty')
    resource_path=$(printf '%s' "$args_json" | jq -r '.resource_path // empty')
    if [[ -z "$skill_name" ]]; then echo "Error: 'skill_name' is required for read_skill_resource"; return 1; fi
    if [[ -z "$resource_path" ]]; then echo "Error: 'resource_path' is required for read_skill_resource"; return 1; fi
    if [[ "$skill_name" == *..* || "$resource_path" == *..* ]]; then echo "Error: Path traversal is not allowed"; return 1; fi
    local skill_dir=".agents/skills/$skill_name"
    local full_path="$skill_dir/$resource_path"
    if [[ -d "$skill_dir" ]]; then
        local resolved_path resolved_skill_dir
        resolved_path=$(realpath -m "$full_path" 2>/dev/null)
        resolved_skill_dir=$(realpath -m "$skill_dir" 2>/dev/null)
        if [[ -n "$resolved_path" && -n "$resolved_skill_dir" ]]; then
            if [[ "$resolved_path" != "$resolved_skill_dir"* ]]; then
                echo "Error: Resource path must be within the skill directory"; return 1
            fi
        fi
    fi
    if [[ ! -f "$full_path" ]]; then echo "Error: Resource not found: $resource_path in skill $skill_name (looked for $full_path)"; return 1; fi
    cat "$full_path"
}

exec_skill_script() {
    local args_json="$1"
    local skill_name script_name
    skill_name=$(printf '%s' "$args_json" | jq -r '.skill_name // empty')
    script_name=$(printf '%s' "$args_json" | jq -r '.script_name // empty')
    if [[ -z "$skill_name" ]]; then echo "Error: 'skill_name' is required for exec_skill_script"; return 1; fi
    if [[ -z "$script_name" ]]; then echo "Error: 'script_name' is required for exec_skill_script"; return 1; fi
    if [[ "$skill_name" == *..* || "$script_name" == *..* ]]; then echo "Error: Path traversal is not allowed"; return 1; fi
    local skill_dir=".agents/skills/$skill_name"
    local scripts_dir="$skill_dir/scripts"
    local full_path="$scripts_dir/$script_name"
    if [[ -d "$scripts_dir" ]]; then
        local resolved_path resolved_scripts_dir
        resolved_path=$(realpath -m "$full_path" 2>/dev/null)
        resolved_scripts_dir=$(realpath -m "$scripts_dir" 2>/dev/null)
        if [[ -n "$resolved_path" && -n "$resolved_scripts_dir" ]]; then
            if [[ "$resolved_path" != "$resolved_scripts_dir"* ]]; then
                echo "Error: Script path must be within the skill's scripts/ directory"; return 1
            fi
        fi
    fi
    if [[ ! -f "$full_path" ]]; then echo "Error: Script not found: $script_name in skill $skill_name (looked for $full_path)"; return 1; fi
    if [[ ! -x "$full_path" ]]; then chmod +x "$full_path" 2>/dev/null; fi
    local -a cmd_args=("$full_path")
    local num_args
    num_args=$(printf '%s' "$args_json" | jq '(.args // []) | length')
    for ((i=0; i<num_args; i++)); do
        cmd_args+=("$(printf '%s' "$args_json" | jq -r ".args[$i]")")
    done
    local timeout=60 max_output_size=65536
    local output
    output=$(timeout "$timeout" "${cmd_args[@]}" 2>&1)
    local exit_code=$?
    if [[ $exit_code -eq 124 ]]; then echo "Error: Script timed out after ${timeout} seconds."; return 1; fi
    if [[ ${#output} -gt $max_output_size ]]; then output="${output:0:$max_output_size}... [truncated]"; fi
    echo "$output"
}

execute_tool() {
    local tool_name="$1" args_json="$2"
    local jq_err
    if ! jq_err=$(printf '%s' "$args_json" | jq empty 2>&1); then
        echo "Error: Invalid JSON arguments: $jq_err"; return 1
    fi
    case "$tool_name" in
        "read_file")           read_file "$args_json" ;;
        "write_file")          write_file "$args_json" ;;
        "edit_file")           edit_file "$args_json" ;;
        "exec_shell_command")  exec_shell_command "$args_json" ;;
        "agent_skills_system") agent_skills_system ;;
        "list_skills")         list_skills ;;
        "list_skill_files")    list_skill_files "$args_json" ;;
        "load_skill")          load_skill "$args_json" ;;
        "read_skill_resource") read_skill_resource "$args_json" ;;
        "exec_skill_script")   exec_skill_script "$args_json" ;;
        *) echo "Error: Unknown tool $tool_name"; return 1 ;;
    esac
}

# Compact the conversation history
compact_conversation() {
    if [[ ${#CONVERSATION[@]} -eq 0 ]]; then
        printf "%s[INFO] Conversation is empty, nothing to compact. [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
        return 0
    fi
    local conversation_text="" found=0
    for msg in "${CONVERSATION[@]}"; do
        local role content
        role=$(printf '%s' "$msg" | jq -r '.role // empty')
        content=$(printf '%s' "$msg" | jq -r '.content // empty')
        if [[ "$role" == "user" || "$role" == "assistant" ]]; then
            conversation_text+="${role}: ${content}"$'\n'; found=1
        fi
    done
    if [[ "$found" -eq 0 ]]; then
        printf "%s[INFO] No user/assistant messages to compact. [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
        return 0
    fi
    local summary_prompt
    summary_prompt="Summarize the conversation below concisely.
Focus on: main goal, skill names loaded and used, what was accomplished, and current status.

Conversation:
 ${conversation_text}

Summary:"
    local summary_messages_json
    summary_messages_json=$(printf '%s' "$summary_prompt" | jq -Rs '[{role: "user", content: .}]')
    local request_body
    request_body=$(jq -n --arg model "$BR_MODEL_NAME" --argjson stream "false" \
        '{model: $model, messages: input, stream: $stream}' <<< "$summary_messages_json")
    local -a curl_args=()
    curl_args+=("-H" "Content-Type: application/json")
    curl_args+=("-H" "X-Session-Affinity: $SESSION_AFFINITY")
    curl_args+=("-H" "X-Conversation-Id: $CONVERSATION_ID")
    if [[ -n "$BR_API_KEY" ]]; then curl_args+=("-H" "Authorization: Bearer $BR_API_KEY"); fi
    printf "%s[INFO] Compacting conversation... [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
    local response
    response=$(curl -s --max-time "$BR_TIMEOUT" "$BR_BASE_URL/chat/completions" "${curl_args[@]}" -d "$request_body")
    if [[ -z "$response" ]]; then echo "Error: Empty response from LLM server during compaction."; return 1; fi
    local api_error
    api_error=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)
    if [[ -n "$api_error" ]]; then echo "Error: $api_error"; return 1; fi
    local summary
    summary=$(printf '%s' "$response" | jq -j '.choices[0].message.content // empty' 2>/dev/null; printf x)
    summary="${summary%x}"
    if [[ -z "$summary" ]]; then echo "Error: Empty summary received from LLM."; return 1; fi
    local summary_user_content="[SUMMARY]
 ${summary}
[/SUMMARY]"
    local summary_user_msg
    summary_user_msg=$(printf '%s' "$summary_user_content" | jq -Rs '{role: "user", content: .}')
    local reasoning_text="The conversation history was compressed into a summary. I now understand the previous context."
    local assistant_content="Got it. Continuing from the summary."
    local summary_assistant_msg
    summary_assistant_msg=$(printf '%s' "$assistant_content" | jq -Rs --arg rc "$reasoning_text" '{role: "assistant", reasoning_content: $rc, content: .}')
    CONVERSATION=("$summary_user_msg" "$summary_assistant_msg")
    br_sync_msgs
    printf "%s[INFO] Conversation compacted. [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
    printf "%sSummary:%s %s\n\n" "${COLOR_DIM}" "${COLOR_RESET}" "$summary"
}

# Check for standalone ESC key to interrupt generation
check_esc_interrupt() {
    local timeout="${1:-0.001}" key k2 k3
    if ! IFS= read -t "$timeout" -n 1 key 2>/dev/null; then return 1; fi
    if [[ "$key" != $'\e' ]]; then return 1; fi
    if IFS= read -t 0.01 -n 1 k2 2>/dev/null; then
        if [[ "$k2" == "[" || "$k2" == "O" ]]; then
            IFS= read -t 0.01 -n 1 k3 2>/dev/null
        fi
        return 1
    else
        return 0
    fi
}

oai_make_request() {
    local user_message="$1"

    # Ensure valid session/conversation before sending
    br_update_headers
    if [[ -z "$SESSION_AFFINITY" || -z "$CONVERSATION_ID" ]]; then
        printf "%s[ERROR] No active session/conversation. Use /session conv new or /session conv resume. [/ERROR]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
        return 1
    fi

    # Append user message to conversation history
    local user_msg_json
    user_msg_json=$(printf '%s' "$user_message" | jq -Rs '{role: "user", content: .}')
    CONVERSATION+=("$user_msg_json")

    local tools_json
    tools_json=$(get_tools_json)

    while true; do
        local messages_json="[]"
        if [[ ${#CONVERSATION[@]} -gt 0 ]]; then
            messages_json=$(printf '%s\n' "${CONVERSATION[@]}" | jq -s '.')
        fi
        local request_body
        request_body=$(jq -n \
            --arg model "$BR_MODEL_NAME" \
            --argjson stream "$BR_MODEL_STREAM" \
            --argjson tools "$tools_json" \
            '{model: $model, messages: input, stream: $stream, tools: $tools}' \
            <<< "$messages_json")

        local -a curl_args=()
        curl_args+=("-H" "Content-Type: application/json")
        curl_args+=("-H" "X-Session-Affinity: $SESSION_AFFINITY")
        curl_args+=("-H" "X-Conversation-Id: $CONVERSATION_ID")
        if [[ -n "$BR_API_KEY" ]]; then
            curl_args+=("-H" "Authorization: Bearer $BR_API_KEY")
        fi

        local request_successful=false
        while [[ "$request_successful" == "false" ]]; do
            local reasoning_content="" reasoning_started=false response_content=""
            local has_tool_calls=false
            local -a current_tool_calls=()
            local api_error="" curl_exit_code=0 http_code="000" err_detail=""
            local INTERRUPTED=false

            if [[ "$BR_MODEL_STREAM" == "true" ]]; then
                local tmp_pipe=$(mktemp -u)
                mkfifo "$tmp_pipe"
                curl -s -N -w "\n%{http_code}" --max-time "$BR_TIMEOUT" --speed-time 30 --speed-limit 1 \
                    "$BR_BASE_URL/chat/completions" "${curl_args[@]}" -d "$request_body" > "$tmp_pipe" &
                local CURL_PID=$!
                local DONE_RECEIVED=false
                exec 3< "$tmp_pipe"
                local sse_buffer=""
                while true; do
                    if check_esc_interrupt 0.001; then INTERRUPTED=true; break; fi
                    local partial=""
                    if IFS= read -t 0.1 -r partial <&3; then
                        sse_buffer+="$partial"$'\n'
                    elif [[ -n "$partial" ]]; then
                        sse_buffer+="$partial"; continue
                    else
                        if ! kill -0 "$CURL_PID" 2>/dev/null; then
                            if [[ -z "$sse_buffer" ]]; then break; fi
                            sse_buffer+=$'\n'
                        else
                            continue
                        fi
                    fi
                    while [[ "$sse_buffer" == *$'\n'* ]]; do
                        local line="${sse_buffer%%$'\n'*}"
                        sse_buffer="${sse_buffer#*$'\n'}"
                        line="${line%$'\r'}"
                        [[ -z "$line" ]] && continue
                        if [[ "$line" == "data: [DONE]" ]]; then DONE_RECEIVED=true; break; fi
                        if [[ "$line" =~ ^data:\ (.+)$ ]]; then
                            local json_data="${BASH_REMATCH[1]}"
                            local err_msg
                            err_msg=$(printf '%s' "$json_data" | jq -r '.error.message // empty' 2>/dev/null)
                            if [[ -n "$err_msg" ]]; then api_error="$err_msg"; break; fi
                            local reasoning_delta
                            reasoning_delta=$(printf '%s' "$json_data" | jq -j '.choices[0].delta.reasoning_content // empty' 2>/dev/null; printf x)
                            reasoning_delta="${reasoning_delta%x}"
                            if [[ -n "$reasoning_delta" ]]; then
                                if [[ "$reasoning_started" == "false" ]]; then
                                    printf "%s[THINK]" "${COLOR_DIM}"; reasoning_started=true
                                fi
                                printf "%s" "$reasoning_delta"
                                reasoning_content+="$reasoning_delta"
                            fi
                            local content
                            content=$(printf '%s' "$json_data" | jq -j '.choices[0].delta.content // empty' 2>/dev/null; printf x)
                            content="${content%x}"
                            if [[ -n "$content" ]]; then
                                if [[ "$reasoning_started" == "true" ]]; then
                                    printf "[/THINK]%s\n\n" "${COLOR_RESET}"; reasoning_started=false
                                    while [[ "$content" =~ ^$'\n' ]]; do content="${content:1}"; done
                                fi
                                if [[ -n "$content" ]]; then printf "%s" "$content"; response_content+="$content"; fi
                            fi
                            local tc_count
                            tc_count=$(printf '%s' "$json_data" | jq -r '(.choices[0].delta.tool_calls // []) | length' 2>/dev/null)
                            if [[ "$tc_count" =~ ^[0-9]+$ ]] && [[ "$tc_count" -gt 0 ]]; then
                                if [[ "$reasoning_started" == "true" ]]; then
                                    printf "[/THINK]%s\n\n" "${COLOR_RESET}"; reasoning_started=false
                                fi
                                has_tool_calls=true
                                for ((i=0; i<tc_count; i++)); do
                                    local idx
                                    idx=$(printf '%s' "$json_data" | jq -r ".choices[0].delta.tool_calls[$i].index" 2>/dev/null)
                                    if [[ -z "$idx" || "$idx" == "null" ]]; then continue; fi
                                    if [[ -z "${current_tool_calls[$idx]}" ]]; then current_tool_calls[$idx]="{}"; fi
                                    local delta_tc merged_tc
                                    delta_tc=$(printf '%s' "$json_data" | jq -c ".choices[0].delta.tool_calls[$i]" 2>/dev/null)
                                    merged_tc=$(printf '%s\n%s\n' "${current_tool_calls[$idx]}" "$delta_tc" | jq -s '
                                        .[0] as $base | .[1] as $delta |
                                        $base |
                                        if $delta.id then .id = $delta.id else . end |
                                        if $delta.type then .type = $delta.type else . end |
                                        if $delta.function then
                                            .function = ((.function // {}) |
                                                if $delta.function.name then .name = $delta.function.name else . end |
                                                if $delta.function.arguments then .arguments = ((.arguments // "") + $delta.function.arguments) else . end)
                                        else . end' 2>/dev/null)
                                    if [[ -n "$merged_tc" ]]; then current_tool_calls[$idx]="$merged_tc"; fi
                                done
                            fi
                        elif [[ "$line" =~ ^[0-9]{3}$ ]]; then
                            http_code="$line"
                        fi
                    done
                    if [[ "$DONE_RECEIVED" == "true" || -n "$api_error" ]]; then break; fi
                done
                exec 3<&-
                rm -f "$tmp_pipe"
                if [[ "$INTERRUPTED" == "true" ]]; then
                    kill "$CURL_PID" 2>/dev/null; wait "$CURL_PID" 2>/dev/null
                    printf "\n%s[INTERRUPTED]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
                    unset 'CONVERSATION[-1]'; br_sync_msgs; return 0
                fi
                if [[ "$DONE_RECEIVED" == "true" || -n "$api_error" ]]; then
                    kill "$CURL_PID" 2>/dev/null; wait "$CURL_PID" 2>/dev/null; curl_exit_code=0
                else
                    wait "$CURL_PID" 2>/dev/null; curl_exit_code=$?
                fi
            else
                # Non-Streaming Mode
                local response_file=$(mktemp)
                curl -s -w "\n%{http_code}" --max-time "$BR_TIMEOUT" \
                    "$BR_BASE_URL/chat/completions" "${curl_args[@]}" -d "$request_body" > "$response_file" &
                local CURL_PID=$!
                while kill -0 "$CURL_PID" 2>/dev/null; do
                    if check_esc_interrupt 0.1; then INTERRUPTED=true; kill "$CURL_PID" 2>/dev/null; break; fi
                done
                wait "$CURL_PID" 2>/dev/null; curl_exit_code=$?
                if [[ "$INTERRUPTED" == "true" ]]; then
                    rm -f "$response_file"
                    printf "\n%s[INTERRUPTED]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
                    unset 'CONVERSATION[-1]'; br_sync_msgs; return 0
                fi
                local response_raw
                response_raw=$(cat "$response_file"); rm -f "$response_file"
                http_code=$(printf '%s' "$response_raw" | tail -n 1)
                local response
                response=$(printf '%s' "$response_raw" | sed '$d')
                if [[ -n "$response" ]]; then
                    local error_msg
                    error_msg=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)
                    if [[ -n "$error_msg" ]]; then api_error="$error_msg"
                    else
                        local message_json
                        message_json=$(printf '%s' "$response" | jq -c '.choices[0].message // empty' 2>/dev/null)
                        if [[ -n "$message_json" ]]; then
                            response_content=$(printf '%s' "$message_json" | jq -j '.content // empty' 2>/dev/null; printf x); response_content="${response_content%x}"
                            reasoning_content=$(printf '%s' "$message_json" | jq -j '.reasoning_content // empty' 2>/dev/null; printf x); reasoning_content="${reasoning_content%x}"
                            local tc_count
                            tc_count=$(printf '%s' "$message_json" | jq '(.tool_calls // []) | length' 2>/dev/null)
                            if [[ "$tc_count" =~ ^[0-9]+$ ]] && [[ "$tc_count" -gt 0 ]]; then
                                has_tool_calls=true
                                for ((i=0; i<tc_count; i++)); do
                                    current_tool_calls[$i]=$(printf '%s' "$message_json" | jq -c ".tool_calls[$i]" 2>/dev/null)
                                done
                            fi
                        fi
                    fi
                fi
            fi

            local should_retry=false
            if [[ $curl_exit_code -ne 0 ]]; then should_retry=true; err_detail="Connection failed (curl exit code $curl_exit_code)"
            elif [[ "$http_code" =~ ^5 ]]; then should_retry=true; err_detail="Server error (HTTP $http_code)"
            elif [[ -n "$api_error" ]]; then
                if [[ "$http_code" =~ ^4 ]]; then should_retry=false; err_detail="Client error (HTTP $http_code): $api_error"
                else should_retry=true; err_detail="API Error: $api_error"; fi
            fi
            if [[ "$should_retry" == "true" ]]; then
                if [[ $GLOBAL_RETRY_COUNT -gt $BR_RETRIES ]]; then
                    echo -e "\n[Max retries ($BR_RETRIES) reached. Aborting request.]"; return 1
                fi
                echo -e "\n[Error communicating with LLM server: $err_detail]"
                echo "[Retry $GLOBAL_RETRY_COUNT/$BR_RETRIES in ${GLOBAL_RETRY_DELAY}s...]"
                sleep "$GLOBAL_RETRY_DELAY"
                GLOBAL_RETRY_DELAY=$((GLOBAL_RETRY_DELAY * 2))
                if [[ $GLOBAL_RETRY_DELAY -gt 128 ]]; then GLOBAL_RETRY_DELAY=2; fi
                GLOBAL_RETRY_COUNT=$((GLOBAL_RETRY_COUNT + 1)); continue
            fi
            if [[ "$should_retry" == "false" && -n "$api_error" ]]; then
                echo -e "\nAPI Error: $api_error"; return 1
            fi
            request_successful=true; GLOBAL_RETRY_COUNT=1; GLOBAL_RETRY_DELAY=2
        done

        if [[ "$reasoning_started" == "true" ]]; then printf "[/THINK]%s\n\n" "${COLOR_RESET}"; fi

        if [[ "$BR_MODEL_STREAM" == "false" ]]; then
            if [[ -n "$reasoning_content" ]]; then
                printf "%s[THINK]" "${COLOR_DIM}"; printf "%s" "$reasoning_content"; printf "[/THINK]%s\n\n" "${COLOR_RESET}"
            fi
            while [[ "$response_content" =~ ^$'\n' ]]; do response_content="${response_content:1}"; done
            if [[ -n "$response_content" ]]; then printf "%s" "$response_content"; fi
        fi

        if [[ "$has_tool_calls" == "true" ]]; then
            if [[ -n "$response_content" ]]; then
                if [[ "$response_content" != *$'\n' ]]; then printf "\n\n"
                elif [[ "$response_content" != *$'\n\n' ]]; then printf "\n"; fi
            fi
            local final_tool_calls="[]"
            if [[ ${#current_tool_calls[@]} -gt 0 ]]; then
                final_tool_calls=$(printf '%s\n' "${current_tool_calls[@]}" | jq -s '[.[] | select(. != null and . != "")]')
            fi
            local assistant_msg tmp_tc tmp_reasoning
            tmp_tc=$(mktemp); printf '%s' "$final_tool_calls" > "$tmp_tc"
            tmp_reasoning="/dev/null"
            if [[ -n "$reasoning_content" ]]; then tmp_reasoning=$(mktemp); printf '%s' "$reasoning_content" > "$tmp_reasoning"; fi
            if [[ -n "$response_content" ]]; then
                assistant_msg=$(printf '%s' "$response_content" | jq -Rs \
                    --slurpfile tc "$tmp_tc" --rawfile rc "$tmp_reasoning" \
                    '{role: "assistant", content: ., tool_calls: ($tc[0] // [])} + (if $rc != "" then {reasoning_content: $rc} else {} end)')
            else
                assistant_msg=$(jq -n --slurpfile tc "$tmp_tc" --rawfile rc "$tmp_reasoning" \
                    '{role: "assistant", tool_calls: ($tc[0] // [])} + (if $rc != "" then {reasoning_content: $rc} else {} end)')
            fi
            [[ "$tmp_reasoning" != "/dev/null" ]] && rm -f "$tmp_reasoning"; rm -f "$tmp_tc"
            CONVERSATION+=("$assistant_msg")

            local tc_length
            tc_length=$(printf '%s' "$final_tool_calls" | jq 'length')
            for ((i=0; i<tc_length; i++)); do
                local tc_id func_name args_json tc_json
                tc_id=$(printf '%s' "$final_tool_calls" | jq -r ".[$i].id")
                func_name=$(printf '%s' "$final_tool_calls" | jq -r ".[$i].function.name")
                args_json=$(printf '%s' "$final_tool_calls" | jq -r ".[$i].function.arguments")
                tc_json=$(printf '%s' "$final_tool_calls" | jq -c ".[$i]")
                printf "%s[TOOL_CALL]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
                printf '%s' "$tc_json" | jq $JQ_COLOR_FLAG .
                printf "%s[/TOOL_CALL]%s\n\n" "${COLOR_DIM}" "${COLOR_RESET}"
                printf "%s[INFO] Executing tool '%s'... [/INFO]%s\n" "${COLOR_DIM}" "$func_name" "${COLOR_RESET}"
                printf "%s[TOOL_RESPONSE]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
                printf "%s" "${COLOR_DIM}"
                local tool_output tool_exit=0
                tool_output=$(execute_tool "$func_name" "$args_json" 2>&1) || tool_exit=$?
                if [[ $tool_exit -ne 0 ]]; then
                    if [[ "$tool_output" != Error:* ]]; then echo "Error: $tool_output"; tool_output="Error: $tool_output"
                    else echo "$tool_output"; fi
                else echo "$tool_output"; fi
                printf "%s[/TOOL_RESPONSE]%s\n\n" "${COLOR_DIM}" "${COLOR_RESET}"
                local tool_msg
                tool_msg=$(printf '%s' "$tool_output" | jq -Rs --arg tool_call_id "$tc_id" '{role: "tool", content: ., tool_call_id: $tool_call_id}')
                CONVERSATION+=("$tool_msg")
            done
            continue
        else
            local assistant_msg tmp_reasoning
            tmp_reasoning="/dev/null"
            if [[ -n "$reasoning_content" ]]; then tmp_reasoning=$(mktemp); printf '%s' "$reasoning_content" > "$tmp_reasoning"; fi
            if [[ -n "$response_content" ]]; then
                assistant_msg=$(printf '%s' "$response_content" | jq -Rs --rawfile rc "$tmp_reasoning" \
                    '{role: "assistant", content: .} + (if $rc != "" then {reasoning_content: $rc} else {} end)')
            else
                assistant_msg=$(jq -n --rawfile rc "$tmp_reasoning" \
                    '{role: "assistant"} + (if $rc != "" then {reasoning_content: $rc} else {} end)')
            fi
            [[ "$tmp_reasoning" != "/dev/null" ]] && rm -f "$tmp_reasoning"
            CONVERSATION+=("$assistant_msg")
            br_sync_msgs
            printf "\n"
            break
        fi
    done
}

# Input history
init_input_history() {
    BR_HIST_DIR="${HOME}/.config/br"
    BR_HIST_FILE="${BR_HIST_DIR}/history"
    mkdir -p "$BR_HIST_DIR" 2>/dev/null
    HISTFILE="$BR_HIST_FILE"
    HISTSIZE=1000
    HISTFILESIZE=1000
    HISTCONTROL="ignorespace:ignoredups"
    history -r "$BR_HIST_FILE" 2>/dev/null
}

append_input_history() {
    local entry="$1"
    [[ -z "$entry" ]] && return 0
    history -s "$entry"
    history -a "$BR_HIST_FILE" 2>/dev/null
}

# Main
main() {
    # Auto-create initial session + conversation
    local init_sid init_sname init_cid init_cname
    init_sid=$(gen_uuid)
    init_sname="${init_sid: -12}"
    init_cid=$(gen_uuid)
    init_cname="${init_cid: -12}"

    # Fallback for rare collisions
    while [[ -n "${SESSIONS[$init_sname]+x}" ]]; do init_sname="${init_sname}_1"; done
    while [[ -n "${CONVS["$init_sname|$init_cname"]+x}" ]]; do init_cname="${init_cname}_1"; done

    SESSIONS["$init_sname"]="$init_sid"
    CONVS["$init_sname|$init_cname"]="$init_cid"
    MSGS["$init_sname|$init_cname"]="[]"

    CUR_SESSION_NAME="$init_sname"
    CUR_CONV_NAME="$init_cname"
    br_update_headers

    read_env_vars
    init_conversation
    init_input_history

    printf "%s[INFO] CTRL+C clears input, CTRL+D exits, UP/DOWN navigates history. [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"

    while true; do
        echo
        # Drain buffered keystrokes
        while IFS= read -t 0.01 -n 1 -r _ 2>/dev/null; do :; done

        # Re-apply TTY settings before each read (readline restores terminal modes)
        apply_tty_settings
        read -r -e -p "User: " message
        status=$?

        # CTRL+D (EOF) exits
        if [ "$status" -ne 0 ]; then
            printf "\n%s[INFO] EOF received. Exiting. [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
            break
        fi

        # Empty input: just re-prompt
        if [ -z "$message" ]; then
            continue
        fi

        append_input_history "$message"

        # Exit
        if [[ "$message" == "/exit" || "$message" == "/quit" ]]; then
            printf "%s[INFO] Exiting. [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
            break
        fi

        # /info
        if [[ "$message" == "/info" ]]; then br_info; continue; fi

        # /help
        if [[ "$message" == "/help" ]]; then
            cat <<EOF
 ${COLOR_DIM}General:${COLOR_RESET}
  /info              Print config and current session/conversation info
  /dump              Print current conversation messages as JSON
  /pop               Pop last message from current conversation
  /compact           Summarize and compact current conversation
  /history           Show input history
  /history clear     Clear input history
  /exit, /quit       Exit

 ${COLOR_DIM}Session (/session ...):${COLOR_RESET}
  /session ls                          List all sessions
  /session new [name]                  Create new session, switch to it
  /session clear [id-or-name]          Remove all conversations in session (default: current)
  /session mv <new>                    Rename current session to <new>
  /session mv <old> <new>              Rename session <old> (id-or-name) to <new>
  /session cp <new>                    Copy current session to <new>
  /session cp <old> <new>              Copy session <old> (id-or-name) to <new>
  /session rm [id-or-name]             Remove session (current if no name)
  /session dump [id-or-name]           Dump session as pretty JSON
  /session resume <id-or-name>         Switch to session
  /session save <file>                 Save all sessions to file
  /session save <id-or-name> <file>    Save single session to file
  /session load <file>                 Load all sessions from file (merge)
  /session load <file> <name>          Load single session into <name>

 ${COLOR_DIM}Conversations (/session conv ...):${COLOR_RESET}
  /session conv ls                              List conversations in current session
  /session conv new [sess] [conv]               Create new conversation, switch to it
  /session conv rm [sess] [conv]                Remove conversation
  /session conv clear [sess] [conv]             Clear messages of conversation
  /session conv mv <new>                        Rename current conversation
  /session conv mv <old> <new>                  Rename conversation in current session
  /session conv mv <s1> <c1> <s2> <c2>          Move conversation across sessions
  /session conv cp <new>                        Copy current conversation
  /session conv cp <old> <new>                  Copy conversation in current session
  /session conv cp <s1> <c1> <s2> <c2>          Copy conversation across sessions
  /session conv resume <conv>                   Resume conversation in current session
  /session conv resume <sess> <conv>            Resume conversation in session <sess>
  /session conv save <file>                     Save all convs of current session
  /session conv save <conv> <file>              Save single conversation
  /session conv load <file>                     Load convs into current session (merge)
  /session conv load <file> <conv>              Load single conv into <conv>

 ${COLOR_DIM}Conversations in current session (/conv ...):${COLOR_RESET}
  /conv ls                          List conversations in current session
  /conv new [name]                  Create new conversation, switch to it
  /conv rm [name]                   Remove conversation
  /conv clear [name]                Clear messages of conversation
  /conv mv <new>                    Rename current conversation
  /conv mv <old> <new>              Rename conversation
  /conv cp <new>                    Copy current conversation
  /conv cp <old> <new>              Copy conversation
  /conv resume <name>               Resume conversation
  /conv save <file>                 Save all convs of current session
  /conv save <conv> <file>          Save single conversation
  /conv load <file>                 Load convs into current session (merge)
  /conv load <file> <conv>          Load single conv into <conv>

 ${COLOR_DIM}Shorthands for current session convs:${COLOR_RESET}
  /ls                               Shorthand for /conv ls
  /new [name]                       Shorthand for /conv new [name]
  /clear [name]                     Shorthand for /conv clear [name]
  /rm [name]                        Shorthand for /conv rm [name]
  /mv <new>                         Shorthand for /conv mv <new>
  /mv <old> <new>                   Shorthand for /conv mv <old> <new>
  /cp <new>                         Shorthand for /conv cp <new>
  /cp <old> <new>                   Shorthand for /conv cp <old> <new>
  /resume <name>                    Shorthand for /conv resume <name>
  /save <file>                      Shorthand for /conv save <file>
  /save <conv> <file>               Shorthand for /conv save <conv> <file>
  /load <file>                      Shorthand for /conv load <file>
  /load <file> <conv>               Shorthand for /conv load <file> <conv>
EOF
            continue
        fi

        # /dump - check session/conversation exists
        if [[ "$message" == "/dump" ]]; then
            if ! br_check_current; then continue; fi
            local messages_json="[]"
            if [[ ${#CONVERSATION[@]} -gt 0 ]]; then
                messages_json=$(printf '%s\n' "${CONVERSATION[@]}" | jq -s '.')
            fi
            echo "${COLOR_DIM}[CONVERSATION]${COLOR_RESET}"
            printf '%s' "$messages_json" | jq $JQ_COLOR_FLAG .
            echo "${COLOR_DIM}[/CONVERSATION]${COLOR_RESET}"
            continue
        fi

        # /pop - check session/conversation exists
        if [[ "$message" == "/pop" ]]; then
            if ! br_check_current; then continue; fi
            if [[ ${#CONVERSATION[@]} -gt 0 ]]; then
                echo "${COLOR_DIM}[MESSAGE]${COLOR_RESET}"
                printf '%s' "${CONVERSATION[-1]}" | jq $JQ_COLOR_FLAG .
                echo "${COLOR_DIM}[/MESSAGE]${COLOR_RESET}"
                unset 'CONVERSATION[-1]'
                br_sync_msgs
                printf "%s[INFO] Popped last message from conversation. [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
            else
                printf "%s[INFO] Conversation is empty. [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
            fi
            continue
        fi

        # /compact - check session/conversation exists
        if [[ "$message" == "/compact" ]]; then
            if ! br_check_current; then continue; fi
            compact_conversation; continue
        fi

        # /history
        if [[ "$message" == "/history" ]]; then
            echo "${COLOR_DIM}[INPUT HISTORY]${COLOR_RESET}"
            history 2>/dev/null | sed "s/^/  /"
            echo "${COLOR_DIM}[/INPUT HISTORY]${COLOR_RESET}"
            continue
        fi
        if [[ "$message" == "/history clear" ]]; then
            history -c 2>/dev/null; : > "$BR_HIST_FILE" 2>/dev/null
            printf "%s[INFO] Input history cleared. [/INFO]%s\n" "${COLOR_DIM}" "${COLOR_RESET}"
            continue
        fi

        # /session ...
        if [[ "$message" == "/session" || "$message" == /session\ * ]]; then
            local rest="${message#/session}"
            rest="${rest# }"
            local -a sargs
            read -ra sargs <<< "$rest"
            local sub="${sargs[0]:-}"
            local -a sub_args=("${sargs[@]:1}")
            br_handle_session "$sub" "${sub_args[@]}"
            continue
        fi

        # /conv ... (independent command, current session only)
        if [[ "$message" == "/conv" || "$message" == /conv\ * ]]; then
            local rest="${message#/conv}"
            rest="${rest# }"
            local -a sargs
            read -ra sargs <<< "$rest"
            local sub="${sargs[0]:-}"
            local -a sub_args=("${sargs[@]:1}")
            br_handle_conv "$sub" "${sub_args[@]}"
            continue
        fi

        # Shorthand commands for /conv
        case "$message" in
            /ls|/new|/clear|/rm|/mv|/cp|/resume|/save|/load|/ls\ *|/new\ *|/clear\ *|/rm\ *|/mv\ *|/cp\ *|/resume\ *|/save\ *|/load\ *)
                local rest="${message#* }"
                if [[ "$message" == /ls || "$message" == /new || "$message" == /clear || "$message" == /rm || "$message" == /mv || "$message" == /cp || "$message" == /resume || "$message" == /save || "$message" == /load ]]; then
                    rest=""
                fi
                local cmd="${message%% *}"
                local sub="ls"
                case "$cmd" in
                    /new) sub="new" ;;
                    /clear) sub="clear" ;;
                    /rm) sub="rm" ;;
                    /mv) sub="mv" ;;
                    /cp) sub="cp" ;;
                    /resume) sub="resume" ;;
                    /save) sub="save" ;;
                    /load) sub="load" ;;
                esac
                local -a sargs
                if [[ -n "$rest" ]]; then
                    read -ra sargs <<< "$rest"
                else
                    sargs=()
                fi
                br_handle_conv "$sub" "${sargs[@]}"
                continue
                ;;
        esac

        # Send to LLM - check session/conversation exists
        if ! br_check_current; then continue; fi
        echo
        echo -n "Assistant: "
        oai_make_request "$message"
    done
}

main
exit 0

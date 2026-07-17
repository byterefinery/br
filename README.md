# br

![br](./logo.png)

ByteRefinery Agent (Harness)

## Bash Implementation

Single file implementation in `br.sh` that uses only `curl` to make HTTP(S) requests, and `jq` to parse JSON responses.

**NOTE:**
- We chose convenience of `curl` and `jq` over re-implementing them.
- Once features stabilize, we will re-factor `br.sh` to be simpler, but we need it working first.
- In near future, we will re-implement `br` in Python, Node/bun/deno, other shells, and later in other programming languages.

### Configuration

**RECOMMENDED:** Set up environment variables. Without setting them `br` expects local LLM server running.

**NOTE:** `br` first check for local `.env`, then `~/.config/br/config`, and then if config files are missing it uses local LLM server on `http://127.0.0.1:8080`.

```bash
cp .env.example .env
```

### Run

```bash
./br.sh
```

## Local LLM Server

**Recommended:** Build `llama.cpp` using **Vulkan** backend:

```bash
cd ~
git clone git@github.com:ggml-org/llama.cpp.git
cd llama.cpp
rm -rf build ; git pull ; cmake -B build -DGGML_VULKAN=ON && cmake --build build --config Release -j $(nproc)
```

### LiquidAI/LFM2.5-8B-A1B

```bash
~/llama.cpp/build/bin/llama-server \
    -hf 'LiquidAI/LFM2.5-8B-A1B-GGUF:Q8_0' \
    --alias 'LiquidAI/LFM2.5-8B-A1B' \
    -ngl -1 \
    -np 1 \
    --temp 0.2 --top-k 80 --repeat-penalty 1.05 -fa on \
    --spec-default \
    --reasoning on \
    --chat-template-kwargs '{"preserve_thinking": true}' \
    --tools all \
    --ui
```

### RWKV/RWKV7-G1h-7.2B

```bash
~/llama.cpp/build/bin/llama-server \
    -hf 'shoumenchougou/RWKV7-G1h-7.2B-GGUF:Q8_0' \
    --alias 'RWKV/RWKV7-G1h-7.2B' \
    -ngl -1 \
    -np 1 \
    --temp 0.0 --top-p 0.0 -n 16384 -fa on \
    --spec-default \
    --reasoning on \
    --tools all \
    --chat-template-file 'misc/rwkv7.jinja' \
    --ui
```

### deepreinforce-ai/Ornith-1.0-9B

```bash
~/llama.cpp/build/bin/llama-server \
    -hf 'deepreinforce-ai/Ornith-1.0-9B-GGUF:Q4_K_M' \
    --alias 'deepreinforce-ai/Ornith-1.0-9B' \
    -ngl -1 \
    -np 1 \
    --temp 0.6 --top-p 0.95 --top-k 20 -n 16384 -c 131072 -fa on \
    -ctk q4_1 -ctv q4_1 \
    --no-mmproj-offload \
    --spec-default \
    --spec-draft-n-max 3 \
    --reasoning on \
    --chat-template-kwargs '{"preserve_thinking": true}' \
    --tools all \
    --ui
```

### empero-ai/Qwythos-9B-v2

```bash
~/llama.cpp/build/bin/llama-server \
    -hf 'empero-ai/Qwythos-9B-v2-GGUF:MTP-Q4_K_M' \
    --alias 'empero-ai/Qwythos-9B-v2' \
    -ngl -1 \
    -np 1 \
    --temp 0.6 --top-p 0.95 --top-k 20 -n 16384 -c 131072 -fa on \
    -ctk q4_1 -ctv q4_1 \
    --no-mmproj-offload \
    --spec-default \
    --spec-draft-n-max 3 \
    --reasoning on \
    --chat-template-kwargs '{"preserve_thinking": true}' \
    --tools all \
    --ui
```

### google/gemma-4-12B-it-qat

```bash
~/llama.cpp/build/bin/llama-server \
    -hf 'unsloth/gemma-4-12B-it-qat-GGUF:Q4_K_XL' \
    --alias 'google/gemma-4-12B-it-qat' \
    -ngl -1 \
    -np 1 \
    --temp 1.0 --top-p 0.95 --top-k 64 -c 131072 -fa on \
    -ctk q4_1 -ctv q4_1 \
    --no-mmproj-offload \
    --spec-default \
    --spec-type draft-mtp --spec-draft-n-max 3 \
    --reasoning on \
    --chat-template-kwargs '{"preserve_thinking": true}' \
    --tools all \
    --ui
```

### prism-ml/Ternary-Bonsai-27B

```bash
~/llama.cpp/build/bin/llama-server \
    -hf 'prism-ml/Ternary-Bonsai-27B-gguf:Q2_g64' \
    --alias 'prism-ml/Ternary-Bonsai-27B' \
    -ngl -1 \
    -np 1 \
    --temp 0.7 --top-p 0.95 --top-k 20 -n 16384 -c 131072 -fa on \
    -ctk q4_1 -ctv q4_1 \
    --no-mmproj-offload \
    --spec-default \
    --reasoning on \
    --chat-template-kwargs '{"preserve_thinking": true}' \
    --tools all \
    --ui
```

### prism-ml/Bonsai-27B

```bash
~/llama.cpp/build/bin/llama-server \
    -hf 'prism-ml/Bonsai-27B-gguf:Q1_0' \
    --alias 'prism-ml/Bonsai-27B' \
    -ngl -1 \
    -np 1 \
    --temp 0.7 --top-p 0.95 --top-k 20 -n 16384 -c 131072 -fa on \
    -ctk q4_1 -ctv q4_1 \
    --no-mmproj-offload \
    --spec-default \
    --reasoning on \
    --chat-template-kwargs '{"preserve_thinking": true}' \
    --tools all \
    --ui
```

### Qwen/Qwen3.6-27B

```bash
~/llama.cpp/build/bin/llama-server \
    -hf 'unsloth/Qwen3.6-27B-MTP-GGUF:Q4_K_XL' \
    --alias 'Qwen/Qwen3.6-27B' \
    -ngl -1 \
    -np 1 \
    --temp 0.6 --top-p 0.95 --top-k 20 -c 262144 -fa on \
    -ctk q4_1 -ctv q4_1 \
    --no-mmproj-offload \
    --spec-default \
    --spec-type draft-mtp --spec-draft-n-max 2 \
    --reasoning on \
    --reasoning-preserve \
    --chat-template-kwargs '{"preserve_thinking": true}' \
    --tools all \
    --ui
```

### curl examples

Test streaming response:

```bash
curl -N http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "messages": [
      {
        "role": "system",
        "content": "You are a helpful assistant."
      },
      {
        "role": "user",
        "content": "Hello!"
      }
    ],
    "stream": true
  }'
```

Test non-streaming response:

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "messages": [
      {
        "role": "system",
        "content": "You are a helpful assistant."
      },
      {
        "role": "user",
        "content": "Hello!"
      }
    ],
    "stream": false
  }'
```

Test non-streaming response:

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "messages": [
      {
        "role": "system",
        "content": "Tools: [\n{\"type\":\"function\",\"function\":{\"name\":\"read_file\",\"description\":\"Read the contents of a file. Optionally specify a 1-based line range. If append_loc is true, each line is prefixed with its line number.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file\"},\"start_line\":{\"type\":\"integer\",\"description\":\"First line to read, 1-based (default: 1)\"},\"end_line\":{\"type\":\"integer\",\"description\":\"Last line to read, 1-based inclusive (default: end of file)\"},\"append_loc\":{\"type\":\"boolean\",\"description\":\"Prefix each line with its line number\"}},\"required\":[\"path\"]}}},\n{\"type\":\"function\",\"function\":{\"name\":\"exec_shell_command\",\"description\":\"Execute a shell command and return its output (stdout and stderr combined).\",\"parameters\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"Shell command to execute\"},\"timeout\":{\"type\":\"integer\",\"description\":\"Timeout in seconds (default 10, max 60)\"},\"max_output_size\":{\"type\":\"integer\",\"description\":\"Maximum output size in bytes (default 16384)\"}},\"required\":[\"command\"]}}},\n{\"type\":\"function\",\"function\":{\"name\":\"write_file\",\"description\":\"Write content to a file, creating it (including parent directories) if it does not exist. May use with edit_file for more complex edits.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path of the file to write\"},\"content\":{\"type\":\"string\",\"description\":\"Content to write\"}},\"required\":[\"path\",\"content\"]}}},\n{\"type\":\"function\",\"function\":{\"name\":\"edit_file\",\"description\":\"Edit a file using exact text replacement. Each edits[].old_text must be unique in the file and is matched against the original content, not incrementally. Merge nearby changes into one edit instead of overlapping edits. Use write_file to replace the whole file.\",\"parameters\":{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Path to the file to edit\"},\"edits\":{\"type\":\"array\",\"description\":\"One or more exact text replacements to apply\",\"items\":{\"type\":\"object\",\"properties\":{\"old_text\":{\"type\":\"string\",\"description\":\"Exact text to find; must be unique in the file and must not overlap with other edits\"},\"new_text\":{\"type\":\"string\",\"description\":\"Text to replace old_text with\"}},\"required\":[\"old_text\",\"new_text\"]}}},\"required\":[\"path\",\"edits\"]}}}\n]"
      },
      {
        "role": "user",
        "content": "List current directory"
      }
    ],
    "stream": false
  }' | jq .
```

## Example

### Skills - websearch

1. `./br.sh`
2. agent skills system
3. list available skills
4. load skill `websearch`
5. exec skill `websearch`, query "byterefinery github repos"
6. format results as Markdown table
7. Exit, CTRL+D or `/exit`

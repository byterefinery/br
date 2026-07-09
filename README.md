# br

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

Run `llama.cpp` server and `LiquidAI/LFM2.5-8B-A1B` model:
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

Test streaming response:
```bash
curl -N http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "model": "LiquidAI/LFM2.5-8B-A1B",
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
    "model": "LiquidAI/LFM2.5-8B-A1B",
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

## Example

### Skills - websearch

1. Help commands inside `br`
2. Load agent skills system
3. List available skills
4. Load skill `websearch`
5. Execute `websearch` script
6. Format results as Markdown table
7. Exit, CTRL+D or `/exit`

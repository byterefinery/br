# br

![br](./logo.png)

ByteRefinery Agent (Harness)

## Bash Implementation

Single file implementation in `br.sh` that uses only `curl` to make HTTP(S) requests, and `jq` to parse JSON responses.

**NOTE:**
- We chose convenience of `curl` and `jq` over re-implementing them.
- Once features stabilize, we will re-factor `br.sh` to be simpler, but we need it working first.
- In near future, we will re-implement `br` in Python, Node/bun/deno, other shells, and later in other programming languages.

## Configuration

**RECOMMENDED:** Set up environment variables. Without setting them `br` expects local LLM server running.

**NOTE:** `br` first check for local `.env`, then `~/.config/br/config`, and then if config files are missing it uses local LLM server on `http://127.0.0.1:8080`.

```bash
cp .env.example .env
```

## Run br

```bash
./br.sh
```

## Models

How to locally run model check out [MODELS.md](./MODELS.md) that shows how to clone, build, and run engine and LLM.

**Recommended:**
- Build `llama.cpp` using **Vulkan** backend
- Start with these models because they can fit in 8GB VRAM on GPU:
  - `deepreinforce-ai/Ornith-1.0-9B`, Dense, 131,072 context, ~6.8 GB VRAM
  - `google/gemma-4-12B-it-qat`, Dense, 131,072 context, ~7.8 GB VRAM
  - `prism-ml/Bonsai-27B`, Dense, 131,072 context, ~7.0 GB VRAM
  - `LiquidAI/LFM2.5-8B-A1B`, MoE, 128,000 context, ~7.3 GB VRAM

## Example

### Skills - websearch

1. `./br.sh`
2. agent skills system
3. list available skills
4. load skill `websearch`
5. exec skill `websearch`, query "byterefinery github repos"
6. format results as Markdown table
7. Exit, CTRL+D or `/exit`

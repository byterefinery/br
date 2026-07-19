# br

ByteRefinery Agent Harness

![br](./logo.png)

**NOTE:**
- We chose first to implement `br` using `bash` and convenience of `curl` and `jq`.
- In near future, we will re-implement `br` in Python, Node/bun/deno, other shells, and later in other programming languages.

## Bash Implementation

Single file implementation in `br.sh` that uses only `curl` to make HTTP(S) requests, and `jq` to parse JSON responses.

## Configuration

`br` first checks for local `.env` which holds environment variables, then `~/.config/br/config`, and then if config files are missing it uses local LLM server `http://127.0.0.1:8080`.

```bash
cp .env.example .env
```

Inspect and edit `.env` file if necessary.

## Run br

```bash
./br.sh
```

## Models

Instructions how to locally run model(s) check out [MODELS.md](./MODELS.md) that shows how to clone, build, and run engine and different models.

**Recommended:**
- Build [`llama.cpp`](https://github.com/ggml-org/llama.cpp) using **Vulkan** backend
- Start with these models because they can fit in 8GB VRAM on GPU:
  - `deepreinforce-ai/Ornith-1.0-9B`, Dense, 131,072 context, ~6.8 GB VRAM
  - `google/gemma-4-12B-it-qat`, Dense, 131,072 context, ~7.8 GB VRAM
  - `prism-ml/Bonsai-27B`, Dense, 131,072 context, ~7.0 GB VRAM
  - `LiquidAI/LFM2.5-8B-A1B`, MoE, 128,000 context, ~7.3 GB VRAM

Besides [`llama.cpp`](https://github.com/ggml-org/llama.cpp) you can also use:
- [LM Studio](https://lmstudio.ai/)
- [Ollama](https://ollama.com/)
- [Unsloth Studio](https://unsloth.ai/docs/new/studio)

## Example

### Skills - websearch

1. `./br.sh`
2. agent skills system
3. list available skills
4. load skill `websearch`
5. exec skill `websearch`, query "byterefinery github repos"
6. format results as Markdown table
7. Exit, CTRL+D or `/exit`

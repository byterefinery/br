# br

ByteRefinery Agent

## Bash Implementation

Single file implementation in `br.sh` that uses only `curl` to make HTTP requests, and `jq` to parse HTTP JSON responses.

**NOTE:**
- We chose convenience of `curl` and `jq` over re-implementing them.
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

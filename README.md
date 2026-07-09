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

### Example

1. Help commands inside `br`
2. Load agent skills system
3. List available skills
4. Load skill `websearch`
5. Execute `websearch` script
6. Format results as Markdown table
7. Exit, CTRL+D or `/exit`

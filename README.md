# br

ByteRefinery Agent

## Bash Implementation

Uses only `curl` to make HTTP requests, and `jq` to parse HTTP JSON responses.

**NOTE:** In near future, we will re-implement `br.py` in Python, and after that in other programming languages.

### Configuration

**RECOMMENDED:** Set up environment variables. Without setting them `br` expects local LLM server running.

```bash
cp .env.example .env
```

### Run

```bash
./br.sh
```

---
name: okf
description: Create, read, validate, and navigate Open Knowledge Format (OKF) bundles — hierarchical markdown knowledge bases with YAML frontmatter. Use when working with OKF bundles such as creating concept documents, index.md files, log.md files, cross-linking concepts, or validating conformance.
metadata:
  tags:
    - meta
---

# okf

## Overview

OKF (Open Knowledge Format, v0.1) is an open, human- and agent-friendly format for representing knowledge — the metadata, context, and curated insight that surrounds data and systems. It is a directory of markdown files with YAML frontmatter. No schema registry, no central authority, no required tooling. If you can `cat` a file, you can read OKF; if you can `git clone` a repo, you can ship it.

The format standardizes only the small set of structural conventions needed to make a knowledge corpus *self-describing*. Everything beyond that is left to the producer.

### Design principles

Knowledge representations should be:

- **Readable** by humans without tooling.
- **Parseable** by agents without bespoke SDKs.
- **Diffable** in version control.
- **Portable** across tools, organizations, and time.

### Goals

1. Define a universal format that **enrichment agents** can write into.
2. Inform how **consumption agents** should read and traverse it.
3. Facilitate **exchange** of knowledge across systems and organizations.
4. Standardize the small number of **required** fields for meaningful consumption.

### Non-goals

- Defining a fixed taxonomy of concept types.
- Prescribing storage, serving, or query infrastructure.
- Replacing domain-specific schemas (Avro, Protobuf, OpenAPI) — OKF *references* them, it does not subsume them.

### Relationship to other formats

OKF is intentionally close to established patterns:

- **LLM "wiki" repositories** — markdown + frontmatter as agent-readable knowledge bases.
- **Personal knowledge tools** (Obsidian, Notion) — hierarchical markdown with cross-links.
- **"Metadata as code"** — catalog metadata stored alongside source code rather than in a separate registry.

OKF differs by being **specified** — pinning down the small set of rules needed for interoperability without dictating tooling.

Use this skill when:
- Creating new OKF concept documents or bundles from scratch
- Adding concepts to an existing OKF bundle
- Generating or updating `index.md` files for progressive disclosure
- Maintaining `log.md` change histories
- Validating bundle conformance
- Cross-linking concepts within a bundle
- Converting existing documentation or knowledge bases into OKF

## Terminology

| Term | Definition |
|---|---|
| **Knowledge Bundle** | A self-contained, hierarchical collection of knowledge documents. The unit of distribution. |
| **Concept** | A single unit of knowledge within a bundle. One markdown document. May describe a tangible asset (table, API), an abstract idea (metric, process), or anything in between. |
| **Concept ID** | The file path within the bundle with `.md` removed. E.g., `tables/users.md` has concept ID `tables/users`. |
| **Frontmatter** | YAML metadata block delimited by `---` at the top of a markdown file. |
| **Body** | Everything in the file after the frontmatter. |
| **Link** | A standard markdown link from one concept to another, expressing relationships beyond the implicit parent/child hierarchy. |
| **Citation** | A link from a concept to an external source that supports a claim in the body. |

## Bundle Structure

A bundle is a directory tree of markdown files. The directory structure is domain-independent — organize concepts however makes sense for the knowledge being captured.

```
bundle/
├── index.md                      # Optional. Directory listing for progressive disclosure.
├── log.md                        # Optional. Chronological history of updates.
├── <concept>.md                  # A concept at the bundle root.
└── <subdirectory>/               # Subdirectories organize concepts into groups.
    ├── index.md
    ├── <concept>.md
    └── <subdirectory>/
        └── …
```

### Distribution

A bundle may be distributed as:

- A **git repository** (recommended — provides history, attribution, diffs).
- A tarball or zip archive of the directory.
- A subdirectory within a larger repository.

### Reserved filenames

These filenames have defined meaning at any hierarchy level and must not be used for concept documents:

| Filename | Purpose |
|---|---|
| `index.md` | Directory listing for progressive disclosure |
| `log.md` | Update history |

All other `.md` files are concept documents. Tags are a first-class concept via the `tags` frontmatter field — OKF does not specify a separate file format for aggregating documents by tag. Producers that want a tag-browsing view can synthesize one at consumption time by scanning frontmatter.

## Concept Documents

Every concept is a UTF-8 markdown file with two parts:

1. **YAML frontmatter block** — delimited by `---` on its own line at the start and a closing `---` on its own line.
2. **Markdown body** — free-form content after the frontmatter.

### Frontmatter

```yaml
---
type: <Type name>                  # REQUIRED
title: <Optional display name>
description: <Optional summary>
resource: <Optional URI>
tags: [<tag>, <tag>]
timestamp: <ISO 8601 datetime>
# … producer-defined key/value pairs
---
```

#### Required fields

- **`type`** — A short string identifying the kind of concept. Consumers use this for routing, filtering, and presentation. Example values: `BigQuery Table`, `BigQuery Dataset`, `API Endpoint`, `Metric`, `Playbook`, `Reference`.

  Type values are **not registered centrally**. Producers should pick descriptive, self-explanatory values. Consumers must tolerate unknown types gracefully (typically by treating them as generic concepts).

#### Recommended fields (in priority order)

- **`title`** — Human-readable display name. If omitted, consumers may derive a title from the filename.
- **`description`** — A single sentence summarizing the concept. Used by `index.md` generators, search snippets, and previews.
- **`resource`** — A URI that uniquely identifies the underlying asset the concept describes. Absent for concepts describing abstract ideas rather than physical resources.
- **`tags`** — A YAML list of short strings for cross-cutting categorization.
- **`timestamp`** — ISO 8601 datetime of last meaningful change.

#### Extensions

Producers may include any additional keys. Consumers should preserve unknown keys when round-tripping and must not reject documents with unrecognized fields.

### Body

The body is standard markdown. Producers should favor **structural markdown** — headings, lists, tables, fenced code blocks — over freeform prose, since structure aids both human reading and agent retrieval.

No body sections are required. The following section headings have **conventional** meaning and should be used when applicable:

| Heading | Purpose |
|---|---|
| `# Schema` | Structured description of an asset's columns/fields |
| `# Examples` | Concrete usage examples, often as fenced code blocks |
| `# Citations` | External sources backing claims in the body |

## Cross-linking

Concepts may link to other concepts using standard markdown links. Two forms are supported:

### Absolute (bundle-relative) links

Begin with `/`, interpreted relative to the bundle root. This is the **recommended** form because it is stable when documents are moved within their subdirectory.

```markdown
See the [customers table](/tables/customers.md) for the join key.
```

### Relative links

Standard markdown relative paths.

```markdown
See the [neighboring concept](./other.md).
```

### Link semantics

A link from concept A to concept B asserts a *relationship*. The specific kind of relationship (parent/child, references, joins-with, depends-on, etc.) is **conveyed by the surrounding prose, not by the link itself**. Consumers that build a graph view typically treat all links as **directed edges of an untyped relationship**.

Consumers **must** tolerate broken links — a link whose target does not exist is not malformed; it may represent not-yet-written knowledge.

## Index Files

An `index.md` file may appear in any directory, including the bundle root. It enumerates the directory's contents to support **progressive disclosure** — letting a human or agent see what is available before opening individual documents.

Index files contain **no frontmatter** (the only exception is the bundle-root `index.md`, which may declare `okf_version`). The body uses one or more sections, each grouping concepts under a heading:

```markdown
# Section / Group Heading

- [Title 1](relative-url-1) - short description of item 1
- [Title 2](relative-url-2) - short description of item 2

# Another Section

- [Subdirectory](subdir/) - short description of the subdirectory
```

Entries should include the `description` from the linked concept's frontmatter. Producers may generate `index.md` automatically; consumers may synthesize one on the fly when none is present.

## Log Files

A `log.md` file may appear at any level of the hierarchy to record the history of changes to that scope. The format is a flat list of date-grouped entries, **newest first**:

```markdown
# Directory Update Log

## 2026-05-22
- **Update**: Added new BigQuery table reference for [Customer Metrics](/tables/customer-metrics.md).
- **Creation**: Established the [Dataplex Playbook](/playbooks/dataplex.md).

## 2026-05-15
- **Initialization**: Created foundational directory structure.
```

Date headings must use ISO 8601 `YYYY-MM-DD` form. Log entries are prose; the leading bold word (`**Update**`, `**Creation**`, `**Deprecation**`, etc.) is a convention, not a requirement.

## Citations

When a concept's body makes claims sourced from external material, those sources should be listed under a `# Citations` heading at the bottom of the document, numbered:

```markdown
# Citations

[1] [BigQuery public dataset announcement](https://cloud.google.com/blog/products/data-analytics/...)
[2] [Internal data quality runbook](https://wiki.acme.internal/data/quality)
```

Citation links may be:

- **Absolute URLs** — external web pages, documentation, dashboards.
- **Bundle-relative paths** — links to other concepts within the same bundle.
- **Paths into a `references/` subdirectory** — mirroring external material as first-class OKF concepts within the bundle.

## Conformance

A bundle is **conformant** with OKF v0.1 if:

1. Every non-reserved `.md` file in the tree contains a parseable YAML frontmatter block.
2. Every frontmatter block contains a non-empty `type` field.
3. Every reserved filename (`index.md`, `log.md`) follows the specified structure when present.

Consumers **must not** reject a bundle because of:

- Missing optional frontmatter fields.
- Unknown `type` values.
- Unknown additional frontmatter keys.
- Broken cross-links.
- Missing `index.md` files.

This permissive consumption model is intentional — OKF is meant to remain useful as bundles grow, get refactored, and are partially generated by agents.

## Versioning

OKF uses `<major>.<minor>` versioning:

- **Minor** bump — backward-compatible additions (new optional fields, new conventional section headings).
- **Major** bump — may include breaking changes (renaming required fields, changing reserved filenames).

Bundles may declare the OKF version they target by including `okf_version: "0.1"` in the bundle-root `index.md` frontmatter block (the only place frontmatter is permitted in an `index.md`). Consumers that do not understand the declared version should attempt **best-effort consumption** rather than refusing the bundle.

## Usage

### Creating a concept bound to a resource

```markdown
---
type: BigQuery Table
title: Customer Orders
description: One row per completed customer order across all channels.
resource: https://console.cloud.google.com/bigquery?p=acme&d=sales&t=orders
tags: [sales, orders, revenue]
timestamp: 2026-05-28T14:30:00Z
---

# Schema

| Column        | Type      | Description                              |
|---------------|-----------|------------------------------------------|
| `order_id`    | STRING    | Globally unique order identifier.        |
| `customer_id` | STRING    | FK to [customers](/tables/customers.md). |
| `total_usd`   | NUMERIC   | Order total in US dollars.               |
| `placed_at`   | TIMESTAMP | When the customer submitted the order.   |

# Joins

Joined with [customers](/tables/customers.md) on `customer_id`.

# Citations

[1] [BigQuery table schema](https://console.cloud.google.com/bigquery?p=acme&d=sales&t=orders)
```

### Creating an abstract concept (no resource)

```markdown
---
type: Playbook
title: Incident response — data freshness alert
description: Steps to triage a freshness alert on the orders pipeline.
tags: [oncall, incident]
timestamp: 2026-04-12T09:00:00Z
---

# Trigger

A freshness alert fires when `orders` lags more than 30 minutes behind
its expected SLA. See the [orders table](/tables/orders.md).

# Steps

1. Check the ingestion job dashboard.
2. Restart the pipeline if stalled.
3. Escalate if unresolved after 15 minutes.
```

### Generating an index.md

Scan the directory for `.md` files (excluding `index.md` and `log.md`), extract `title` and `description` from each concept's frontmatter, and produce bulleted sections grouped by heading:

```markdown
# Tables

- [Orders](orders.md) — One row per completed customer order.
- [Customers](customers.md) — Customer profile and contact data.

# Subdirectories

- [Datasets](datasets/) — All sales-related datasets.
```

### Validating conformance

For each `.md` file in the bundle:

1. Skip `index.md` and `log.md` for frontmatter checks.
2. Verify parseable YAML frontmatter delimited by `---`.
3. Verify `type` field is present and non-empty.
4. For `index.md`: verify no frontmatter (except optional `okf_version` at bundle root).
5. For `log.md`: verify date headings use `YYYY-MM-DD` form.

### Minimal example bundle

```
my_bundle/
├── index.md
├── datasets/
│   ├── index.md
│   └── sales.md
└── tables/
    ├── index.md
    ├── orders.md
    └── customers.md
```

## Gotchas

- **`type` is the only required frontmatter field** — everything else is optional. Do not invent required fields beyond what the spec mandates.
- **`index.md` has no frontmatter** — unlike concept documents. The only exception is the bundle-root `index.md`, which may declare `okf_version: "0.1"`. No other `index.md` file anywhere in the tree may have frontmatter.
- **`index.md` and `log.md` are reserved filenames** — never use them for concept documents. Every other `.md` file is a concept and must have frontmatter with `type`.
- **`type` values are not registered** — producers pick their own values. Consumers must tolerate unknown types gracefully (treat as generic concepts).
- **Broken links are tolerated** — a link to a non-existent concept is not an error. It may represent not-yet-written knowledge. Consumers must not reject bundles for broken links.
- **Use absolute bundle-relative links** (`/path/to/concept.md`) over relative links — they are stable when documents are moved within their subdirectory.
- **Link semantics are carried by prose, not the link itself** — the relationship type (parent/child, references, joins-with, depends-on) is conveyed by surrounding text. In a graph view, all links are untyped directed edges.
- **Concept ID is the file path minus `.md`** — e.g., `tables/users.md` has concept ID `tables/users`. Use this for any programmatic references.
- **`log.md` entries are newest first** — reverse chronological order. Date headings must use ISO 8601 `YYYY-MM-DD` form.
- **OKF references schemas, does not replace them** — use `resource` to link to Avro, Protobuf, OpenAPI, or other domain-specific schemas. OKF describes the knowledge around them, not the schemas themselves.
- **Unknown frontmatter keys must be preserved** — when round-tripping or transforming OKF content, never drop unrecognized keys. Consumers must not reject documents with extra fields.
- **Citations can reference `references/` subdirectories** — external material can be mirrored as first-class OKF concepts inside a `references/` subdirectory, and cited via bundle-relative paths.
- **Tags have no dedicated file** — OKF does not specify a separate format for tag aggregation. Synthesize tag-browsing views at consumption time by scanning frontmatter `tags` fields.
- **index.md can be auto-generated or synthesized** — producers may generate `index.md` automatically; consumers may synthesize one on the fly when none is present. Do not treat a missing `index.md` as an error.
- **Bundles are distributed via git** (recommended — provides history, attribution, diffs), tarball/zip, or as a subdirectory. Do not assume a specific distribution mechanism.
- **Versioning is best-effort** — consumers that encounter an unknown `okf_version` should attempt best-effort consumption rather than refusing the bundle.
- **Favor structural markdown in bodies** — headings, lists, tables, and fenced code blocks aid both human reading and agent retrieval. Avoid dense freeform prose.

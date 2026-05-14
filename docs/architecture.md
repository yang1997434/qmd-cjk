# Architecture

## The problem

[qmd](https://github.com/tobi/qmd) stores markdown content in a SQLite FTS5 virtual table `documents_fts` with `tokenize='porter unicode61'`. The `unicode61` tokenizer splits on Unicode whitespace and punctuation, then applies Porter stemming to alphabetic tokens. It works for English. **It does not split CJK runs** — an entire Chinese paragraph becomes a single token, so any query shorter than that paragraph returns 0 hits.

## Rejected approaches

### SQLite built-in `trigram` tokenizer

SQLite 3.34+ ships a `trigram` tokenizer that indexes overlapping 3-character n-grams. In theory, it works for CJK. **In practice, on this corpus it does not.** Empirically (verified 2026-05-13 on Debian 12, SQLite 3.40.1):

- The trigram tokenizer indexes 3-char ngrams that **include leading whitespace / punctuation**, e.g. the token literally stored is `' 节点'` (space + 节 + 点), because Chinese paragraphs in markdown often start after a space, `*`, or `\n`.
- Query-time, when matching `'节点扩容'`, the tokenizer slices into `'节点扩'` / `'点扩容'` (no leading space).
- The index-side ngrams (with whitespace) and query-side ngrams (without) never align, and FTS5 returns 0 hits.

We confirmed this empirically and rolled back. The behavior may improve in later SQLite versions, but as of 3.40.1 it is broken for our use case.

### Application-layer jieba wrapper

Wrap qmd's CLI in a shell/Python script that pre-segments Chinese with whitespace before writing, and again before querying. `unicode61` then sees whitespace as a separator and indexes per-word.

- **Cons**: only covers queries that go through your wrapper. Anything that calls qmd's API directly (MCP server, future plugins) bypasses it. Phrase search and prefix match behave differently because tokenization happens at the wrong layer. Dictionary changes require a full reindex.
- **Verdict**: works, but only covers your own entry points and adds a fragile parallel codepath.

### Replace search stack (Tantivy / Meilisearch / Typesense)

Native CJK support, far better than SQLite FTS5. **But** replacing qmd's entire search layer means rewriting embedding/vector/reranking pipelines, the MCP server, the CLI. Not justified for a small personal vault.

### Embedding-only retrieval

Skip FTS entirely. Semantic search is multilingual by nature. qmd already has `qmd vsearch` (vector similarity) and `qmd query` (vector + LLM rerank). They work for CJK but are 10–100× slower than BM25 and miss exact-keyword cases (search "ovh02" — embeddings care about meaning, not literal tokens).

## Chosen approach: simple-jieba via SQLite extension

Load [wangfenjin/simple](https://github.com/wangfenjin/simple) — a SQLite FTS5 tokenizer extension that bundles cppjieba — at qmd startup. Schema uses `tokenize='simple'`. Indexing and querying go through the same tokenizer, so they align exactly.

**Why this beats the alternatives:**

- **Original fix, not a workaround.** qmd's internal FTS5 logic is unchanged in spirit; only the tokenizer changes. Every entry point benefits automatically.
- **Native performance.** cppjieba is C++ and runs inside the SQLite query engine. ~0.3 s for any query on a 75-doc vault.
- **OOV handling.** `simple_query()` does both jieba word segmentation and 2-char unigram fallback, so project-specific terms not in the jieba dictionary (e.g. `OpenClaw`, `iLink`) still match via raw character runs.

## The 5 patches

Applied to `~/.nvm/versions/node/.../node_modules/@tobilu/qmd/src/store.ts`:

### 1. Loader function

Inserted before `function initializeDatabase`:

```ts
function loadSimpleJiebaIfAvailable(db: Database): void {
  const extPath = Bun.env.QMD_SIMPLE_EXT || resolve(homedir(), ".local/lib/qmd/libsimple.so");
  const dictPath = Bun.env.QMD_SIMPLE_DICT || resolve(homedir(), ".local/lib/qmd/dict");
  try {
    db.loadExtension(extPath);
    db.prepare(`SELECT jieba_dict(?) AS ok`).get(dictPath);
  } catch { /* fall back to porter unicode61 */ }
}
```

The `try`/`catch` makes the patch best-effort: if `libsimple.so` is missing, qmd still starts (search just falls back).

### 2. Loader invocation

Inside `initializeDatabase`, after `sqliteVec.load(db)`:

```ts
loadSimpleJiebaIfAvailable(db);
```

### 3. FTS5 schema

```ts
- tokenize='porter unicode61'
+ tokenize='simple'
```

### 4. Query builder

The original `buildFTS5Query` quotes each whitespace-separated term and joins with `AND`. With `simple_query()` doing the heavy lifting, we just hand off the cleaned terms as raw text:

```ts
function buildFTS5Query(query: string): string | null {
  const terms = query.split(/\s+/).map(t => sanitizeFTS5Term(t)).filter(Boolean);
  if (terms.length === 0) return null;
  return terms.join(' ');
}
```

### 5. SQL MATCH wrapping

```sql
- WHERE documents_fts MATCH ? AND d.active = 1
+ WHERE documents_fts MATCH simple_query(?) AND d.active = 1
```

The crucial line. `simple_query()` is a SQL function registered by the extension. Given raw text like `'节点扩容'`, it returns a FTS5 query string like `( 节点+扩容* OR 节点扩容* )` — OR of (colocated tokens with prefix wildcard, raw run with prefix wildcard). This matches both well-segmented documents and OOV cases.

## simple_query vs jieba_query

`simple` exposes two query helpers. Empirically on this vault:

| Query | raw `MATCH ?` | `MATCH simple_query(?)` | `MATCH jieba_query(?)` |
|-------|---|---|---|
| `节点扩容` | 0 | **7** | 0 |
| `微信绑定` | 0 | **3** | 1 |
| `hermes 节点` | 2 | **4** | 2 |

`simple_query` is more forgiving (OR + prefix). `jieba_query` is strict (segment-aware AND). For a personal knowledge vault where most queries are loose recall, `simple_query` wins.

## Why patch qmd source instead of forking

A fork would require constantly rebasing against upstream and re-publishing. With a patch-script approach:

- qmd stays installed via `npm install -g @tobilu/qmd` like normal
- the patch is small (5 sites, ~30 lines of diff total) and easy to re-apply
- when upstream releases a new version, run `install.sh` again — idempotent, picks up the unpatched file and re-applies

## When the patch breaks

- **qmd refactors `initializeDatabase`** — the loader anchor disappears. `patch-qmd.py` aborts with an explicit error rather than silently producing broken state.
- **qmd switches away from FTS5** — entire approach moot, but extremely unlikely.
- **`simple` releases v0.8+ with breaking API** — `simple_query()` is a stable public API, very low risk.

#!/usr/bin/env bun
//
// Rebuild documents_fts in a qmd sqlite index using the `simple` tokenizer.
// Loads libsimple via Bun.env.QMD_SIMPLE_EXT (default ~/.local/lib/qmd/libsimple.so)
// and initializes jieba_dict from Bun.env.QMD_SIMPLE_DICT.
//
// Usage:
//   bun run rebuild-fts.ts /path/to/index.sqlite
//
import { Database } from "bun:sqlite";
import { resolve } from "node:path";
import { homedir } from "node:os";
import { existsSync } from "node:fs";

const dbPath = process.argv[2];
if (!dbPath) {
  console.error("Usage: bun run rebuild-fts.ts <path-to-sqlite>");
  process.exit(1);
}
if (!existsSync(dbPath)) {
  console.error(`ERROR: ${dbPath} does not exist`);
  process.exit(1);
}

const soDefault = resolve(homedir(), ".local/lib/qmd/libsimple.so");
const soDylib = resolve(homedir(), ".local/lib/qmd/libsimple.dylib");
const extPath = process.env.QMD_SIMPLE_EXT
  || (existsSync(soDefault) ? soDefault : soDylib);
const dictPath = process.env.QMD_SIMPLE_DICT || resolve(homedir(), ".local/lib/qmd/dict");

console.log(`    -> ${dbPath.split("/").pop()}`);

const db = new Database(dbPath);
try {
  db.loadExtension(extPath);
} catch (err) {
  console.error(`       FAILED to load ${extPath}: ${err}`);
  process.exit(1);
}
db.prepare("SELECT jieba_dict(?)").get(dictPath);

// Verify schema we expect exists
const docsTable = db.prepare(
  "SELECT name FROM sqlite_master WHERE type='table' AND name='documents'"
).get();
if (!docsTable) {
  console.log(`       (empty qmd db, nothing to rebuild)`);
  db.close();
  process.exit(0);
}

db.exec("DROP TABLE IF EXISTS documents_fts");
db.exec(`
  CREATE VIRTUAL TABLE documents_fts USING fts5(
    filepath, title, body,
    tokenize='simple'
  )
`);
db.exec(`
  INSERT INTO documents_fts(rowid, filepath, title, body)
  SELECT d.id, d.collection || '/' || d.path, d.title, c.doc
  FROM documents d
  JOIN content c ON c.hash = d.hash
  WHERE d.active = 1
`);
const result = db.prepare("SELECT COUNT(*) AS c FROM documents_fts").get() as { c: number };
console.log(`       ${result.c} rows reindexed`);
db.close();

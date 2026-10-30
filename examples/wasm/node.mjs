// xqlite.wasm in Node.js, with the database in a real file (node:fs as
// the host VFS) and in memory. Checks what it prints, so it doubles as a
// test (`zig build wasm-example`):
//
//   zig build wasm
//   node examples/wasm/node.mjs zig-out/wasm/xqlite.wasm [DIR]
//
// It leaves DIR/node.db (default: a new temporary directory), which stock
// sqlite3 can open.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import assert from "node:assert/strict";
import { load, OPEN } from "./xqlite.mjs";

// The host VFS on node:fs: a handle is a file descriptor.
export function nodeFiles() {
  return {
    open(p, flags) {
      const rw = flags & OPEN.READ_WRITE;
      let f = rw ? fs.constants.O_RDWR : fs.constants.O_RDONLY;
      if (flags & OPEN.CREATE) f |= fs.constants.O_CREAT;
      if (flags & OPEN.EXCLUSIVE) f |= fs.constants.O_EXCL;
      try {
        return fs.openSync(p, f, 0o644);
      } catch {
        return -2;
      }
    },
    close: (h) => fs.closeSync(h),
    read: (h, buf, off) => fs.readSync(h, buf, 0, buf.length, off),
    write: (h, buf, off) => {
      for (let n = 0; n < buf.length; ) n += fs.writeSync(h, buf, n, buf.length - n, off + n);
    },
    truncate: (h, size) => fs.ftruncateSync(h, size),
    sync: (h) => fs.fsyncSync(h),
    size: (h) => fs.fstatSync(h).size,
    delete: (p) => fs.rmSync(p, { force: true }),
    access: (p, mode) => {
      try {
        fs.accessSync(p, [fs.constants.F_OK, fs.constants.W_OK, fs.constants.R_OK][mode]);
        return true;
      } catch {
        return false;
      }
    },
  };
}

const [wasmPath, dirArg] = process.argv.slice(2);
const dir = dirArg ?? fs.mkdtempSync(path.join(os.tmpdir(), "xqlite-wasm-"));
const xq = await load(fs.readFileSync(wasmPath), { files: nodeFiles() });

// In memory (the default when the host supplies no files).
{
  const db = xq.open(":memory:");
  db.exec("CREATE TABLE t(a INTEGER PRIMARY KEY, b TEXT); INSERT INTO t(b) VALUES ('x'), ('y')");
  assert.deepEqual(db.query("SELECT a, b FROM t WHERE a > ?", [1]), [{ a: 2, b: "y" }]);
  assert.deepEqual(db.query("SELECT 2.5 * 2 AS f, x'0102' AS g, NULL AS n"), [{ f: 5, g: new Uint8Array([1, 2]), n: null }]);
  assert.throws(() => db.exec("SELECT * FROM nope"), /no such table: nope/);
  db.close();
}

// The dialects, by pragma and by name.
{
  const db = xq.open(":memory:");
  db.exec("PRAGMA xq_dialect = 'postgres'");
  assert.deepEqual(db.query("SELECT 7 / 2 AS q, 'a' || 1::text AS s"), [{ q: 3, s: "a1" }]);
  db.setDialect("mariadb");
  assert.deepEqual(db.query("SELECT CONCAT('a', 'b') AS c"), [{ c: "ab" }]);
  db.setDialect("mssql");
  assert.deepEqual(db.query("SELECT TOP 1 'x' + 'y' AS c"), [{ c: "xy" }]);
  db.setDialect("oracle");
  // Oracle folds unquoted names to upper case.
  assert.deepEqual(db.query("SELECT NVL('', 'empty') AS c FROM dual"), [{ C: "empty" }]);
  db.close();
}

// A file through node:fs: rollback journal, then WAL, then reopen.
const file = path.join(dir, "node.db");
fs.rmSync(file, { force: true });
{
  const db = xq.open(file, { host: true });
  db.exec("CREATE TABLE kv(k TEXT PRIMARY KEY, v)");
  db.exec("BEGIN; INSERT INTO kv VALUES ('a', 1); INSERT INTO kv VALUES ('b', 2); COMMIT");
  db.exec("BEGIN; INSERT INTO kv VALUES ('c', 3); ROLLBACK");
  assert.deepEqual(db.query("PRAGMA journal_mode = wal"), [{ journal_mode: "wal" }]);
  db.exec("INSERT INTO kv VALUES ('d', 4)");
  // A second connection of this instance sees the WAL (in-process shm).
  const db2 = xq.open(file, { host: true });
  assert.deepEqual(db2.query("SELECT count(*) AS n FROM kv"), [{ n: 3 }]);
  db2.close();
  db.close();
}
{
  const db = xq.open(file, { host: true });
  assert.deepEqual(db.query("SELECT group_concat(k || v, ',') AS s FROM kv"), [{ s: "a1,b2,d4" }]);
  assert.deepEqual(db.query("PRAGMA integrity_check"), [{ integrity_check: "ok" }]);
  db.exec("PRAGMA journal_mode = delete");
  db.close();
}
console.log(`ok: memory, dialects, journal, WAL, reopen (${file})`);

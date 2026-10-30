// JavaScript glue for zig-out/wasm/xqlite.wasm (`zig build wasm`), for
// Node.js and browsers. It supplies the imports of the module (the clock,
// randomness and, optionally, a file system) and wraps the xq_* exports
// in a small Database class. The contract is in docs/wasm.md.
//
//   import { load } from "./xqlite.mjs";
//   const xq = await load(wasmBytes, { files });   // files: optional
//   const db = xq.open("app.db", { host: true });  // host: false = memory
//   db.exec("CREATE TABLE t(a, b)");
//   db.query("SELECT * FROM t WHERE a > ?", [1]);  // [{a: ..., b: ...}]
//   db.close();
//
// `files` is the host file system (see nodeFiles() in node.mjs and
// opfsFiles() in browser/worker.mjs): open(path, flags) -> handle >= 0 or
// a negative error, close(h), read(h, bytes, offset) -> count,
// write(h, bytes, offset), truncate(h, size), sync(h, flags), size(h),
// delete(path), access(path, mode) -> 0/1, and optionally lock(h, level)
// -> 0 or 5 (busy). Errors are negative: -1 I/O, -2 cannot open,
// -3 read-only, -4 disk full, -5 busy. Without `files` only memory
// databases work.

const ROW = 100;
const DONE = 101;

/// Open flags given to files.open() (OpenBits in pkg/vfs/src/host.zig).
export const OPEN = { READ_WRITE: 1, CREATE: 2, EXCLUSIVE: 4, DELETE_ON_CLOSE: 8 };

export async function load(wasm, { files } = {}) {
  let ex; // the exports, once instantiated
  const mem = () => new Uint8Array(ex.memory.buffer);
  const dec = new TextDecoder();
  const enc = new TextEncoder();
  const str = (p, n) => dec.decode(mem().subarray(p, p + n));
  const guard = (f) => (...a) => {
    try {
      return f(...a);
    } catch (e) {
      return -1;
    }
  };
  const nofile = () => -2;
  const fs = files ?? {};
  const env = {
    xq_host_now_ms: () => Date.now(),
    xq_host_random: (p, n) => {
      for (let i = 0; i < n; i += 65536) crypto.getRandomValues(mem().subarray(p + i, p + Math.min(n, i + 65536)));
    },
    xq_host_open: files ? guard((p, n, flags) => fs.open(str(p, n), flags)) : nofile,
    xq_host_close: (h) => fs.close?.(h),
    xq_host_read: guard((h, p, n, off) => fs.read(h, mem().subarray(p, p + n), off)),
    xq_host_write: guard((h, p, n, off) => (fs.write(h, mem().subarray(p, p + n), off), 0)),
    xq_host_truncate: guard((h, size) => (fs.truncate(h, size), 0)),
    xq_host_sync: guard((h, flags) => (fs.sync?.(h, flags), 0)),
    xq_host_size: guard((h) => fs.size(h)),
    xq_host_delete: files ? guard((p, n) => (fs.delete(str(p, n)), 0)) : () => 0,
    xq_host_access: files ? guard((p, n, mode) => (fs.access(str(p, n), mode) ? 1 : 0)) : () => 0,
    xq_host_lock: (h, level) => fs.lock?.(h, level) ?? 0,
  };
  const { instance } = await WebAssembly.instantiate(wasm, { env });
  ex = instance.exports;

  // A string in wasm memory for the duration of f(ptr, len).
  const withString = (s, f) => {
    const bytes = enc.encode(s);
    const p = ex.xq_malloc(bytes.length);
    mem().set(bytes, p);
    try {
      return f(p, bytes.length);
    } finally {
      ex.xq_free(p, bytes.length);
    }
  };
  const cstr = (p) => {
    const m = mem();
    let e = p;
    while (m[e]) e++;
    return dec.decode(m.subarray(p, e));
  };

  class XqError extends Error {
    constructor(code, message) {
      super(message);
      this.code = code;
    }
  }

  class Database {
    constructor(path, { host = false, readOnly = false } = {}) {
      this.h = withString(path, (p, n) => ex.xq_open(p, n, (readOnly ? 1 : 0) | (host ? 2 : 0)));
      if (!this.h) throw new XqError(7, "out of memory");
      if (ex.xq_errcode(this.h) !== 0) {
        const err = this.#error(ex.xq_errcode(this.h));
        ex.xq_close(this.h);
        throw err;
      }
    }
    #error(code) {
      return new XqError(code, cstr(ex.xq_errmsg(this.h)));
    }
    #check(rc) {
      if (rc !== 0 && rc !== ROW && rc !== DONE) throw this.#error(rc);
      return rc;
    }
    exec(sql) {
      this.#check(withString(sql, (p, n) => ex.xq_exec(this.h, p, n)));
    }
    setDialect(name) {
      this.#check(withString(name, (p, n) => ex.xq_set_dialect(this.h, p, n)));
    }
    // One statement: the rows as objects keyed by column name.
    query(sql, params = []) {
      const s = withString(sql, (p, n) => ex.xq_prepare(this.h, p, n));
      if (!s) throw this.#error(ex.xq_errcode(this.h));
      try {
        params.forEach((v, i) => this.#check(this.#bind(s, i + 1, v)));
        const rows = [];
        const ncol = ex.xq_column_count(s);
        const names = Array.from({ length: ncol }, (_, i) => cstr(ex.xq_column_name(s, i)));
        while (this.#check(ex.xq_step(s)) === ROW) {
          const row = {};
          for (let i = 0; i < ncol; i++) row[names[i]] = column(s, i);
          rows.push(row);
        }
        return rows;
      } finally {
        ex.xq_finalize(s);
      }
    }
    #bind(s, i, v) {
      if (v === null || v === undefined) return ex.xq_bind_null(s, i);
      if (typeof v === "bigint") return ex.xq_bind_int64(s, i, v);
      if (typeof v === "number") return Number.isInteger(v) ? ex.xq_bind_int64(s, i, BigInt(v)) : ex.xq_bind_double(s, i, v);
      return withString(String(v), (p, n) => ex.xq_bind_text(s, i, p, n));
    }
    close() {
      this.#check(ex.xq_close(this.h));
      this.h = 0;
    }
  }

  function column(s, i) {
    switch (ex.xq_column_type(s, i)) {
      case 1: {
        const v = ex.xq_column_int64(s, i);
        return Number.isSafeInteger(Number(v)) ? Number(v) : v;
      }
      case 2:
        return ex.xq_column_double(s, i);
      case 3:
        return str(ex.xq_column_text(s, i), ex.xq_column_bytes(s, i));
      case 4: {
        const p = ex.xq_column_text(s, i);
        return mem().slice(p, p + ex.xq_column_bytes(s, i));
      }
      default:
        return null;
    }
  }

  return { open: (path, opts) => new Database(path, opts), XqError, exports: ex };
}

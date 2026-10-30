// xqlite.wasm in a browser worker, with the database in the Origin
// Private File System. The host VFS is synchronous, and OPFS sync access
// handles can only be created asynchronously, so opfsFiles() opens the
// handles of a database (and its journal and WAL) before the database is
// opened; a "deleted" file is one truncated to nothing.

import { load } from "../xqlite.mjs";

export async function opfsFiles(dir, names) {
  const files = new Map(); // name -> { h: FileSystemSyncAccessHandle, exists }
  for (const name of names) {
    const fh = await dir.getFileHandle(name, { create: true });
    const h = await fh.createSyncAccessHandle();
    files.set(name, { h, exists: h.getSize() > 0 });
  }
  const open = []; // handle -> entry
  return {
    open(name, flags) {
      const f = files.get(name);
      if (!f || (!f.exists && !(flags & 2))) return -2;
      f.exists = true;
      open.push(f);
      return open.length - 1;
    },
    close() {},
    read: (h, buf, off) => open[h].h.read(buf, { at: off }),
    write: (h, buf, off) => open[h].h.write(buf, { at: off }),
    truncate: (h, size) => open[h].h.truncate(size),
    sync: (h) => open[h].h.flush(),
    size: (h) => open[h].h.getSize(),
    delete(name) {
      const f = files.get(name);
      if (f) {
        f.h.truncate(0);
        f.exists = false;
      }
    },
    access: (name) => files.get(name)?.exists ?? false,
  };
}

const log = (line) => postMessage(line);
try {
  const dir = await navigator.storage.getDirectory();
  const files = await opfsFiles(dir, ["demo.db", "demo.db-journal", "demo.db-wal"]);
  const xq = await load(await (await fetch("../../../zig-out/wasm/xqlite.wasm")).arrayBuffer(), { files });
  const db = xq.open("demo.db", { host: true });
  db.exec("CREATE TABLE IF NOT EXISTS visits(at TEXT)");
  db.exec("INSERT INTO visits VALUES (datetime('now'))");
  log(`visits: ${db.query("SELECT count(*) AS n FROM visits")[0].n}`);
  db.exec("PRAGMA xq_dialect = 'postgres'");
  log(`postgres: ${JSON.stringify(db.query("SELECT 7 / 2 AS q, 'a' || 1::text AS s"))}`);
  log(`integrity_check: ${db.query("PRAGMA integrity_check")[0].integrity_check}`);
  db.close();
} catch (e) {
  log(`error: ${e.message}`);
}

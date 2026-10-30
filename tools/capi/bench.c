/* Insert benchmark for libxqlite3: a prepared INSERT bound, stepped and
 * reset in one transaction on ":memory:", then a check of the rows.
 * `bench [N]` (default 300000). `zig build capi-bench` runs it
 * against the ReleaseFast static library several times. */
#include <stdio.h>
#include <stdlib.h>
#include "sqlite3.h"

#define CK(x)                                                                         \
    do {                                                                              \
        int rc_ = (x);                                                                \
        if (rc_ != SQLITE_OK && rc_ != SQLITE_DONE) {                                 \
            fprintf(stderr, "%s:%d rc=%d %s\n", __FILE__, __LINE__, rc_,              \
                    sqlite3_errmsg(db));                                              \
            return 1;                                                                 \
        }                                                                             \
    } while (0)

int main(int argc, char **argv) {
    int n = argc > 1 ? atoi(argv[1]) : 300000;
    sqlite3 *db = 0;
    sqlite3_stmt *st = 0;
    char buf[64];
    long long c, s;
    CK(sqlite3_open(":memory:", &db));
    CK(sqlite3_exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, a INTEGER, b TEXT, c REAL)", 0, 0, 0));
    CK(sqlite3_exec(db, "BEGIN", 0, 0, 0));
    CK(sqlite3_prepare_v2(db, "INSERT INTO t(a,b,c) VALUES(?,?,?)", -1, &st, 0));
    for (int i = 0; i < n; i++) {
        snprintf(buf, sizeof buf, "row-%d", i);
        CK(sqlite3_bind_int64(st, 1, i));
        CK(sqlite3_bind_text(st, 2, buf, -1, SQLITE_TRANSIENT));
        CK(sqlite3_bind_double(st, 3, i * 0.5));
        int rc = sqlite3_step(st);
        if (rc != SQLITE_DONE) {
            fprintf(stderr, "step %d rc=%d %s\n", i, rc, sqlite3_errmsg(db));
            return 1;
        }
        CK(sqlite3_reset(st));
    }
    CK(sqlite3_finalize(st));
    CK(sqlite3_exec(db, "COMMIT", 0, 0, 0));
    CK(sqlite3_prepare_v2(db, "SELECT count(*), sum(a) FROM t", -1, &st, 0));
    if (sqlite3_step(st) != SQLITE_ROW) return 2;
    c = sqlite3_column_int64(st, 0);
    s = sqlite3_column_int64(st, 1);
    sqlite3_finalize(st);
    CK(sqlite3_close(db));
    if (c != n || s != (long long)n * (n - 1) / 2) {
        fprintf(stderr, "bad count/sum %lld %lld\n", c, s);
        return 3;
    }
    printf("ok %lld\n", c);
    return 0;
}

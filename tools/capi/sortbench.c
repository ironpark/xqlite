/* Sorter benchmark: ORDER BY, GROUP BY and CREATE INDEX on 300000
 * random rows, each query's rows stepped through and hashed in order, so
 * that two builds can be compared for both speed and output.
 *
 *   sortbench [-n ROWS] [-spill] [-ref FILE]
 *
 * -spill makes the cache 10 pages, so that the sorts write PMAs and
 * merge them. -ref FILE is the output of another run (of the benchmark
 * built on SQLite's sqlite3.c): every hash must be the same, and each
 * line gets the time ratio. `zig build capi-sortbench` builds it on the
 * ReleaseFast static libxqlite3 and on sqlite3.c, and runs both. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "sqlite3.h"

/* The lines of the -ref file, in order. */
static char ref_lines[64][128];
static int n_ref, i_ref, n_mismatch;

static double now(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static int exec(sqlite3 *db, const char *sql) {
    char *err = 0;
    if (sqlite3_exec(db, sql, 0, 0, &err) != SQLITE_OK) {
        fprintf(stderr, "%s: %s\n", sql, err);
        return 1;
    }
    return 0;
}

static unsigned long long hashBytes(unsigned long long h, const void *p, int n) {
    const unsigned char *b = p;
    for (int i = 0; i < n; i++) h = (h ^ b[i]) * 1099511628211ULL;
    return h;
}

/* Print one result, and compare it with the same line of the -ref file:
 * "NAME  TIME ms  HASH". */
static void report(const char *name, double ms, const char *hash) {
    char line[128];
    snprintf(line, sizeof line, "%-22s %8.1f ms  %s", name, ms, hash);
    if (i_ref >= n_ref) {
        printf("%s\n", line);
        return;
    }
    const char *ref = ref_lines[i_ref++];
    double ref_ms = strtod(ref + 22, 0);
    const char *ref_hash = strstr(ref, " ms  ");
    ref_hash = ref_hash ? ref_hash + 5 : "";
    /* The hash ends the line, or the ratio of a run with -ref follows. */
    size_t n_hash = strlen(hash);
    int same = strncmp(ref, line, 22) == 0 && strncmp(ref_hash, hash, n_hash) == 0 &&
               (ref_hash[n_hash] == 0 || ref_hash[n_hash] == ' ');
    if (!same) n_mismatch++;
    printf("%s  x%.2f%s\n", line, ref_ms > 0 ? ms / ref_ms : 0, same ? "" : "  DIFFERENT");
}

static int run(sqlite3 *db, const char *name, const char *sql, int reps) {
    double best = 1e9;
    unsigned long long h = 0;
    for (int r = 0; r < reps; r++) {
        sqlite3_stmt *st;
        if (sqlite3_prepare_v2(db, sql, -1, &st, 0) != SQLITE_OK) {
            fprintf(stderr, "%s: %s\n", sql, sqlite3_errmsg(db));
            return 1;
        }
        double t0 = now();
        h = 1469598103934665603ULL;
        int rc;
        while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
            for (int i = 0; i < sqlite3_column_count(st); i++) {
                int ty = sqlite3_column_type(st, i);
                h = hashBytes(h, &ty, sizeof ty);
                if (ty == SQLITE_INTEGER) {
                    sqlite3_int64 v = sqlite3_column_int64(st, i);
                    h = hashBytes(h, &v, sizeof v);
                } else if (ty == SQLITE_FLOAT) {
                    double v = sqlite3_column_double(st, i);
                    h = hashBytes(h, &v, sizeof v);
                } else if (ty != SQLITE_NULL) {
                    const void *b = sqlite3_column_blob(st, i);
                    h = hashBytes(h, b, sqlite3_column_bytes(st, i));
                }
            }
        }
        double t = now() - t0;
        if (rc != SQLITE_DONE) {
            fprintf(stderr, "%s: %s\n", name, sqlite3_errmsg(db));
            return 1;
        }
        sqlite3_finalize(st);
        if (t < best) best = t;
    }
    char hash[17];
    snprintf(hash, sizeof hash, "%016llx", h);
    report(name, best * 1000, hash);
    return 0;
}

int main(int argc, char **argv) {
    int n = 300000, spill = 0;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "-n") == 0 && i + 1 < argc) {
            n = atoi(argv[++i]);
        } else if (strcmp(argv[i], "-spill") == 0) {
            spill = 1;
        } else if (strcmp(argv[i], "-ref") == 0 && i + 1 < argc) {
            FILE *f = fopen(argv[++i], "r");
            if (!f) {
                perror(argv[i]);
                return 1;
            }
            while (n_ref < 64 && fgets(ref_lines[n_ref], sizeof ref_lines[0], f)) {
                ref_lines[n_ref][strcspn(ref_lines[n_ref], "\n")] = 0;
                if (ref_lines[n_ref][0] != '#') n_ref++;
            }
            fclose(f);
        } else {
            fprintf(stderr, "usage: sortbench [-n ROWS] [-spill] [-ref FILE]\n");
            return 1;
        }
    }
    sqlite3 *db;
    if (sqlite3_open(":memory:", &db) != SQLITE_OK) return 1;
    if (exec(db, spill ? "PRAGMA cache_size=10" : "PRAGMA cache_size=-262144")) return 1;
    printf("# %s, %d rows%s\n", sqlite3_libversion(), n, spill ? ", spilling" : "");
    if (exec(db, "CREATE TABLE t(i INT, r REAL, s TEXT, l TEXT, b BLOB, m, g INT)")) return 1;
    sqlite3_stmt *ins;
    if (sqlite3_prepare_v2(db, "INSERT INTO t VALUES(?,?,?,?,?,?,?)", -1, &ins, 0)) return 1;
    exec(db, "BEGIN");
    unsigned long long x = 88172645463325252ULL;
#define RND() (x ^= x << 13, x ^= x >> 7, x ^= x << 17, x)
    char buf[64];
    unsigned char blob[16];
    for (int k = 1; k <= n; k++) {
        sqlite3_bind_int64(ins, 1, RND() % 1000000);
        sqlite3_bind_double(ins, 2, (double)(long long)RND() / 1e12);
        int len = 8 + RND() % 16;
        for (int j = 0; j < len; j++) buf[j] = "0123456789abcdef"[RND() % 16];
        sqlite3_bind_text(ins, 3, buf, len, SQLITE_TRANSIENT);
        char l[64];
        snprintf(l, sizeof l, "prefix-common-%012llx", RND() % 0xffffffffffffULL);
        sqlite3_bind_text(ins, 4, l, -1, SQLITE_TRANSIENT);
        int bl = 1 + RND() % 12;
        for (int j = 0; j < bl; j++) blob[j] = RND();
        sqlite3_bind_blob(ins, 5, blob, bl, SQLITE_TRANSIENT);
        switch (k % 5) {
        case 0: sqlite3_bind_null(ins, 6); break;
        case 1: sqlite3_bind_int64(ins, 6, (long long)(RND() % 2000000) - 1000000); break;
        case 2: sqlite3_bind_double(ins, 6, (double)(long long)(RND() % 2000000) * 0.5 - 500000); break;
        case 3: snprintf(buf, sizeof buf, "%llX", RND() % 100000); sqlite3_bind_text(ins, 6, buf, -1, SQLITE_TRANSIENT); break;
        default: blob[0] = RND(); blob[1] = RND(); blob[2] = RND(); sqlite3_bind_blob(ins, 6, blob, 3, SQLITE_TRANSIENT); break;
        }
        sqlite3_bind_int64(ins, 7, k % 100);
        if (sqlite3_step(ins) != SQLITE_DONE) return 1;
        sqlite3_reset(ins);
    }
    sqlite3_finalize(ins);
    exec(db, "COMMIT");
    int reps = 5;
    if (run(db, "int", "SELECT i FROM t ORDER BY i", reps)) return 1;
    if (run(db, "int desc", "SELECT i FROM t ORDER BY i DESC", reps)) return 1;
    if (run(db, "real", "SELECT r FROM t ORDER BY r", reps)) return 1;
    if (run(db, "text", "SELECT s FROM t ORDER BY s", reps)) return 1;
    if (run(db, "text common prefix", "SELECT l FROM t ORDER BY l", reps)) return 1;
    if (run(db, "text nocase", "SELECT s FROM t ORDER BY s COLLATE NOCASE", reps)) return 1;
    if (run(db, "blob", "SELECT b FROM t ORDER BY b", reps)) return 1;
    if (run(db, "mixed", "SELECT m FROM t ORDER BY m", reps)) return 1;
    if (run(db, "mixed nulls last", "SELECT m FROM t ORDER BY m NULLS LAST", reps)) return 1;
    if (run(db, "mixed desc nulls 1st", "SELECT m FROM t ORDER BY m DESC NULLS FIRST", reps)) return 1;
    if (run(db, "int,text", "SELECT g, s FROM t ORDER BY g, s", reps)) return 1;
    if (run(db, "text desc,int", "SELECT s, i FROM t ORDER BY s DESC, i", reps)) return 1;
    if (run(db, "group by text", "SELECT s, count(*) FROM t GROUP BY s", reps)) return 1;
    if (run(db, "distinct-ish m", "SELECT m, count(*) FROM t GROUP BY m", reps)) return 1;
    if (run(db, "group by int", "SELECT g, count(*), max(s) FROM t GROUP BY g", reps)) return 1;
    double t0 = now();
    if (exec(db, "CREATE INDEX ts ON t(s); CREATE INDEX tm ON t(m); CREATE INDEX tl ON t(l DESC);")) return 1;
    report("create 3 indexes", (now() - t0) * 1000, "");
    if (run(db, "integrity", "PRAGMA integrity_check", 1)) return 1;
    if (run(db, "index order", "SELECT s, m, l FROM t INDEXED BY tl ORDER BY l DESC", 1)) return 1;
    sqlite3_close(db);
    if (n_mismatch) {
        fprintf(stderr, "sortbench: %d results differ from the reference\n", n_mismatch);
        return 1;
    }
    return 0;
}

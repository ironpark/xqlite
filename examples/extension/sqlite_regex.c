/*
** Loading a third-party SQLite extension into xqlite through the C ABI:
** sqlite-regex (https://github.com/asg017/sqlite-regex), Rust's regex
** crate as SQL functions and table-valued functions. The extension is
** built against sqlite3ext.h and calls through sqlite3_api_routines, so
** it loads into libxqlite3 unchanged, as it would into libsqlite3.
**
**     # regex0.dylib (macOS) or regex0.so (Linux) from a release:
**     # https://github.com/asg017/sqlite-regex/releases
**     zig build example-sqlite-regex-c -- ./regex0
**
** The argument is the library, with or without its suffix (default
** "regex0", which the dynamic loader looks for on its path). The
** entry point is sqlite3_regex_init, the name sqlite3_load_extension()
** derives from the file name. docs/load-extension.md has the rest.
*/
#include <stdio.h>
#include <stdlib.h>

#include "sqlite3.h"
#include "xqlite.h"

/* Print each row of `sql` as tab-separated columns. */
static int show(sqlite3 *db, const char *sql) {
    sqlite3_stmt *st;
    printf("%s\n", sql);
    if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) {
        printf("  error: %s\n", sqlite3_errmsg(db));
        return 1;
    }
    int rc;
    while ((rc = sqlite3_step(st)) == SQLITE_ROW) {
        printf("  ");
        for (int i = 0; i < sqlite3_column_count(st); i++) {
            const unsigned char *v = sqlite3_column_text(st, i);
            printf("%s%s", i ? "\t" : "", v ? (const char *)v : "NULL");
        }
        printf("\n");
    }
    if (rc != SQLITE_DONE) printf("  error: %s\n", sqlite3_errmsg(db));
    sqlite3_finalize(st);
    return rc != SQLITE_DONE;
}

/* Load the extension into `db`. */
static int load(sqlite3 *db, const char *path) {
    char *err = NULL;
    sqlite3_enable_load_extension(db, 1);
    int rc = sqlite3_load_extension(db, path, NULL, &err);
    sqlite3_enable_load_extension(db, 0);
    if (rc != SQLITE_OK) {
        fprintf(stderr, "cannot load %s: %s\n", path, err ? err : sqlite3_errstr(rc));
        sqlite3_free(err);
    }
    return rc;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "regex0";
    sqlite3 *db;
    int failed = 0;

    /* The SQLite dialect. */
    if (sqlite3_open(":memory:", &db) != SQLITE_OK) return 1;
    if (load(db, path) != SQLITE_OK) return 1;
    printf("-- dialect %s\n", xqlite_dialect(db));
    failed |= show(db, "SELECT regex_version()");
    failed |= show(db, "SELECT 'foo' REGEXP 'f', 'foo' REGEXP '^o'");
    failed |= show(db, "SELECT regex_find('[0-9]{3}-[0-9]{3}-[0-9]{4}', 'phone: 111-222-3333')");
    failed |= show(db,
        "SELECT rowid, start, end, match FROM regex_find_all('\\b\\w{13}\\b', "
        "'Retroactively relinquishing remunerations is reprehensible.')");
    failed |= show(db,
        "SELECT regex_capture(captures, 'title') AS title, regex_capture(captures, 'year') AS year "
        "FROM regex_captures(regex('''(?P<title>[^'']+)''\\s+\\((?P<year>\\d{4})\\)'), "
        "'''Citizen Kane'' (1941), ''The Wizard of Oz'' (1939), ''M'' (1931).')");
    failed |= show(db, "SELECT regexset_is_match(regexset('bar', 'foo', 'barfoo'), 'foobar')");
    failed |= show(db, "SELECT rowid, item FROM regex_split('[ \\t]+', 'a b     c d    e')");
    failed |= show(db,
        "SELECT regex_replace('(?P<last>[^,\\s]+),\\s+(?P<first>\\S+)', 'Springsteen, Bruce', '$first $last')");

    /* In a table: a CHECK constraint and an index on an expression. The
    ** schema then needs the extension in every connection that writes it,
    ** as it would in sqlite3. */
    sqlite3_exec(db,
        "CREATE TABLE users(email TEXT CHECK (email REGEXP '^[^@\\s]+@[^@\\s]+$'));"
        "CREATE INDEX users_domain ON users(regex_find('@.*$', email));"
        "INSERT INTO users VALUES ('ann@example.com'), ('bob@example.org'), ('cy@example.com');",
        NULL, NULL, NULL);
    failed |= show(db, "SELECT email FROM users WHERE regex_find('@.*$', email) = '@example.com'");
    /* A row the CHECK refuses: an error, on purpose. */
    printf("INSERT INTO users VALUES ('not an email')\n  %s\n",
           sqlite3_exec(db, "INSERT INTO users VALUES ('not an email')", NULL, NULL, NULL) == SQLITE_CONSTRAINT
               ? sqlite3_errmsg(db)
               : "(accepted?)");
    sqlite3_close(db);

    /* The PostgreSQL dialect: the extension's functions are called as
    ** any function is, next to the dialect's own ~ operator. */
    if (sqlite3_open_v2("file::memory:?dialect=postgres", &db,
                        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_URI, NULL) != SQLITE_OK)
        return 1;
    if (load(db, path) != SQLITE_OK) return 1;
    printf("-- dialect %s\n", xqlite_dialect(db));
    failed |= show(db,
        "SELECT regex_replace_all('[aeiou]', 'xqlite speaks postgres', '_') AS r, "
        "'xqlite' ~ '^xq' AS pg_match");
    failed |= show(db,
        "SELECT item FROM regex_split(',\\s*', 'one, two,three') ORDER BY item DESC");
    sqlite3_close(db);

    return failed;
}

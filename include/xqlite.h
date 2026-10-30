/*
** xqlite's extensions to the sqlite3 C API (libxqlite3; see
** docs/c-api.md). Include it after sqlite3.h.
**
** The SQL dialect of a connection can also be chosen when it is opened,
** with the dialect= parameter of a URI filename (SQLITE_OPEN_URI):
**
**     sqlite3_open_v2("file:app.db?dialect=postgres", &db,
**                     SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_URI, 0);
**
** and with SQL: PRAGMA xq_dialect = 'mariadb'.
*/
#ifndef XQLITE_H
#define XQLITE_H

#include "sqlite3.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
** Make zName the SQL dialect of the statements prepared on db from now
** on: "sqlite", "postgres", "mariadb", "mssql" or "oracle" (any case),
** or an alias: "pg", "postgresql", "mysql", "sqlserver", "tsql".
** Statements prepared before keep theirs. Returns SQLITE_OK, or
** SQLITE_ERROR (with an error message on db) for an unknown name.
*/
int xqlite_set_dialect(sqlite3 *db, const char *zName);

/* The name of the SQL dialect of db ("sqlite", "postgres", ...). */
const char *xqlite_dialect(sqlite3 *db);

#ifdef __cplusplus
}
#endif

#endif /* XQLITE_H */

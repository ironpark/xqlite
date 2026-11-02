/*
** The C side of the xqlite loadable extension (src/loadable/root.zig,
** docs/extension.md): the entry points sqlite3_load_extension() calls,
** and the part of the sqlite3_api_routines table the Zig adapter uses,
** as small functions. Every call goes through the table the loader hands
** to the entry point (sqlite3ext.h's macros), so the library links
** against no SQLite: it works with whatever SQLite loads it (the system
** sqlite3, Python's sqlite3, xqlite's own C ABI).
**
** It is in C because the table is a C struct of ~270 function pointers
** whose order is the ABI: sqlite3ext.h gives it right by construction,
** as for src/capi/loadext.c.
**
** The entry points are the only symbols the library exports:
**   sqlite3_xqliteext_init   what sqlite3_load_extension() derives from
**                            the file name libxqlite_ext.{so,dylib}, and
**                            the name to give it explicitly;
**   sqlite3_extension_init   the default it tries first.
** Everything else here is hidden.
*/
#include "sqlite3ext.h"
SQLITE_EXTENSION_INIT1

#define XQE __attribute__((visibility("hidden")))
#if defined(_WIN32)
#define XQE_EXPORT __declspec(dllexport)
#else
#define XQE_EXPORT __attribute__((visibility("default")))
#endif

/* The Zig adapter: register everything on db (root.zig's register()). */
extern int xqe_register(sqlite3 *db, char **pzErrMsg);

/* ------------------------------------------------------------- values */

XQE int xqe_value_type(sqlite3_value *v){ return sqlite3_value_type(v); }
XQE sqlite3_int64 xqe_value_int64(sqlite3_value *v){ return sqlite3_value_int64(v); }
XQE double xqe_value_double(sqlite3_value *v){ return sqlite3_value_double(v); }
XQE const unsigned char *xqe_value_text(sqlite3_value *v){ return sqlite3_value_text(v); }
XQE const void *xqe_value_blob(sqlite3_value *v){ return sqlite3_value_blob(v); }
XQE int xqe_value_bytes(sqlite3_value *v){ return sqlite3_value_bytes(v); }
XQE unsigned int xqe_value_subtype(sqlite3_value *v){ return sqlite3_value_subtype(v); }

/* ------------------------------------------------------------ results */

XQE void xqe_result_null(sqlite3_context *c){ sqlite3_result_null(c); }
XQE void xqe_result_int64(sqlite3_context *c, sqlite3_int64 v){ sqlite3_result_int64(c, v); }
XQE void xqe_result_double(sqlite3_context *c, double v){ sqlite3_result_double(c, v); }
XQE void xqe_result_text(sqlite3_context *c, const char *z, sqlite3_uint64 n){
  sqlite3_result_text64(c, z, n, SQLITE_TRANSIENT, SQLITE_UTF8);
}
XQE void xqe_result_blob(sqlite3_context *c, const void *z, sqlite3_uint64 n){
  sqlite3_result_blob64(c, z, n, SQLITE_TRANSIENT);
}
XQE void xqe_result_zeroblob(sqlite3_context *c, sqlite3_uint64 n){ sqlite3_result_zeroblob64(c, n); }
XQE void xqe_result_subtype(sqlite3_context *c, unsigned int t){ sqlite3_result_subtype(c, t); }
XQE void xqe_result_error(sqlite3_context *c, const char *z, int n){ sqlite3_result_error(c, z, n); }
XQE void xqe_result_error_code(sqlite3_context *c, int rc){ sqlite3_result_error_code(c, rc); }
XQE void xqe_result_error_nomem(sqlite3_context *c){ sqlite3_result_error_nomem(c); }
XQE void xqe_result_error_toobig(sqlite3_context *c){ sqlite3_result_error_toobig(c); }

/* ------------------------------------------------------------ context */

XQE void *xqe_user_data(sqlite3_context *c){ return sqlite3_user_data(c); }
XQE void *xqe_aggregate_context(sqlite3_context *c, int n){ return sqlite3_aggregate_context(c, n); }
XQE sqlite3 *xqe_context_db_handle(sqlite3_context *c){ return sqlite3_context_db_handle(c); }

/* ------------------------------------------------------- registration */

typedef void (*XqeStep)(sqlite3_context*, int, sqlite3_value**);
typedef void (*XqeFinal)(sqlite3_context*);
typedef int (*XqeCmp)(void*, int, const void*, int, const void*);

XQE int xqe_create_function(sqlite3 *db, const char *zName, int nArg, int flags,
    void *pApp, XqeStep xFunc, XqeStep xStep, XqeFinal xFinal, void (*xDestroy)(void*)){
  return sqlite3_create_function_v2(db, zName, nArg, flags, pApp, xFunc, xStep, xFinal, xDestroy);
}
XQE int xqe_create_window_function(sqlite3 *db, const char *zName, int nArg, int flags,
    void *pApp, XqeStep xStep, XqeFinal xFinal, XqeFinal xValue, XqeStep xInverse,
    void (*xDestroy)(void*)){
  return sqlite3_create_window_function(db, zName, nArg, flags, pApp, xStep, xFinal, xValue, xInverse, xDestroy);
}
XQE int xqe_create_collation(sqlite3 *db, const char *zName, void *pArg, XqeCmp xCmp){
  return sqlite3_create_collation_v2(db, zName, SQLITE_UTF8, pArg, xCmp, 0);
}
XQE int xqe_libversion_number(void){ return sqlite3_libversion_number(); }
XQE const char *xqe_errmsg(sqlite3 *db){ return sqlite3_errmsg(db); }

/* *pzErrMsg = z, in memory of sqlite3_malloc() as the loader frees it. */
XQE void xqe_set_errmsg(char **pzErrMsg, const char *z){
  if( pzErrMsg ) *pzErrMsg = sqlite3_mprintf("%s", z);
}

/* ---------------------------------------------- statements (sequences) */

XQE int xqe_prepare(sqlite3 *db, const char *zSql, int n, sqlite3_stmt **pp){
  return sqlite3_prepare_v2(db, zSql, n, pp, 0);
}
XQE int xqe_step(sqlite3_stmt *p){ return sqlite3_step(p); }
XQE int xqe_finalize(sqlite3_stmt *p){ return sqlite3_finalize(p); }
XQE int xqe_bind_text(sqlite3_stmt *p, int i, const char *z, int n){
  return sqlite3_bind_text(p, i, z, n, SQLITE_TRANSIENT);
}
XQE int xqe_bind_int64(sqlite3_stmt *p, int i, sqlite3_int64 v){ return sqlite3_bind_int64(p, i, v); }
XQE sqlite3_int64 xqe_column_int64(sqlite3_stmt *p, int i){ return sqlite3_column_int64(p, i); }

/* ------------------------------------------------------- entry points */

XQE_EXPORT int sqlite3_xqliteext_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi){
  SQLITE_EXTENSION_INIT2(pApi);
  return xqe_register(db, pzErrMsg);
}

XQE_EXPORT int sqlite3_extension_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi){
  return sqlite3_xqliteext_init(db, pzErrMsg, pApi);
}

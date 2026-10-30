/*
** A loadable extension for tools/capi/capi_test.c, written as any
** extension built against sqlite3ext.h is: every call goes through the
** sqlite3_api_routines table the loader hands to the entry point. `zig
** build test-capi` builds it as libxqexttest.so (.dylib) and passes its
** path to capi_test.
**
** There is no sqlite3_extension_init: the loader must find the entry
** point by the name it derives from the file, sqlite3_xqexttest_init.
*/
#include "sqlite3ext.h"
SQLITE_EXTENSION_INIT1

/* xq_ext_hello(X): 'hello X', made with sqlite3_mprintf(). */
static void helloFunc(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  const char *zPrefix = (const char*)sqlite3_user_data(ctx);
  char *z;
  (void)argc;
  z = sqlite3_mprintf("%s %s", zPrefix, (const char*)sqlite3_value_text(argv[0]));
  sqlite3_result_text(ctx, z, -1, sqlite3_free);
}

/* xq_ext_sum(X): the sum of X, as a 64-bit integer (an aggregate). */
static void sumStep(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  sqlite3_int64 *p = (sqlite3_int64*)sqlite3_aggregate_context(ctx, sizeof(*p));
  (void)argc;
  if( p ) *p += sqlite3_value_int64(argv[0]);
}
static void sumFinal(sqlite3_context *ctx){
  sqlite3_int64 *p = (sqlite3_int64*)sqlite3_aggregate_context(ctx, 0);
  sqlite3_result_int64(ctx, p ? *p : 0);
}

/* xq_ext_version(): sqlite3_libversion_number(). */
static void versionFunc(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  (void)argc; (void)argv;
  sqlite3_result_int(ctx, sqlite3_libversion_number());
}

int sqlite3_xqexttest_init(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi){
  int rc;
  SQLITE_EXTENSION_INIT2(pApi);
  (void)pzErrMsg;
  rc = sqlite3_create_function_v2(db, "xq_ext_hello", 1, SQLITE_UTF8|SQLITE_DETERMINISTIC,
                                  (void*)"hello", helloFunc, 0, 0, 0);
  if( rc==SQLITE_OK ){
    rc = sqlite3_create_function(db, "xq_ext_sum", 1, SQLITE_UTF8, 0, 0, sumStep, sumFinal);
  }
  if( rc==SQLITE_OK ){
    rc = sqlite3_create_function(db, "xq_ext_version", 0, SQLITE_UTF8, 0, versionFunc, 0, 0);
  }
  return rc;
}

/* An entry point that fails, with a message from sqlite3_mprintf(). */
int xq_ext_fail(sqlite3 *db, char **pzErrMsg, const sqlite3_api_routines *pApi){
  SQLITE_EXTENSION_INIT2(pApi);
  (void)db;
  *pzErrMsg = sqlite3_mprintf("boom %d", 42);
  return SQLITE_ERROR;
}

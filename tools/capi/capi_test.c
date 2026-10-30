/*
** A test of xqlite's sqlite3 C ABI: an ordinary C program, written
** against SQLite's sqlite3.h, linked with libxqlite3 (`zig build
** test-capi` links it once with the static and once with the shared
** library). It exits 0 when every check passes and prints the failures
** otherwise.
*/
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "sqlite3.h"
#include "xqlite.h"

static int nFail = 0;
static int nCheck = 0;

#define CHECK(X) do{ nCheck++; if( !(X) ){ nFail++; \
  fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #X); } }while(0)
#define CHECK_RC(RC, EXPECT, DB) do{ int rc_ = (RC); nCheck++; if( rc_!=(EXPECT) ){ nFail++; \
  fprintf(stderr, "%s:%d: %s returned %d (%s), expected %d\n", __FILE__, __LINE__, #RC, rc_, \
          (DB) ? sqlite3_errmsg(DB) : sqlite3_errstr(rc_), (EXPECT)); } }while(0)
#define CHECK_STR(A, B) do{ const char *a_ = (const char*)(A); const char *b_ = (B); nCheck++; \
  if( (a_==0) != (b_==0) || (a_ && strcmp(a_, b_)!=0) ){ nFail++; \
  fprintf(stderr, "%s:%d: %s is \"%s\", expected \"%s\"\n", __FILE__, __LINE__, #A, a_ ? a_ : "(null)", b_ ? b_ : "(null)"); } }while(0)

/* The first column of the first row of zSql, as text (static buffer). */
static const char *one(sqlite3 *db, const char *zSql){
  static char buf[1024];
  sqlite3_stmt *p = 0;
  buf[0] = 0;
  if( sqlite3_prepare_v2(db, zSql, -1, &p, 0)!=SQLITE_OK ){
    snprintf(buf, sizeof(buf), "ERROR: %s", sqlite3_errmsg(db));
    return buf;
  }
  if( sqlite3_step(p)==SQLITE_ROW ){
    const unsigned char *z = sqlite3_column_text(p, 0);
    snprintf(buf, sizeof(buf), "%s", z ? (const char*)z : "NULL");
  }else if( sqlite3_reset(p)!=SQLITE_OK ){
    snprintf(buf, sizeof(buf), "ERROR: %s", sqlite3_errmsg(db));
  }
  sqlite3_finalize(p);
  return buf;
}

static void exec(sqlite3 *db, const char *zSql){
  char *zErr = 0;
  int rc = sqlite3_exec(db, zSql, 0, 0, &zErr);
  nCheck++;
  if( rc!=SQLITE_OK ){
    nFail++;
    fprintf(stderr, "exec(%s): %d %s\n", zSql, rc, zErr ? zErr : "");
  }
  sqlite3_free(zErr);
}

/* ---------------------------------------------------------------- library */

static void test_library(void){
  CHECK_STR(sqlite3_libversion(), SQLITE_VERSION);
  CHECK(sqlite3_libversion_number()==SQLITE_VERSION_NUMBER);
  CHECK(strncmp(sqlite3_sourceid(), SQLITE_SOURCE_ID, 80)==0);
  CHECK_STR(sqlite3_version, SQLITE_VERSION);
  CHECK(sqlite3_threadsafe()==2);
  CHECK(sqlite3_compileoption_used("THREADSAFE=2"));
  CHECK(sqlite3_compileoption_used("SQLITE_THREADSAFE"));
  CHECK(!sqlite3_compileoption_used("ENABLE_COLUMN_METADATA"));
  CHECK(sqlite3_compileoption_get(0)!=0);
  CHECK(sqlite3_compileoption_get(1000)==0);
  CHECK_RC(sqlite3_initialize(), SQLITE_OK, 0);
  CHECK_STR(sqlite3_errstr(SQLITE_BUSY), "database is locked");
  CHECK_STR(sqlite3_errstr(SQLITE_CONSTRAINT_UNIQUE), "constraint failed");

  CHECK(sqlite3_complete("SELECT 1;"));
  CHECK(!sqlite3_complete("SELECT 1"));
  CHECK(!sqlite3_complete("CREATE TRIGGER t AFTER INSERT ON x BEGIN SELECT 1;"));
  CHECK(sqlite3_keyword_count()>100);
  {
    const char *z = 0; int n = 0, i, found = 0;
    for(i=0; i<sqlite3_keyword_count(); i++){
      CHECK_RC(sqlite3_keyword_name(i, &z, &n), SQLITE_OK, 0);
      if( n==6 && strncmp(z, "SELECT", 6)==0 ) found = 1;
    }
    CHECK(found);
    CHECK(sqlite3_keyword_name(-1, &z, &n)==SQLITE_ERROR);
  }
  CHECK(sqlite3_keyword_check("select", 6));
  CHECK(!sqlite3_keyword_check("selectx", 7));
  CHECK(sqlite3_stricmp("abc", "ABC")==0);
  CHECK(sqlite3_stricmp("abc", "abd")<0);
  CHECK(sqlite3_strnicmp("abcx", "ABCy", 3)==0);
  CHECK(sqlite3_strglob("a*c", "abbbc")==0);
  CHECK(sqlite3_strglob("a*c", "abbbd")!=0);
  CHECK(sqlite3_strlike("a%C", "abbbc", 0)==0);

  {
    void *p = sqlite3_malloc(100);
    CHECK(p!=0);
    CHECK(sqlite3_msize(p)>=100);
    memset(p, 'x', 100);
    p = sqlite3_realloc(p, 1000);
    CHECK(p!=0 && ((char*)p)[99]=='x');
    CHECK(sqlite3_msize(p)>=1000);
    sqlite3_free(p);
    CHECK(sqlite3_malloc(0)==0);
    p = sqlite3_malloc64(10);
    sqlite3_free(sqlite3_realloc64(p, 20));
    sqlite3_free(0);
  }
  {
    unsigned char a[16], b[16];
    sqlite3_randomness(sizeof(a), a);
    sqlite3_randomness(sizeof(b), b);
    CHECK(memcmp(a, b, sizeof(a))!=0);
  }
  CHECK(sqlite3_sleep(1)>=0);
  {
    sqlite3_mutex *m = sqlite3_mutex_alloc(SQLITE_MUTEX_RECURSIVE);
    CHECK(m!=0);
    sqlite3_mutex_enter(m);
    sqlite3_mutex_enter(m);
#ifndef NDEBUG
    CHECK(sqlite3_mutex_held(m));
#endif
    sqlite3_mutex_leave(m);
    sqlite3_mutex_leave(m);
#ifndef NDEBUG
    CHECK(sqlite3_mutex_notheld(m));
#endif
    sqlite3_mutex_free(m);
    m = sqlite3_mutex_alloc(SQLITE_MUTEX_STATIC_APP1);
    CHECK(m!=0 && m==sqlite3_mutex_alloc(SQLITE_MUTEX_STATIC_APP1));
    CHECK(sqlite3_mutex_try(m)==SQLITE_OK);
    sqlite3_mutex_leave(m);
  }
}

/* ----------------------------------------------------------------- printf */

static void test_printf(void){
  char buf[32];
  char *z;
  z = sqlite3_mprintf("%d %lld %s %5.2f|%-4s|%x %c", 42, (sqlite3_int64)1<<40, "hi", 3.14159, "ab", 255, 'Z');
  CHECK_STR(z, "42 1099511627776 hi  3.14|ab  |ff Z");
  sqlite3_free(z);
  z = sqlite3_mprintf("%q|%Q|%Q|%w", "it's", "a'b", (char*)0, "x\"y");
  CHECK_STR(z, "it''s|'a''b'|NULL|x\"\"y");
  sqlite3_free(z);
  z = sqlite3_mprintf("%.*s|%*d|%z", 3, "abcdef", 5, 7, sqlite3_mprintf("dyn%d", 1));
  CHECK_STR(z, "abc|    7|dyn1");
  sqlite3_free(z);
  z = sqlite3_mprintf("%!.15g %g %e %%", 0.1, 1e100, 12345.678);
  CHECK_STR(z, "0.1 1e+100 1.234568e+04 %");
  sqlite3_free(z);
  z = sqlite3_mprintf("%lu %u %i %ld", 4000000000UL, 4000000000U, -5, -6L);
  CHECK_STR(z, "4000000000 4000000000 -5 -6");
  sqlite3_free(z);
  sqlite3_snprintf(sizeof(buf), buf, "%s-%d", "abc", 12);
  CHECK_STR(buf, "abc-12");
  sqlite3_snprintf(5, buf, "%s", "abcdefgh");
  CHECK_STR(buf, "abcd");
  {
    sqlite3_str *s = sqlite3_str_new(0);
    sqlite3_str_appendf(s, "%d+%d", 1, 2);
    sqlite3_str_append(s, "xyz", 2);
    sqlite3_str_appendall(s, "!");
    sqlite3_str_appendchar(s, 3, '.');
    CHECK(sqlite3_str_length(s)==9);
    CHECK_STR(sqlite3_str_value(s), "1+2xy!...");
    sqlite3_str_truncate(s, 3);
    CHECK(sqlite3_str_errcode(s)==SQLITE_OK);
    z = sqlite3_str_finish(s);
    CHECK_STR(z, "1+2");
    sqlite3_free(z);
  }
}

/* -------------------------------------------------------------- statements */

static int exec_cb(void *p, int n, char **azVal, char **azCol){
  char *acc = (char*)p;
  int i;
  for(i=0; i<n; i++){
    strcat(acc, azCol[i]);
    strcat(acc, "=");
    strcat(acc, azVal[i] ? azVal[i] : "NULL");
    strcat(acc, ";");
  }
  return 0;
}

static int exec_abort(void *p, int n, char **azVal, char **azCol){
  (void)p; (void)n; (void)azVal; (void)azCol;
  return 1;
}

static void test_statements(void){
  sqlite3 *db = 0;
  sqlite3_stmt *p = 0;
  const char *zTail = 0;
  const char *zSql = "INSERT INTO t(a, b, c, d) VALUES(?1, :b, @c, $d); SELECT 1";
  int i;

  CHECK_RC(sqlite3_open_v2(":memory:", &db, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE, 0), SQLITE_OK, db);
  exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, a INT, b TEXT, c REAL, d BLOB)");
  CHECK_RC(sqlite3_prepare_v2(db, zSql, -1, &p, &zTail), SQLITE_OK, db);
  CHECK_STR(zTail, " SELECT 1");
  CHECK(sqlite3_bind_parameter_count(p)==4);
  CHECK_STR(sqlite3_bind_parameter_name(p, 2), ":b");
  CHECK_STR(sqlite3_bind_parameter_name(p, 4), "$d");
  CHECK(sqlite3_bind_parameter_index(p, "@c")==3);
  CHECK(sqlite3_bind_parameter_index(p, ":zz")==0);
  CHECK(!sqlite3_stmt_readonly(p));
  CHECK(!sqlite3_stmt_busy(p));
  CHECK_RC(sqlite3_bind_int(p, 1, 7), SQLITE_OK, db);
  CHECK_RC(sqlite3_bind_text(p, 2, "hello world", 5, SQLITE_TRANSIENT), SQLITE_OK, db);
  CHECK_RC(sqlite3_bind_double(p, 3, 2.5), SQLITE_OK, db);
  CHECK_RC(sqlite3_bind_blob(p, 4, "\x01\x02\x00\x03", 4, SQLITE_STATIC), SQLITE_OK, db);
  CHECK_RC(sqlite3_bind_int(p, 5, 1), SQLITE_RANGE, db);
  {
    char *z = sqlite3_expanded_sql(p);
    CHECK_STR(z, "INSERT INTO t(a, b, c, d) VALUES(7, 'hello', 2.5, x'01020003');");
    sqlite3_free(z);
  }
  CHECK_STR(sqlite3_sql(p), "INSERT INTO t(a, b, c, d) VALUES(?1, :b, @c, $d);");
  CHECK_RC(sqlite3_step(p), SQLITE_DONE, db);
  CHECK(sqlite3_changes(db)==1);
  CHECK(sqlite3_last_insert_rowid(db)==1);
  CHECK_RC(sqlite3_reset(p), SQLITE_OK, db);
  CHECK_RC(sqlite3_clear_bindings(p), SQLITE_OK, db);
  CHECK_RC(sqlite3_bind_int64(p, 1, (sqlite3_int64)1<<50), SQLITE_OK, db);
  CHECK_RC(sqlite3_bind_text(p, 2, strdup("owned"), -1, free), SQLITE_OK, db);
  CHECK_RC(sqlite3_bind_zeroblob(p, 4, 3), SQLITE_OK, db);
  CHECK_RC(sqlite3_step(p), SQLITE_DONE, db);
  CHECK_RC(sqlite3_finalize(p), SQLITE_OK, db);
  CHECK(sqlite3_total_changes(db)==2);
  CHECK(sqlite3_total_changes64(db)==2);

  CHECK_RC(sqlite3_prepare_v3(db, "SELECT id, a, b, c, d, NULL AS n FROM t ORDER BY id", -1, SQLITE_PREPARE_PERSISTENT, &p, 0), SQLITE_OK, db);
  CHECK(sqlite3_stmt_readonly(p));
  CHECK(sqlite3_column_count(p)==6);
  CHECK(sqlite3_data_count(p)==0);
  CHECK_STR(sqlite3_column_name(p, 5), "n");
  CHECK_STR(sqlite3_column_decltype(p, 2), "TEXT");
  CHECK(sqlite3_column_decltype(p, 5)==0);
  CHECK_RC(sqlite3_step(p), SQLITE_ROW, db);
  CHECK(sqlite3_stmt_busy(p));
  CHECK(sqlite3_data_count(p)==6);
  CHECK(sqlite3_column_type(p, 1)==SQLITE_INTEGER);
  CHECK(sqlite3_column_int(p, 1)==7);
  CHECK_STR(sqlite3_column_text(p, 2), "hello");
  CHECK(sqlite3_column_bytes(p, 2)==5);
  CHECK(sqlite3_column_bytes16(p, 2)==10);
  CHECK(sqlite3_column_type(p, 3)==SQLITE_FLOAT && sqlite3_column_double(p, 3)==2.5);
  CHECK(sqlite3_column_type(p, 4)==SQLITE_BLOB && sqlite3_column_bytes(p, 4)==4);
  CHECK(memcmp(sqlite3_column_blob(p, 4), "\x01\x02\x00\x03", 4)==0);
  CHECK(sqlite3_column_type(p, 5)==SQLITE_NULL && sqlite3_column_text(p, 5)==0);
  {
    sqlite3_value *v = sqlite3_value_dup(sqlite3_column_value(p, 2));
    CHECK_STR(sqlite3_value_text(v), "hello");
    sqlite3_value_free(v);
  }
  CHECK_RC(sqlite3_step(p), SQLITE_ROW, db);
  CHECK(sqlite3_column_int64(p, 1)==(sqlite3_int64)1<<50);
  CHECK_STR(sqlite3_column_text(p, 2), "owned");
  CHECK(sqlite3_column_bytes(p, 4)==3);
  CHECK_RC(sqlite3_step(p), SQLITE_DONE, db);
  CHECK(sqlite3_next_stmt(db, 0)==p);
  CHECK(sqlite3_db_handle(p)==db);
  CHECK(sqlite3_stmt_status(p, SQLITE_STMTSTATUS_VM_STEP, 0)>0);
  CHECK(sqlite3_stmt_status(p, SQLITE_STMTSTATUS_RUN, 0)>=1);
  CHECK_RC(sqlite3_finalize(p), SQLITE_OK, db);
  CHECK(sqlite3_next_stmt(db, 0)==0);

  /* Errors. */
  CHECK_RC(sqlite3_prepare_v2(db, "SELEC 1", -1, &p, 0), SQLITE_ERROR, db);
  CHECK(p==0);
  CHECK_STR(sqlite3_errmsg(db), "near \"SELEC\": syntax error");
  CHECK(sqlite3_error_offset(db)==0);
  CHECK(sqlite3_errcode(db)==SQLITE_ERROR);
  exec(db, "CREATE UNIQUE INDEX tb ON t(b)");
  {
    char *zErr = 0;
    CHECK_RC(sqlite3_exec(db, "INSERT INTO t(b) VALUES('hello')", 0, 0, &zErr), SQLITE_CONSTRAINT, db);
    CHECK_STR(zErr, "UNIQUE constraint failed: t.b");
    sqlite3_free(zErr);
    CHECK(sqlite3_extended_errcode(db)==SQLITE_CONSTRAINT_UNIQUE);
    CHECK(sqlite3_errcode(db)==SQLITE_CONSTRAINT);
    sqlite3_extended_result_codes(db, 1);
    CHECK_RC(sqlite3_exec(db, "INSERT INTO t(b) VALUES('hello')", 0, 0, 0), SQLITE_CONSTRAINT_UNIQUE, db);
    sqlite3_extended_result_codes(db, 0);
  }

  /* An nByte without NUL, and the tail inside it. */
  CHECK_RC(sqlite3_prepare_v2(db, "SELECT 42; garbage", 10, &p, &zTail), SQLITE_OK, db);
  CHECK(zTail==(const char*)0 || strncmp(zTail, " garbage", 8)==0);
  CHECK_RC(sqlite3_step(p), SQLITE_ROW, db);
  CHECK(sqlite3_column_int(p, 0)==42);
  sqlite3_finalize(p);
  CHECK_RC(sqlite3_prepare_v2(db, "  -- nothing\n", -1, &p, 0), SQLITE_OK, db);
  CHECK(p==0);

  /* get_table */
  {
    char **az = 0; int nRow = 0, nCol = 0;
    CHECK_RC(sqlite3_get_table(db, "SELECT id, b FROM t ORDER BY id", &az, &nRow, &nCol, 0), SQLITE_OK, db);
    CHECK(nRow==2 && nCol==2);
    if( az ){
      CHECK_STR(az[0], "id");
      CHECK_STR(az[3], "hello");
      CHECK_STR(az[5], "owned");
    }
    sqlite3_free_table(az);
  }

  /* exec callback */
  {
    char acc[64] = "";
    CHECK_RC(sqlite3_exec(db, "SELECT 1 AS a; SELECT 2 AS b UNION ALL SELECT NULL", exec_cb, acc, 0), SQLITE_OK, db);
    CHECK_STR(acc, "a=1;b=2;b=NULL;");
    CHECK_RC(sqlite3_exec(db, "SELECT 1; SELECT 2", exec_abort, 0, 0), SQLITE_ABORT, db);
  }

  /* Transactions and autocommit. */
  CHECK(sqlite3_get_autocommit(db));
  exec(db, "BEGIN");
  CHECK(!sqlite3_get_autocommit(db));
  CHECK(sqlite3_txn_state(db, 0)==SQLITE_TXN_NONE);
  exec(db, "INSERT INTO t(a) VALUES(1)");
  CHECK(sqlite3_txn_state(db, "main")==SQLITE_TXN_WRITE);
  exec(db, "ROLLBACK");
  CHECK(sqlite3_get_autocommit(db));
  CHECK(sqlite3_txn_state(db, "nosuch")==-1);

  /* Limits and db_config. */
  CHECK(sqlite3_limit(db, SQLITE_LIMIT_LENGTH, -1)>0);
  CHECK(sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, 3)>3);
  CHECK_RC(sqlite3_prepare_v2(db, "SELECT ?1, ?2, ?3, ?4", -1, &p, 0), SQLITE_ERROR, db);
  {
    int on = -1;
    CHECK_RC(sqlite3_db_config(db, SQLITE_DBCONFIG_ENABLE_FKEY, 1, &on), SQLITE_OK, db);
    CHECK(on==1);
    CHECK_STR(one(db, "PRAGMA foreign_keys"), "1");
    CHECK_RC(sqlite3_db_config(db, SQLITE_DBCONFIG_DEFENSIVE, -1, &on), SQLITE_OK, db);
    CHECK(on==0);
  }
  {
    const char *zType = 0, *zColl = 0; int notNull = -1, pk = -1, autoinc = -1;
    exec(db, "CREATE TABLE m(x INTEGER PRIMARY KEY AUTOINCREMENT, y TEXT NOT NULL COLLATE nocase)");
    CHECK_RC(sqlite3_table_column_metadata(db, 0, "m", "y", &zType, &zColl, &notNull, &pk, &autoinc), SQLITE_OK, db);
    CHECK_STR(zType, "TEXT");
    CHECK_STR(zColl, "nocase");
    CHECK(notNull==1 && pk==0 && autoinc==0);
    CHECK_RC(sqlite3_table_column_metadata(db, "main", "m", "x", &zType, &zColl, &notNull, &pk, &autoinc), SQLITE_OK, db);
    CHECK(pk==1 && autoinc==1);
    CHECK_STR(zColl, "BINARY");
    CHECK_RC(sqlite3_table_column_metadata(db, 0, "m", "nope", 0, 0, 0, 0, 0), SQLITE_ERROR, db);
    CHECK_RC(sqlite3_table_column_metadata(db, 0, "m", 0, 0, 0, 0, 0, 0), SQLITE_OK, db);
  }

  /* close_v2 leaves a zombie until the last statement goes. */
  CHECK_RC(sqlite3_prepare_v2(db, "SELECT 1", -1, &p, 0), SQLITE_OK, db);
  CHECK_RC(sqlite3_close(db), SQLITE_BUSY, db);
  CHECK_RC(sqlite3_close_v2(db), SQLITE_OK, 0);
  CHECK_RC(sqlite3_step(p), SQLITE_ROW, 0);
  CHECK_RC(sqlite3_finalize(p), SQLITE_OK, 0);
  (void)i;
}

/* --------------------------------------------------------------- functions */

static int nDestroy = 0;
static void destroy(void *p){ (void)p; nDestroy++; }

static void fn_twice(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  int *pMul = (int*)sqlite3_user_data(ctx);
  CHECK(argc==1);
  CHECK(sqlite3_context_db_handle(ctx)!=0);
  switch( sqlite3_value_type(argv[0]) ){
    case SQLITE_INTEGER: sqlite3_result_int64(ctx, sqlite3_value_int64(argv[0]) * *pMul); break;
    case SQLITE_FLOAT: sqlite3_result_double(ctx, sqlite3_value_double(argv[0]) * *pMul); break;
    case SQLITE_TEXT: {
      int n = sqlite3_value_bytes(argv[0]);
      char *z = sqlite3_malloc(2*n + 1);
      memcpy(z, sqlite3_value_text(argv[0]), n);
      memcpy(z+n, sqlite3_value_text(argv[0]), n);
      z[2*n] = 0;
      sqlite3_result_text(ctx, z, 2*n, sqlite3_free);
      break;
    }
    case SQLITE_BLOB: sqlite3_result_zeroblob(ctx, 2*sqlite3_value_bytes(argv[0])); break;
    default: sqlite3_result_null(ctx); break;
  }
}

static void fn_fail(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  (void)argc; (void)argv;
  sqlite3_result_error(ctx, "custom failure", -1);
}

static void fn_code(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  (void)argc; (void)argv;
  sqlite3_result_error_code(ctx, SQLITE_CONSTRAINT);
}

static void aux_free(void *p){ sqlite3_free(p); nDestroy++; }

/* regexp-like: caches its compiled pattern (here, a copy) as auxdata. */
static void fn_aux(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  char *z = (char*)sqlite3_get_auxdata(ctx, 0);
  (void)argc;
  if( z==0 ){
    z = sqlite3_mprintf("%s", sqlite3_value_text(argv[0]));
    sqlite3_set_auxdata(ctx, 0, z, aux_free);
    z = (char*)sqlite3_get_auxdata(ctx, 0);
    sqlite3_result_int(ctx, z ? 0 : -1);
  }else{
    sqlite3_result_int(ctx, 1);
  }
}

typedef struct SumCtx { sqlite3_int64 sum; int n; } SumCtx;
static void sum_step(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  SumCtx *p = (SumCtx*)sqlite3_aggregate_context(ctx, sizeof(*p));
  (void)argc;
  if( p ){ p->sum += sqlite3_value_int64(argv[0]); p->n++; }
}
static void sum_inverse(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  SumCtx *p = (SumCtx*)sqlite3_aggregate_context(ctx, sizeof(*p));
  (void)argc;
  p->sum -= sqlite3_value_int64(argv[0]); p->n--;
}
static void sum_value(sqlite3_context *ctx){
  SumCtx *p = (SumCtx*)sqlite3_aggregate_context(ctx, 0);
  sqlite3_result_int64(ctx, p ? p->sum : 0);
}
static void sum_final(sqlite3_context *ctx){
  SumCtx *p = (SumCtx*)sqlite3_aggregate_context(ctx, 0);
  if( p ){
    sqlite3_str *s = sqlite3_str_new(sqlite3_context_db_handle(ctx));
    sqlite3_str_appendf(s, "%lld/%d", p->sum, p->n);
    sqlite3_result_str(ctx, s, SQLITE_FINISH);
  }else{
    sqlite3_result_null(ctx);
  }
}

static int coll_rev(void *pArg, int n1, const void *z1, int n2, const void *z2){
  int r = memcmp(z1, z2, n1<n2 ? n1 : n2);
  (void)pArg;
  if( r==0 ) r = n1 - n2;
  return -r;
}

static void ptr_free(void *p){ free(p); nDestroy++; }
static void fn_ptr_make(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  int *p = malloc(sizeof(int));
  (void)argc; (void)argv;
  *p = 1234;
  sqlite3_result_pointer(ctx, p, "xq-test", ptr_free);
}
static void fn_ptr_read(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  int *p = (int*)sqlite3_value_pointer(argv[0], "xq-test");
  (void)argc;
  CHECK(sqlite3_value_pointer(argv[0], "other")==0);
  sqlite3_result_int(ctx, p ? *p : -1);
}

static void test_functions(void){
  sqlite3 *db = 0;
  static int mul = 2;
  CHECK_RC(sqlite3_open(":memory:", &db), SQLITE_OK, db);
  CHECK_RC(sqlite3_create_function_v2(db, "twice", 1, SQLITE_UTF8|SQLITE_DETERMINISTIC, &mul, fn_twice, 0, 0, destroy), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT twice(21)"), "42");
  CHECK_STR(one(db, "SELECT twice(1.5)"), "3.0");
  CHECK_STR(one(db, "SELECT twice('ab')"), "abab");
  CHECK_STR(one(db, "SELECT length(twice(x'0102'))"), "4");
  CHECK_STR(one(db, "SELECT twice(NULL) IS NULL"), "1");
  CHECK_STR(one(db, "SELECT twice(1, 2)"), "ERROR: wrong number of arguments to function twice()");
  /* Replacing the function runs the destructor of the old one. */
  CHECK_RC(sqlite3_create_function_v2(db, "twice", 1, SQLITE_UTF8, &mul, fn_twice, 0, 0, destroy), SQLITE_OK, db);
  CHECK(nDestroy==1);
  CHECK_RC(sqlite3_create_function(db, "fail", 0, SQLITE_UTF8, 0, fn_fail, 0, 0), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT fail()"), "ERROR: custom failure");
  {
    sqlite3_stmt *p = 0;
    CHECK_RC(sqlite3_create_function(db, "code", 0, SQLITE_UTF8, 0, fn_code, 0, 0), SQLITE_OK, db);
    CHECK_RC(sqlite3_prepare_v2(db, "SELECT code()", -1, &p, 0), SQLITE_OK, db);
    CHECK_RC(sqlite3_step(p), SQLITE_CONSTRAINT, db);
    sqlite3_finalize(p);
  }
  CHECK_RC(sqlite3_create_function(db, "auxf", 1, SQLITE_UTF8, 0, fn_aux, 0, 0), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT group_concat(auxf('pat'), ',') FROM (SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3)"), "0,1,1");
  CHECK_RC(sqlite3_create_window_function(db, "wsum", 1, SQLITE_UTF8, 0, sum_step, sum_final, sum_value, sum_inverse, destroy), SQLITE_OK, db);
  exec(db, "CREATE TABLE n(x); INSERT INTO n VALUES(1),(2),(3),(4)");
  CHECK_STR(one(db, "SELECT wsum(x) FROM n"), "10/4");
  CHECK_STR(one(db, "SELECT group_concat(s, ',') FROM (SELECT wsum(x) OVER (ORDER BY x ROWS 1 PRECEDING) AS s FROM n)"), "1,3,5,7");
  CHECK_STR(one(db, "SELECT wsum(x) FROM n WHERE x > 10"), "NULL");
  /* Deleting a function. */
  CHECK_RC(sqlite3_create_function(db, "fail", 0, SQLITE_UTF8, 0, 0, 0, 0), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT fail()"), "ERROR: no such function: fail");
  CHECK_RC(sqlite3_create_function(db, "bad", 0, SQLITE_UTF8, 0, fn_fail, sum_step, 0), SQLITE_MISUSE, db);

  CHECK_RC(sqlite3_create_function(db, "ptr_make", 0, SQLITE_UTF8, 0, fn_ptr_make, 0, 0), SQLITE_OK, db);
  CHECK_RC(sqlite3_create_function(db, "ptr_read", 1, SQLITE_UTF8, 0, fn_ptr_read, 0, 0), SQLITE_OK, db);
  nDestroy = 0;
  CHECK_STR(one(db, "SELECT ptr_read(ptr_make())"), "1234");
  CHECK(nDestroy==1);
  {
    sqlite3_stmt *p = 0;
    int *q = malloc(sizeof(int));
    *q = 99;
    CHECK_RC(sqlite3_prepare_v2(db, "SELECT ptr_read(?)", -1, &p, 0), SQLITE_OK, db);
    CHECK_RC(sqlite3_bind_pointer(p, 1, q, "xq-test", ptr_free), SQLITE_OK, db);
    CHECK_RC(sqlite3_step(p), SQLITE_ROW, db);
    CHECK(sqlite3_column_int(p, 0)==99);
    sqlite3_finalize(p);
    CHECK(nDestroy==2);
  }

  CHECK_RC(sqlite3_create_collation_v2(db, "rev", SQLITE_UTF8, 0, coll_rev, destroy), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT group_concat(x, '') FROM (SELECT x FROM (SELECT 'a' x UNION SELECT 'c' UNION SELECT 'b') ORDER BY x COLLATE rev)"), "cba");
  nDestroy = 0;
  CHECK_RC(sqlite3_create_collation(db, "rev", SQLITE_UTF8, 0, coll_rev), SQLITE_OK, db);
  CHECK(nDestroy==1);
  CHECK_RC(sqlite3_create_collation(db, "rev", SQLITE_UTF8, 0, 0), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT 'a' < 'b' COLLATE rev"), "ERROR: no such collation sequence: rev");

  nDestroy = 0;
  CHECK_RC(sqlite3_close(db), SQLITE_OK, 0);
  CHECK(nDestroy==2); /* twice and wsum */
}

/* ------------------------------------------------------------------- utf16 */

static void test_utf16(void){
  sqlite3 *db = 0;
  sqlite3_stmt *p = 0;
  const void *zTail = 0;
  static const unsigned short zName[] = { ':', 'm', 'e', 'm', 'o', 'r', 'y', ':', 0 };
  static const unsigned short zSql[] = { 'S','E','L','E','C','T',' ','?',',',' ','0','x','e','9',';',' ','X', 0 };
  static const unsigned short zText[] = { 0x00e9, 0xd83d, 0xde00, 0 };
  CHECK_RC(sqlite3_open16(zName, &db), SQLITE_OK, db);
  CHECK_RC(sqlite3_prepare16_v2(db, zSql, -1, &p, &zTail), SQLITE_OK, db);
  CHECK(zTail==(const void*)&zSql[15]);
  CHECK_RC(sqlite3_bind_text16(p, 1, zText, -1, SQLITE_STATIC), SQLITE_OK, db);
  CHECK_RC(sqlite3_step(p), SQLITE_ROW, db);
  CHECK_STR(sqlite3_column_text(p, 0), "\xc3\xa9\xf0\x9f\x98\x80");
  CHECK(sqlite3_column_bytes16(p, 0)==6);
  CHECK(sqlite3_column_int(p, 1)==233);
  sqlite3_finalize(p);
  CHECK(sqlite3_complete16(zSql)==0);
  CHECK(sqlite3_complete16(zName)==0);
  CHECK_RC(sqlite3_prepare_v2(db, "SELEC", -1, &p, 0), SQLITE_ERROR, db);
  {
    const unsigned short *z = (const unsigned short*)sqlite3_errmsg16(db);
    CHECK(z && z[0]=='n' && z[1]=='e');
  }
  sqlite3_close(db);
}

/* ----------------------------------------------------------------- dialects */

static void test_dialects(void){
  sqlite3 *db = 0;
  const int flags = SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_URI;
  CHECK_RC(sqlite3_open_v2("file::memory:?dialect=postgres", &db, flags, 0), SQLITE_OK, db);
  CHECK_STR(xqlite_dialect(db), "postgres");
  CHECK_STR(one(db, "SELECT 'a' || 1::text"), "a1");
  exec(db, "CREATE TABLE users (id bigserial PRIMARY KEY, email text NOT NULL)");
  CHECK_STR(one(db, "INSERT INTO users (email) VALUES ('x@y') RETURNING id"), "1");
  CHECK_RC(xqlite_set_dialect(db, "mysql"), SQLITE_OK, db);
  CHECK_STR(xqlite_dialect(db), "mariadb");
  CHECK_STR(one(db, "SELECT CONCAT('a', 'b', 1)"), "ab1");
  CHECK_RC(xqlite_set_dialect(db, "klingon"), SQLITE_ERROR, db);
  CHECK_STR(sqlite3_errmsg(db), "no such dialect: klingon");
  exec(db, "PRAGMA xq_dialect = 'sqlite'");
  CHECK_STR(xqlite_dialect(db), "sqlite");
  sqlite3_close(db);

  db = 0;
  CHECK_RC(sqlite3_open_v2("file::memory:?dialect=klingon", &db, flags, 0), SQLITE_ERROR, db);
  CHECK(db!=0);
  CHECK_STR(sqlite3_errmsg(db), "no such dialect: klingon");
  sqlite3_close(db);

  /* Without SQLITE_OPEN_URI, the name is a plain file name. */
  db = 0;
  CHECK_RC(sqlite3_open_v2("file::memory:?dialect=oracle", &db, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_MEMORY, 0), SQLITE_OK, db);
  CHECK_STR(xqlite_dialect(db), "sqlite");
  sqlite3_close(db);

  CHECK_RC(sqlite3_open_v2("file::memory:?dialect=oracle&mode=memory", &db, flags, 0), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT 1 FROM dual"), "1");
  sqlite3_close(db);
}

/* ----------------------------------------------------- files, WAL, backup */

static int nWal = 0;
static int wal_hook(void *p, sqlite3 *db, const char *zDb, int nFrame){
  (void)p; (void)db; (void)zDb;
  if( nFrame>0 ) nWal++;
  return SQLITE_OK;
}

static int nBusy = 0;
static int busy_handler(void *p, int n){ (void)p; nBusy++; return n<2; }

static void test_files(const char *zDir){
  sqlite3 *db = 0, *db2 = 0, *mem = 0;
  char zPath[512], zUri[600];
  sqlite3_backup *b;
  int nLog = -2, nCkpt = -2;
  const char *zFile;

  snprintf(zPath, sizeof(zPath), "%s/test.db", zDir);
  snprintf(zUri, sizeof(zUri), "file:%s?cache=private&xq_answer=42&flag=yes", zPath);
  CHECK_RC(sqlite3_open_v2(zUri, &db, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_URI, 0), SQLITE_OK, db);
  zFile = sqlite3_db_filename(db, "main");
  CHECK(zFile && strstr(zFile, "/test.db")!=0 && zFile[0]=='/');
  CHECK_STR(sqlite3_uri_parameter(zFile, "xq_answer"), "42");
  CHECK(sqlite3_uri_int64(zFile, "xq_answer", 0)==42);
  CHECK(sqlite3_uri_boolean(zFile, "flag", 0)==1);
  CHECK(sqlite3_uri_boolean(zFile, "nope", 1)==1);
  CHECK_STR(sqlite3_uri_key(zFile, 0), "cache");
  CHECK(strstr(sqlite3_filename_journal(zFile), "/test.db-journal")!=0);
  CHECK(strstr(sqlite3_filename_wal(zFile), "/test.db-wal")!=0);
  CHECK(sqlite3_filename_database(zFile)==zFile);
  CHECK(sqlite3_db_readonly(db, "main")==0);
  CHECK(sqlite3_db_readonly(db, "nosuch")==-1);
  CHECK_STR(sqlite3_db_name(db, 0), "main");
  CHECK_STR(sqlite3_db_name(db, 1), "temp");
  CHECK_STR(one(db, "PRAGMA journal_mode=WAL"), "wal");
  sqlite3_wal_hook(db, wal_hook, 0);
  exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES(1),(2),(3)");
  CHECK(nWal>=1);
  CHECK_RC(sqlite3_wal_checkpoint_v2(db, 0, SQLITE_CHECKPOINT_TRUNCATE, &nLog, &nCkpt), SQLITE_OK, db);
  CHECK(nLog==0 && nCkpt==0);
  CHECK_RC(sqlite3_wal_autocheckpoint(db, 100), SQLITE_OK, db);
  CHECK_RC(sqlite3_wal_checkpoint(db, "main"), SQLITE_OK, db);
  CHECK_RC(sqlite3_wal_checkpoint(db, "nosuch"), SQLITE_ERROR, db);

  /* A second connection sees the data, and waits on a lock. */
  CHECK_RC(sqlite3_open_v2(zPath, &db2, SQLITE_OPEN_READWRITE, 0), SQLITE_OK, db2);
  CHECK_STR(one(db2, "SELECT sum(x) FROM t"), "6");
  exec(db, "BEGIN IMMEDIATE");
  sqlite3_busy_handler(db2, busy_handler, 0);
  CHECK_RC(sqlite3_exec(db2, "INSERT INTO t VALUES(4)", 0, 0, 0), SQLITE_BUSY, db2);
  CHECK(nBusy==3);
  CHECK_RC(sqlite3_busy_timeout(db2, 20), SQLITE_OK, db2);
  CHECK_RC(sqlite3_exec(db2, "INSERT INTO t VALUES(4)", 0, 0, 0), SQLITE_BUSY, db2);
  exec(db, "COMMIT");
  exec(db2, "INSERT INTO t VALUES(4)");
  CHECK_RC(sqlite3_close(db2), SQLITE_OK, 0);

  /* Read-only open. */
  CHECK_RC(sqlite3_open_v2(zPath, &db2, SQLITE_OPEN_READONLY, 0), SQLITE_OK, db2);
  CHECK(sqlite3_db_readonly(db2, 0)==1);
  CHECK_RC(sqlite3_exec(db2, "INSERT INTO t VALUES(5)", 0, 0, 0), SQLITE_READONLY, db2);
  sqlite3_close(db2);
  db2 = 0;
  CHECK(sqlite3_open_v2("/nonexistent/dir/x.db", &db2, SQLITE_OPEN_READWRITE, 0)==SQLITE_CANTOPEN);
  CHECK(db2!=0);
  sqlite3_close(db2);
  CHECK(sqlite3_open_v2("x.db", &db2, SQLITE_OPEN_CREATE, 0)==SQLITE_MISUSE);

  /* Backup into memory. */
  CHECK_RC(sqlite3_open(":memory:", &mem), SQLITE_OK, mem);
  b = sqlite3_backup_init(mem, "main", db, "main");
  CHECK(b!=0);
  if( b ){
    int rc;
    do{ rc = sqlite3_backup_step(b, 1); }while( rc==SQLITE_OK );
    CHECK(rc==SQLITE_DONE);
    CHECK(sqlite3_backup_remaining(b)==0);
    CHECK(sqlite3_backup_pagecount(b)>=2);
    CHECK_RC(sqlite3_backup_finish(b), SQLITE_OK, mem);
  }
  CHECK_STR(one(mem, "SELECT sum(x) FROM t"), "10");
  CHECK(sqlite3_backup_init(mem, "main", mem, "main")==0);
  sqlite3_close(mem);

  /* Incremental blob I/O. */
  exec(db, "CREATE TABLE b(id INTEGER PRIMARY KEY, data BLOB, n INT); INSERT INTO b VALUES(1, zeroblob(10), 5)");
  {
    sqlite3_blob *pBlob = 0;
    char buf[10];
    CHECK_RC(sqlite3_blob_open(db, "main", "b", "data", 1, 1, &pBlob), SQLITE_OK, db);
    CHECK(sqlite3_blob_bytes(pBlob)==10);
    CHECK_RC(sqlite3_blob_write(pBlob, "abc", 3, 2), SQLITE_OK, db);
    CHECK_RC(sqlite3_blob_read(pBlob, buf, 5, 1), SQLITE_OK, db);
    CHECK(memcmp(buf, "\0abc\0", 5)==0);
    CHECK_RC(sqlite3_blob_write(pBlob, "abc", 3, 9), SQLITE_ERROR, db);
    CHECK_RC(sqlite3_blob_reopen(pBlob, 2), SQLITE_ERROR, db);
    CHECK_RC(sqlite3_blob_close(pBlob), SQLITE_OK, db);
    CHECK_STR(one(db, "SELECT hex(data) FROM b"), "00006162630000000000");
    CHECK_RC(sqlite3_blob_open(db, "main", "b", "n", 1, 0, &pBlob), SQLITE_ERROR, db);
    CHECK_STR(sqlite3_errmsg(db), "cannot open value of type integer");
    CHECK(pBlob==0);
  }
  CHECK_RC(sqlite3_close(db), SQLITE_OK, 0);
}

/* -------------------------------------------------------------------- trace */

static int nStmt = 0, nRow = 0, nProfile = 0, nClose = 0;
static int trace_cb(unsigned t, void *ctx, void *p, void *x){
  (void)ctx;
  if( t==SQLITE_TRACE_STMT ){ nStmt++; CHECK(strcmp((const char*)x, sqlite3_sql((sqlite3_stmt*)p))==0); }
  if( t==SQLITE_TRACE_ROW ) nRow++;
  if( t==SQLITE_TRACE_PROFILE ){ nProfile++; CHECK(*(sqlite3_int64*)x>=0); }
  if( t==SQLITE_TRACE_CLOSE ) nClose++;
  return 0;
}

static void test_trace(void){
  sqlite3 *db = 0;
  CHECK_RC(sqlite3_open(":memory:", &db), SQLITE_OK, db);
  CHECK_RC(sqlite3_trace_v2(db, SQLITE_TRACE_STMT|SQLITE_TRACE_ROW|SQLITE_TRACE_PROFILE|SQLITE_TRACE_CLOSE, trace_cb, 0), SQLITE_OK, db);
  exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES(1),(2); SELECT * FROM t");
  CHECK(nStmt==3);
  nRow = 0;
  exec(db, "SELECT * FROM t");
  CHECK(nRow==2);
  CHECK(nProfile==4);
  sqlite3_close(db);
  CHECK(nClose==1);
}

/* ------------------------------------------------------------ virtual table */

/* A table-valued function: seq(n) yields value 1..n. */
typedef struct SeqCursor { sqlite3_vtab_cursor base; sqlite3_int64 i, n; } SeqCursor;
static int nSeqDestroy = 0;

static int seqConnect(sqlite3 *db, void *pAux, int argc, const char *const*argv, sqlite3_vtab **ppVtab, char **pzErr){
  int rc;
  (void)pAux; (void)argc; (void)argv; (void)pzErr;
  rc = sqlite3_declare_vtab(db, "CREATE TABLE x(value INTEGER, n HIDDEN)");
  if( rc!=SQLITE_OK ) return rc;
  *ppVtab = sqlite3_malloc(sizeof(sqlite3_vtab));
  memset(*ppVtab, 0, sizeof(sqlite3_vtab));
  sqlite3_vtab_config(db, SQLITE_VTAB_INNOCUOUS);
  return SQLITE_OK;
}
static int seqDisconnect(sqlite3_vtab *p){ sqlite3_free(p); return SQLITE_OK; }
static int seqOpen(sqlite3_vtab *p, sqlite3_vtab_cursor **pp){
  SeqCursor *c = sqlite3_malloc(sizeof(*c));
  (void)p;
  memset(c, 0, sizeof(*c));
  *pp = &c->base;
  return SQLITE_OK;
}
static int seqClose(sqlite3_vtab_cursor *p){ sqlite3_free(p); return SQLITE_OK; }
static int seqFilter(sqlite3_vtab_cursor *p, int idxNum, const char *idxStr, int argc, sqlite3_value **argv){
  SeqCursor *c = (SeqCursor*)p;
  CHECK(idxStr==0 || strcmp(idxStr, "seq-plan")==0);
  c->i = 1;
  c->n = (idxNum==1 && argc==1) ? sqlite3_value_int64(argv[0]) : 0;
  if( c->n<0 ){
    p->pVtab->zErrMsg = sqlite3_mprintf("negative count %lld", c->n);
    return SQLITE_ERROR;
  }
  return SQLITE_OK;
}
static int seqNext(sqlite3_vtab_cursor *p){ ((SeqCursor*)p)->i++; return SQLITE_OK; }
static int seqEof(sqlite3_vtab_cursor *p){ SeqCursor *c = (SeqCursor*)p; return c->i > c->n; }
static int seqColumn(sqlite3_vtab_cursor *p, sqlite3_context *ctx, int i){
  SeqCursor *c = (SeqCursor*)p;
  sqlite3_result_int64(ctx, i==0 ? c->i : c->n);
  return SQLITE_OK;
}
static int seqRowid(sqlite3_vtab_cursor *p, sqlite3_int64 *pRowid){ *pRowid = ((SeqCursor*)p)->i; return SQLITE_OK; }
static int seqBestIndex(sqlite3_vtab *tab, sqlite3_index_info *info){
  int i;
  (void)tab;
  info->idxNum = 0;
  for(i=0; i<info->nConstraint; i++){
    if( info->aConstraint[i].iColumn==1 && info->aConstraint[i].op==SQLITE_INDEX_CONSTRAINT_EQ ){
      if( !info->aConstraint[i].usable ) return SQLITE_CONSTRAINT;
      info->aConstraintUsage[i].argvIndex = 1;
      info->aConstraintUsage[i].omit = 1;
      info->idxNum = 1;
      info->idxStr = sqlite3_mprintf("seq-plan");
      info->needToFreeIdxStr = 1;
      CHECK(sqlite3_vtab_collation(info, i)!=0);
    }
  }
  info->estimatedCost = info->idxNum ? 10 : 1e9;
  if( info->nOrderBy==1 && info->aOrderBy[0].iColumn==0 && !info->aOrderBy[0].desc ){
    info->orderByConsumed = 1;
  }
  return SQLITE_OK;
}
static void seqModuleDestroy(void *p){ (void)p; nSeqDestroy++; }

static sqlite3_module seqModule = {
  0, 0, seqConnect, seqBestIndex, seqDisconnect, 0, seqOpen, seqClose,
  seqFilter, seqNext, seqEof, seqColumn, seqRowid,
  0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
};

static void test_vtab(void){
  sqlite3 *db = 0;
  CHECK_RC(sqlite3_open(":memory:", &db), SQLITE_OK, db);
  CHECK_RC(sqlite3_create_module_v2(db, "seq", &seqModule, 0, seqModuleDestroy), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT group_concat(value, ',') FROM seq(5)"), "1,2,3,4,5");
  CHECK_STR(one(db, "SELECT sum(value) FROM seq WHERE n = 100"), "5050");
  CHECK_STR(one(db, "SELECT count(*) FROM seq(3) a, seq(4) b"), "12");
  CHECK_STR(one(db, "SELECT value FROM seq(-1)"), "ERROR: negative count -1");
  CHECK_STR(one(db, "SELECT group_concat(value) FROM (SELECT value FROM seq(4) ORDER BY value)"), "1,2,3,4");
  CHECK_RC(sqlite3_drop_modules(db, 0), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT * FROM seq(3)"), "ERROR: no such table: seq");
  sqlite3_close(db);
  CHECK(nSeqDestroy==1);
}

/* ---------------------------------------------------------------------- vfs */

/* A VFS that counts opens and delegates to the default one. */
static sqlite3_vfs *pOrig = 0;
static int nOpen = 0;
static int shimOpen(sqlite3_vfs *p, sqlite3_filename z, sqlite3_file *f, int flags, int *pOut){
  (void)p;
  nOpen++;
  return pOrig->xOpen(pOrig, z, f, flags, pOut);
}
static int shimDelete(sqlite3_vfs *p, const char *z, int s){ (void)p; return pOrig->xDelete(pOrig, z, s); }
static int shimAccess(sqlite3_vfs *p, const char *z, int f, int *r){ (void)p; return pOrig->xAccess(pOrig, z, f, r); }
static int shimFull(sqlite3_vfs *p, const char *z, int n, char *o){ (void)p; return pOrig->xFullPathname(pOrig, z, n, o); }
static int shimRandom(sqlite3_vfs *p, int n, char *o){ (void)p; return pOrig->xRandomness(pOrig, n, o); }
static int shimSleep(sqlite3_vfs *p, int n){ (void)p; return pOrig->xSleep(pOrig, n); }
static int shimTime(sqlite3_vfs *p, double *t){ (void)p; return pOrig->xCurrentTime(pOrig, t); }
static sqlite3_vfs shimVfs;

static void test_vfs(const char *zDir){
  sqlite3 *db = 0;
  char zPath[512], zUri[600];
  double now = 0;
  pOrig = sqlite3_vfs_find(0);
  CHECK(pOrig!=0);
  if( pOrig==0 ) return;
  CHECK_STR(pOrig->zName, "unix");
  CHECK(sqlite3_vfs_find("unix")==pOrig);
  CHECK(sqlite3_vfs_find("nope")==0);
  CHECK(pOrig->xCurrentTime(pOrig, &now)==SQLITE_OK && now>2460000.0);
  memset(&shimVfs, 0, sizeof(shimVfs));
  shimVfs.iVersion = 1;
  shimVfs.szOsFile = pOrig->szOsFile;
  shimVfs.mxPathname = pOrig->mxPathname;
  shimVfs.zName = "xq-shim";
  shimVfs.xOpen = shimOpen;
  shimVfs.xDelete = shimDelete;
  shimVfs.xAccess = shimAccess;
  shimVfs.xFullPathname = shimFull;
  shimVfs.xRandomness = shimRandom;
  shimVfs.xSleep = shimSleep;
  shimVfs.xCurrentTime = shimTime;
  CHECK_RC(sqlite3_vfs_register(&shimVfs, 0), SQLITE_OK, 0);
  CHECK(sqlite3_vfs_find(0)==pOrig);
  CHECK(sqlite3_vfs_find("xq-shim")==&shimVfs);
  CHECK(pOrig->pNext==&shimVfs);

  snprintf(zPath, sizeof(zPath), "%s/shim.db", zDir);
  CHECK_RC(sqlite3_open_v2(zPath, &db, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE, "xq-shim"), SQLITE_OK, db);
  exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES(1); BEGIN; INSERT INTO t VALUES(2); COMMIT");
  CHECK(nOpen>=2); /* the database and its journal */
  {
    sqlite3_vfs *pv = 0;
    CHECK_RC(sqlite3_file_control(db, "main", SQLITE_FCNTL_VFS_POINTER, &pv), SQLITE_OK, db);
    CHECK(pv==&shimVfs);
  }
  sqlite3_close(db);
  nOpen = 0;
  snprintf(zUri, sizeof(zUri), "file:%s?vfs=xq-shim", zPath);
  CHECK_RC(sqlite3_open_v2(zUri, &db, SQLITE_OPEN_READONLY|SQLITE_OPEN_URI, 0), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT sum(x) FROM t"), "3");
  CHECK(nOpen==1);
  sqlite3_close(db);

  CHECK_RC(sqlite3_open_v2(zPath, &db, SQLITE_OPEN_READWRITE, "nope"), SQLITE_ERROR, db);
  CHECK_STR(sqlite3_errmsg(db), "no such vfs: nope");
  sqlite3_close(db);

  CHECK_RC(sqlite3_vfs_register(&shimVfs, 1), SQLITE_OK, 0);
  CHECK(sqlite3_vfs_find(0)==&shimVfs);
  CHECK_RC(sqlite3_vfs_unregister(&shimVfs), SQLITE_OK, 0);
  CHECK(sqlite3_vfs_find(0)==pOrig);
  CHECK(sqlite3_vfs_find("xq-shim")==0);
}

/* -------------------------------------------------------------------- hooks */

static int nCommit = 0, nRollback = 0, nProgress = 0, vetoCommit = 0;
static char zUpdates[256];
static int commit_hook(void *p){ (void)p; nCommit++; return vetoCommit; }
static void rollback_hook(void *p){ (void)p; nRollback++; }
static void update_hook(void *p, int op, const char *zDb, const char *zTab, sqlite3_int64 rowid){
  char buf[64];
  (void)p;
  snprintf(buf, sizeof(buf), "%c %s.%s %lld;", op==SQLITE_INSERT ? 'I' : op==SQLITE_UPDATE ? 'U' : op==SQLITE_DELETE ? 'D' : '?', zDb, zTab, rowid);
  strcat(zUpdates, buf);
}
static int progress_cb(void *p){ (void)p; nProgress++; return nProgress>=5; }

static void test_hooks(void){
  sqlite3 *db = 0;
  CHECK_RC(sqlite3_open(":memory:", &db), SQLITE_OK, db);
  exec(db, "CREATE TABLE t(id INTEGER PRIMARY KEY, x)");
  CHECK(sqlite3_commit_hook(db, commit_hook, 0)==0);
  sqlite3_rollback_hook(db, rollback_hook, 0);
  sqlite3_update_hook(db, update_hook, 0);
  exec(db, "INSERT INTO t VALUES(1, 'a'), (2, 'b')");
  CHECK(nCommit==1);
  exec(db, "UPDATE t SET x = 'c' WHERE id = 2; DELETE FROM t WHERE id = 1");
  CHECK_STR(zUpdates, "I main.t 1;I main.t 2;U main.t 2;D main.t 1;");
  CHECK(nCommit==3);
  exec(db, "BEGIN; INSERT INTO t VALUES(3, 'd'); ROLLBACK");
  CHECK(nRollback==1);
  vetoCommit = 1;
  CHECK_RC(sqlite3_exec(db, "INSERT INTO t VALUES(4, 'e')", 0, 0, 0), SQLITE_CONSTRAINT, db);
  CHECK(sqlite3_extended_errcode(db)==SQLITE_CONSTRAINT_COMMITHOOK);
  CHECK(nRollback==2);
  vetoCommit = 0;
  CHECK_STR(one(db, "SELECT count(*) FROM t"), "1");
  sqlite3_commit_hook(db, 0, 0);
  sqlite3_update_hook(db, 0, 0);
  sqlite3_rollback_hook(db, 0, 0);

  sqlite3_progress_handler(db, 10, progress_cb, 0);
  CHECK_STR(one(db, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c) SELECT count(*) FROM c"), "ERROR: interrupted");
  CHECK(nProgress==5);
  sqlite3_progress_handler(db, 0, 0, 0);
  CHECK_STR(one(db, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x<1000) SELECT count(*) FROM c"), "1000");
  sqlite3_close(db);
}

/* -------------------------------------------------------------------- misc */

static int nAuto = 0;
static int auto_ext(sqlite3 *db, char **pzErr, const void *pApi){
  (void)pzErr; (void)pApi;
  nAuto++;
  return sqlite3_create_function(db, "auto_fn", 0, SQLITE_UTF8, 0, fn_ptr_make, 0, 0);
}

static void test_misc(void){
  sqlite3 *db = 0;
  sqlite3_stmt *p = 0;
  void *pData;
  CHECK_RC(sqlite3_auto_extension((void(*)(void))auto_ext), SQLITE_OK, 0);
  CHECK_RC(sqlite3_open(":memory:", &db), SQLITE_OK, db);
  CHECK(nAuto==1);
  CHECK_STR(one(db, "SELECT typeof(auto_fn())"), "null");
  CHECK(sqlite3_cancel_auto_extension((void(*)(void))auto_ext)==1);
  sqlite3_reset_auto_extension();

  /* Client data. */
  pData = malloc(4);
  CHECK_RC(sqlite3_set_clientdata(db, "k", pData, ptr_free), SQLITE_OK, db);
  CHECK(sqlite3_get_clientdata(db, "k")==pData);
  CHECK(sqlite3_get_clientdata(db, "x")==0);

  /* Interrupt. */
  exec(db, "CREATE TABLE t(x)");
  CHECK_RC(sqlite3_prepare_v2(db, "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c) SELECT x FROM c", -1, &p, 0), SQLITE_OK, db);
  CHECK_RC(sqlite3_step(p), SQLITE_ROW, db);
  sqlite3_interrupt(db);
  CHECK(sqlite3_is_interrupted(db));
  {
    int rc;
    do{ rc = sqlite3_step(p); }while( rc==SQLITE_ROW );
    CHECK(rc==SQLITE_INTERRUPT);
  }
  sqlite3_finalize(p);

  /* Unsupported interfaces fail cleanly. */
  {
    char *zErr = 0;
    CHECK(sqlite3_load_extension(db, "x", 0, &zErr)==SQLITE_ERROR);
    CHECK(zErr!=0);
    sqlite3_free(zErr);
  }
  CHECK(sqlite3_serialize(db, "main", 0, 0)==0);
  CHECK(sqlite3_column_table_name(0, 0)==0);

  nDestroy = 0;
  CHECK_RC(sqlite3_close(db), SQLITE_OK, 0);
  CHECK(nDestroy==1); /* the client data */
  CHECK_RC(sqlite3_close(0), SQLITE_OK, 0);
}

/* ===================================================== group A: engine callbacks */

/* -------------------------------------------------------------- authorizer */

static char zAuthLog[2048];
static int authDenyCode = -1, authIgnoreCode = -1;
static const char *zAuthArg = 0;
static int auth_cb(void *p, int code, const char *a, const char *b, const char *c, const char *d){
  char buf[160];
  (void)p;
  snprintf(buf, sizeof(buf), "%d %s %s %s %s;", code, a ? a : "-", b ? b : "-", c ? c : "-", d ? d : "-");
  if( strlen(zAuthLog)+strlen(buf) < sizeof(zAuthLog) ) strcat(zAuthLog, buf);
  if( zAuthArg && !((a && strcmp(a, zAuthArg)==0) || (b && strcmp(b, zAuthArg)==0)) ) return SQLITE_OK;
  if( code==authDenyCode ) return SQLITE_DENY;
  if( code==authIgnoreCode ) return SQLITE_IGNORE;
  return SQLITE_OK;
}

static void test_authorizer(void){
  sqlite3 *db = 0;
  sqlite3_stmt *p = 0;
  CHECK_RC(sqlite3_open(":memory:", &db), SQLITE_OK, db);
  exec(db, "CREATE TABLE t(a INTEGER PRIMARY KEY, b, c); CREATE TABLE log(x);"
           "CREATE VIEW v AS SELECT a, b FROM t;"
           "CREATE TRIGGER tr AFTER INSERT ON t BEGIN INSERT INTO log VALUES(new.b); END;"
           "INSERT INTO t VALUES(1, 2, 3)");
  CHECK_RC(sqlite3_set_authorizer(db, auth_cb, 0), SQLITE_OK, db);

  /* What each statement asks: the trigger's checks name it. */
  zAuthLog[0] = 0;
  exec(db, "INSERT INTO t VALUES(2, 'x', 'y')");
  CHECK_STR(zAuthLog, "18 t - main -;18 log - main tr;20 t b main tr;");
  zAuthLog[0] = 0;
  CHECK_STR(one(db, "SELECT b FROM v WHERE a = 1"), "2");
  CHECK_STR(zAuthLog, "21 - - - -;20 t a main v;20 t b main v;20 v b main -;20 v a main -;21 - - - v;");
  zAuthLog[0] = 0;
  CHECK_STR(one(db, "SELECT count(*) FROM t"), "2");
  CHECK_STR(zAuthLog, "21 - - - -;31 - count - -;20 t  - -;");
  zAuthLog[0] = 0;
  exec(db, "UPDATE t SET c = upper(c) WHERE a = 2");
  CHECK_STR(zAuthLog, "31 - upper - -;20 t c main -;23 t c main -;20 t a main -;");
  zAuthLog[0] = 0;
  exec(db, "BEGIN; SAVEPOINT s; RELEASE s; COMMIT; PRAGMA user_version");
  CHECK_STR(zAuthLog, "22 BEGIN - - -;32 BEGIN s - -;32 RELEASE s - -;22 COMMIT - - -;19 user_version - - -;");
  zAuthLog[0] = 0;
  exec(db, "CREATE INDEX i ON t(b); DROP INDEX i");
  CHECK_STR(zAuthLog, "18 sqlite_master - main -;1 i t main -;20 t b main -;18 sqlite_master - main -;27 i - main -;"
                      "9 sqlite_master - main -;10 i t main -;9 sqlite_master - main -;20 sqlite_master name main -;"
                      "20 sqlite_master type main -;23 sqlite_master rootpage main -;20 sqlite_master rootpage main -;");

  /* IGNORE: the column reads as NULL; the UPDATE of a column is skipped. */
  authIgnoreCode = SQLITE_READ; zAuthArg = "b";
  CHECK_STR(one(db, "SELECT quote(b) FROM t WHERE a = 1"), "NULL");
  CHECK_STR(one(db, "SELECT a FROM t WHERE b = 2"), "");
  authIgnoreCode = SQLITE_UPDATE; zAuthArg = "c";
  exec(db, "UPDATE t SET b = 20, c = 30 WHERE a = 1");
  authIgnoreCode = -1; zAuthArg = 0;
  CHECK_STR(one(db, "SELECT b || ',' || c FROM t WHERE a = 1"), "20,3");
  /* IGNORE of DELETE: no truncation, the rows are deleted one by one. */
  authIgnoreCode = SQLITE_DELETE; zAuthArg = "log";
  exec(db, "DELETE FROM log");
  authIgnoreCode = -1; zAuthArg = 0;
  CHECK_STR(one(db, "SELECT count(*) FROM log"), "0");

  /* DENY: an SQLITE_AUTH error. */
  authDenyCode = SQLITE_READ; zAuthArg = "c";
  CHECK_STR(one(db, "SELECT c FROM t"), "ERROR: access to t.c is prohibited");
  CHECK(sqlite3_errcode(db)==SQLITE_AUTH);
  authDenyCode = SQLITE_FUNCTION; zAuthArg = "upper";
  CHECK_STR(one(db, "SELECT upper('a')"), "ERROR: not authorized to use function: upper");
  CHECK_RC(sqlite3_exec(db, "CREATE TABLE d(x DEFAULT (upper('q')))", 0, 0, 0), SQLITE_ERROR, db);
  authDenyCode = SQLITE_INSERT; zAuthArg = "t";
  CHECK_RC(sqlite3_exec(db, "INSERT INTO t VALUES(9, 9, 9)", 0, 0, 0), SQLITE_AUTH, db);
  CHECK_STR(sqlite3_errmsg(db), "not authorized");
  authDenyCode = SQLITE_ATTACH; zAuthArg = 0;
  CHECK_RC(sqlite3_exec(db, "ATTACH ':memory:' AS aux", 0, 0, 0), SQLITE_AUTH, db);
  authDenyCode = -1;

  /* A new authorizer expires the statements prepared before. */
  CHECK_RC(sqlite3_prepare_v2(db, "SELECT c FROM t", -1, &p, 0), SQLITE_OK, db);
  CHECK(sqlite3_expired(p)==0);
  authDenyCode = SQLITE_READ; zAuthArg = "c";
  CHECK_RC(sqlite3_set_authorizer(db, auth_cb, 0), SQLITE_OK, db);
  CHECK(sqlite3_expired(p)!=0);
  CHECK_RC(sqlite3_step(p), SQLITE_AUTH, db);
  sqlite3_finalize(p);
  authDenyCode = -1; zAuthArg = 0;
  CHECK_RC(sqlite3_set_authorizer(db, 0, 0), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT c FROM t WHERE a = 1"), "3");
  sqlite3_close(db);
}

/* The authorizer sees the statements a dialect frontend lowers. */
static void test_authorizer_dialect(void){
  sqlite3 *db = 0;
  if( strcmp(sqlite3_sourceid(), SQLITE_SOURCE_ID)!=0 || sqlite3_libversion_number()!=SQLITE_VERSION_NUMBER ) return;
  if( sqlite3_open_v2("file::memory:?dialect=postgres", &db, SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE|SQLITE_OPEN_URI, 0)!=SQLITE_OK
   || strcmp(xqlite_dialect(db), "postgres")!=0 ){
    sqlite3_close(db);  /* not xqlite */
    return;
  }
  exec(db, "CREATE TABLE u (id bigserial PRIMARY KEY, secret text)");
  exec(db, "INSERT INTO u (secret) VALUES ('s')");
  CHECK_RC(sqlite3_set_authorizer(db, auth_cb, 0), SQLITE_OK, db);
  authIgnoreCode = SQLITE_READ; zAuthArg = "secret";
  zAuthLog[0] = 0;
  CHECK_STR(one(db, "SELECT id::text || ':' || coalesce(secret, 'hidden') FROM u"), "1:hidden");
  CHECK(strstr(zAuthLog, "20 u secret main -;")!=0);
  CHECK(strstr(zAuthLog, "xq_catalog")==0);
  authIgnoreCode = -1; authDenyCode = SQLITE_DELETE; zAuthArg = "u";
  CHECK_RC(sqlite3_exec(db, "DELETE FROM u WHERE id = $1", 0, 0, 0), SQLITE_AUTH, db);
  authDenyCode = -1; zAuthArg = 0;
  sqlite3_close(db);
}

/* -------------------------------------------------------- collation needed */

static int nCollNeeded = 0;
static int needed_rev(void *p, int n1, const void *a, int n2, const void *b){
  int r = memcmp(a, b, n1<n2 ? n1 : n2);
  (void)p;
  return r ? -r : n2-n1;
}
static void coll_needed(void *p, sqlite3 *db, int enc, const char *z){
  (void)p;
  nCollNeeded++;
  CHECK(enc==SQLITE_UTF8);
  if( strcmp(z, "rev")==0 ) sqlite3_create_collation(db, z, SQLITE_UTF8, 0, needed_rev);
}
static void coll_needed16(void *p, sqlite3 *db, int enc, const void *z){
  const unsigned short *u = (const unsigned short*)z;
  (void)p;
  nCollNeeded++;
  CHECK(enc==SQLITE_UTF8);
  if( u[0]=='r' && u[1]=='2' && u[2]==0 ) sqlite3_create_collation(db, "r2", SQLITE_UTF8, 0, needed_rev);
}

static void test_collation_needed(void){
  sqlite3 *db = 0;
  CHECK_RC(sqlite3_open(":memory:", &db), SQLITE_OK, db);
  exec(db, "CREATE TABLE t(x); INSERT INTO t VALUES('a'), ('c'), ('b')");
  CHECK_STR(one(db, "SELECT group_concat(x, '') FROM (SELECT x FROM t ORDER BY x COLLATE rev)"), "ERROR: no such collation sequence: rev");
  CHECK_RC(sqlite3_collation_needed(db, 0, coll_needed), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT group_concat(x, '') FROM (SELECT x FROM t ORDER BY x COLLATE rev)"), "cba");
  CHECK(nCollNeeded==1);
  CHECK_STR(one(db, "SELECT 'a' < 'b' COLLATE rev"), "0");
  CHECK(nCollNeeded==1);
  CHECK_STR(one(db, "SELECT 1 ORDER BY 1 COLLATE nope"), "ERROR: no such collation sequence: nope");
  CHECK(sqlite3_extended_errcode(db)==SQLITE_ERROR_MISSING_COLLSEQ);
  CHECK(nCollNeeded==2);
  CHECK_RC(sqlite3_collation_needed16(db, 0, coll_needed16), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT max(x COLLATE r2) FROM t"), "a");
  CHECK(nCollNeeded==3);
  sqlite3_close(db);
}

/* -------------------------------------------------------- autovacuum pages */

static int nAvKeep = 0, nAvDestroy = 0;
static char zAvLog[256];
static unsigned int av_pages(void *p, const char *zSchema, unsigned int nOrig, unsigned int nFree, unsigned int szPage){
  char buf[80];
  (void)p;
  snprintf(buf, sizeof(buf), "%s %u %u %u;", zSchema, nOrig, nFree, szPage);
  if( strlen(zAvLog)+strlen(buf) < sizeof(zAvLog) ) strcat(zAvLog, buf);
  return nFree > (unsigned)nAvKeep ? nFree - nAvKeep : 0;
}
static void av_destroy(void *p){ (void)p; nAvDestroy++; }

static void test_autovacuum_pages(const char *zDir){
  sqlite3 *db = 0;
  char zPath[512];
  snprintf(zPath, sizeof(zPath), "%s/av.db", zDir);
  CHECK_RC(sqlite3_open(zPath, &db), SQLITE_OK, db);
  exec(db, "PRAGMA page_size=4096; PRAGMA auto_vacuum=FULL; CREATE TABLE t(x);"
           "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i<100) INSERT INTO t SELECT randomblob(1000) FROM c");
  CHECK_STR(one(db, "PRAGMA page_count"), "28");
  CHECK_RC(sqlite3_autovacuum_pages(db, av_pages, 0, av_destroy), SQLITE_OK, db);
  CHECK_RC(sqlite3_autovacuum_pages(db, av_pages, 0, av_destroy), SQLITE_OK, db);
  CHECK(nAvDestroy==1);
  /* Keep 5 of the 12 free pages. */
  nAvKeep = 5;
  exec(db, "DELETE FROM t WHERE rowid > 50");
  CHECK_STR(zAvLog, "main 28 12 4096;");
  CHECK_STR(one(db, "PRAGMA page_count"), "21");
  CHECK_STR(one(db, "PRAGMA freelist_count"), "5");
  /* Keep them all. */
  nAvKeep = 1000;
  exec(db, "DELETE FROM t WHERE rowid > 25");
  CHECK_STR(one(db, "PRAGMA page_count"), "21");
  CHECK_STR(one(db, "PRAGMA freelist_count"), "11");
  /* Give back everything. */
  nAvKeep = 0;
  exec(db, "DELETE FROM t WHERE rowid > 20");
  CHECK_STR(one(db, "PRAGMA page_count"), "8");
  CHECK_STR(one(db, "PRAGMA freelist_count"), "0");
  CHECK_STR(one(db, "PRAGMA integrity_check"), "ok");
  sqlite3_close(db);
  CHECK(nAvDestroy==2);
}

/* ------------------------------------------------ xFindFunction overloads */

/* fx: a table of value 1..10 whose xFindFunction overloads upper() and
** makes fmod3(value, k) a constraint (SQLITE_INDEX_CONSTRAINT_FUNCTION). */
typedef struct FxCursor { sqlite3_vtab_cursor base; int i, mod; } FxCursor;
static int nFxConsFunction = 0;
static int fxConnect(sqlite3 *db, void *pAux, int argc, const char *const*argv, sqlite3_vtab **ppVtab, char **pzErr){
  (void)pAux; (void)argc; (void)argv; (void)pzErr;
  sqlite3_declare_vtab(db, "CREATE TABLE x(value INTEGER)");
  *ppVtab = sqlite3_malloc(sizeof(sqlite3_vtab));
  memset(*ppVtab, 0, sizeof(sqlite3_vtab));
  return SQLITE_OK;
}
static int fxDisconnect(sqlite3_vtab *p){ sqlite3_free(p); return SQLITE_OK; }
static int fxOpen(sqlite3_vtab *p, sqlite3_vtab_cursor **pp){
  FxCursor *c = sqlite3_malloc(sizeof(*c));
  (void)p;
  memset(c, 0, sizeof(*c));
  *pp = &c->base;
  return SQLITE_OK;
}
static int fxClose(sqlite3_vtab_cursor *p){ sqlite3_free(p); return SQLITE_OK; }
static int fxNext(sqlite3_vtab_cursor *p){
  FxCursor *c = (FxCursor*)p;
  do{ c->i++; }while( c->mod && c->i<=10 && c->i % c->mod != 0 );
  return SQLITE_OK;
}
static int fxFilter(sqlite3_vtab_cursor *p, int idxNum, const char *idxStr, int argc, sqlite3_value **argv){
  FxCursor *c = (FxCursor*)p;
  (void)idxStr;
  c->mod = (idxNum==1 && argc==1) ? sqlite3_value_int(argv[0]) : 0;
  c->i = 0;
  return fxNext(p);
}
static int fxEof(sqlite3_vtab_cursor *p){ return ((FxCursor*)p)->i > 10; }
static int fxColumn(sqlite3_vtab_cursor *p, sqlite3_context *ctx, int i){
  (void)i;
  sqlite3_result_int(ctx, ((FxCursor*)p)->i);
  return SQLITE_OK;
}
static int fxRowid(sqlite3_vtab_cursor *p, sqlite3_int64 *pRowid){ *pRowid = ((FxCursor*)p)->i; return SQLITE_OK; }
static int fxBestIndex(sqlite3_vtab *tab, sqlite3_index_info *info){
  int i;
  (void)tab;
  info->idxNum = 0;
  for(i=0; i<info->nConstraint; i++){
    if( info->aConstraint[i].op==SQLITE_INDEX_CONSTRAINT_FUNCTION && info->aConstraint[i].usable ){
      nFxConsFunction++;
      info->aConstraintUsage[i].argvIndex = 1;
      info->aConstraintUsage[i].omit = 1;
      info->idxNum = 1;
    }
  }
  info->estimatedCost = info->idxNum ? 1 : 100;
  return SQLITE_OK;
}
static void fx_upper(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  (void)argc;
  sqlite3_result_text(ctx, (const char*)sqlite3_user_data(ctx), -1, SQLITE_TRANSIENT);
  (void)argv;
}
static void fx_mod3(sqlite3_context *ctx, int argc, sqlite3_value **argv){
  (void)argc;
  sqlite3_result_int(ctx, sqlite3_value_int(argv[0]) % sqlite3_value_int(argv[1])==0);
}
static int fxFindFunction(sqlite3_vtab *p, int nArg, const char *zName, void (**pxFunc)(sqlite3_context*,int,sqlite3_value**), void **ppArg){
  (void)p;
  if( nArg==1 && strcmp(zName, "upper")==0 ){
    *pxFunc = fx_upper;
    *ppArg = (void*)"overloaded";
    return 1;
  }
  if( nArg==2 && strcmp(zName, "fmod3")==0 ){
    *pxFunc = fx_mod3;
    *ppArg = 0;
    return SQLITE_INDEX_CONSTRAINT_FUNCTION;
  }
  return 0;
}
static sqlite3_module fxModule = {
  0, fxConnect, fxConnect, fxBestIndex, fxDisconnect, fxDisconnect, fxOpen, fxClose,
  fxFilter, fxNext, fxEof, fxColumn, fxRowid,
  0, 0, 0, 0, 0, fxFindFunction, 0, 0, 0, 0, 0, 0
};

static void test_find_function(void){
  sqlite3 *db = 0;
  CHECK_RC(sqlite3_open(":memory:", &db), SQLITE_OK, db);
  CHECK_RC(sqlite3_create_module(db, "fx", &fxModule, 0), SQLITE_OK, db);
  exec(db, "CREATE VIRTUAL TABLE f USING fx");
  CHECK_STR(one(db, "SELECT upper(value) FROM f"), "overloaded");
  CHECK_STR(one(db, "SELECT upper('x') FROM f"), "X");
  CHECK_RC(sqlite3_overload_function(db, "fmod3", 2), SQLITE_OK, db);
  CHECK_STR(one(db, "SELECT group_concat(value) FROM f WHERE fmod3(value, 3)"), "3,6,9");
  CHECK(nFxConsFunction>0);
  CHECK_STR(one(db, "SELECT group_concat(value) FROM f WHERE fmod3(value, 4) OR value = 1"), "1,4,8");
  sqlite3_close(db);
}

/* ================================================= end of group A */

int main(void){
  char zDir[] = "/tmp/xqlite-capi-XXXXXX";
  if( mkdtemp(zDir)==0 ){ perror("mkdtemp"); return 1; }
  test_library();
  test_printf();
  test_statements();
  test_functions();
  test_utf16();
  test_dialects();
  test_files(zDir);
  test_trace();
  test_hooks();
  test_vtab();
  test_vfs(zDir);
  test_misc();
  test_authorizer();
  test_authorizer_dialect();
  test_collation_needed();
  test_autovacuum_pages(zDir);
  test_find_function();
  {
    char zCmd[600];
    snprintf(zCmd, sizeof(zCmd), "rm -rf '%s'", zDir);
    if( system(zCmd)!=0 ) fprintf(stderr, "could not remove %s\n", zDir);
  }
  printf("capi_test: %d checks, %d failed\n", nCheck, nFail);
  return nFail ? 1 : 0;
}

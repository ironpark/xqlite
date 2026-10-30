/*
** The parts of xqlite's C ABI that are written in C (src/capi/*.zig has
** the rest):
**
**  - The variadic interfaces: sqlite3_mprintf() and friends,
**    sqlite3_str_appendf(), sqlite3_log(), sqlite3_config(),
**    sqlite3_db_config(), sqlite3_vtab_config() and
**    sqlite3_test_control(). Zig cannot define C variadic functions on
**    every target it builds for, so they are here: each reads its
**    arguments out of the va_list (for printf, as the format string
**    says) and calls a plain function of the Zig side (xq_*).
**
**  - sqlite3_mutex_*(), on POSIX threads.
*/
#ifndef _GNU_SOURCE
# define _GNU_SOURCE /* PTHREAD_MUTEX_RECURSIVE with glibc */
#endif
#if defined(__wasi__) && !defined(_REENTRANT)
# define XQ_NO_THREADS 1 /* single-threaded WebAssembly: no-op mutexes */
#else
# include <pthread.h>
#endif
#include <stdlib.h>
#include <string.h>
#include "sqlite3.h"

/* ------------------------------------------------------------- printf */

/* One argument read out of a va_list (XqArg in capi/printf.zig). */
typedef struct XqArg {
  int kind;
  union { sqlite3_int64 i; double d; const char *s; void *p; } v;
} XqArg;
#define XQ_INT 0
#define XQ_DOUBLE 1
#define XQ_STR 2
#define XQ_STR_FREE 3

char *xq_vmprintf(const char*, const XqArg*, int);
char *xq_vsnprintf(int, char*, const char*, const XqArg*, int);
void xq_str_vappendf(sqlite3_str*, const char*, const XqArg*, int);
void xq_log(int, const char*, const XqArg*, int);
int xq_log_enabled(void);
int xq_config(int, sqlite3_int64, sqlite3_int64, void*, void*);
int xq_db_config(sqlite3*, int, sqlite3_int64, sqlite3_int64, void*, int*);
int xq_vtab_config(sqlite3*, int, int);

/* The arguments of sqlite3_test_control(), as the op takes them. */
typedef struct XqTestArgs {
  void *p[3];          /* pointers, in order */
  sqlite3_int64 i[3];  /* integers, in order */
  double r;            /* SQLITE_TESTCTRL_LOGEST */
} XqTestArgs;
int xq_test_control(int, XqTestArgs*);

/*
** The arguments `zFormat` reads from `*ap`, into `*paArg` (a[] if they
** fit, else memory from malloc()): the same walk over the format as the
** engine's vappendf() (sql/printf.zig, a port of printf.c), taking the
** argument each conversion takes. Returns the count, or -1 on OOM.
*/
static int collectArgs(const char *zFormat, va_list *ap, XqArg *a, int nA, XqArg **paArg){
  const char *z;
  int n = 0, nMax = 0;
  XqArg *aArg = a;
  for(z=zFormat; *z; z++) if( *z=='%' ) nMax += 3;
  if( nMax>nA ){
    aArg = malloc(sizeof(XqArg)*(size_t)nMax);
    if( aArg==0 ) return -1;
  }
  *paArg = aArg;
  for(z=zFormat; *z; z++){
    int c, flagLong = 0, done = 0;
    if( *z!='%' ) continue;
    c = *++z;
    if( c==0 ) break;
    /* Flags, width, precision and size. */
    while( !done ){
      switch( c ){
        case '-': case '+': case ' ': case '#': case '!': case '0': case ',':
          break;
        case 'l':
          flagLong = 1;
          c = *++z;
          if( c=='l' ){ c = *++z; flagLong = 2; }
          done = 1;
          break;
        case '1': case '2': case '3': case '4': case '5':
        case '6': case '7': case '8': case '9':
          do{ c = *++z; }while( c>='0' && c<='9' );
          if( c!='.' && c!='l' ) done = 1; else z--;
          break;
        case '*':
          aArg[n].kind = XQ_INT; aArg[n++].v.i = va_arg(*ap, int);
          c = z[1];
          if( c!='.' && c!='l' ){ c = *++z; done = 1; }
          break;
        case '.':
          c = *++z;
          if( c=='*' ){
            aArg[n].kind = XQ_INT; aArg[n++].v.i = va_arg(*ap, int);
            c = *++z;
          }else{
            while( c>='0' && c<='9' ) c = *++z;
          }
          if( c=='l' ) z--; else done = 1;
          break;
        default:
          done = 1;
          break;
      }
      if( done ) break;
      c = *++z;
      if( c==0 ) break;
    }
    if( c==0 ) break;
    /* The conversion. */
    switch( c ){
      case 'd': case 'i': case 'r':
        aArg[n].kind = XQ_INT;
        if( flagLong==2 ) aArg[n].v.i = va_arg(*ap, sqlite3_int64);
        else if( flagLong==1 ) aArg[n].v.i = va_arg(*ap, long);
        else aArg[n].v.i = va_arg(*ap, int);
        n++;
        break;
      case 'u': case 'x': case 'X': case 'o':
        aArg[n].kind = XQ_INT;
        if( flagLong==2 ) aArg[n].v.i = (sqlite3_int64)va_arg(*ap, sqlite3_uint64);
        else if( flagLong==1 ) aArg[n].v.i = (sqlite3_int64)va_arg(*ap, unsigned long);
        else aArg[n].v.i = va_arg(*ap, unsigned int);
        n++;
        break;
      case 'c':
        aArg[n].kind = XQ_INT; aArg[n++].v.i = va_arg(*ap, unsigned int);
        break;
      case 'p':
        aArg[n].kind = XQ_INT; aArg[n++].v.i = (sqlite3_int64)(size_t)va_arg(*ap, void*);
        break;
      case 'e': case 'E': case 'f': case 'g': case 'G':
        aArg[n].kind = XQ_DOUBLE; aArg[n++].v.d = va_arg(*ap, double);
        break;
      case 's': case 'q': case 'Q': case 'w': case 'j': case 'J':
        aArg[n].kind = XQ_STR; aArg[n++].v.s = va_arg(*ap, const char*);
        break;
      case 'z':
        aArg[n].kind = XQ_STR_FREE; aArg[n++].v.s = va_arg(*ap, const char*);
        break;
      case 'n':
        /* The engine writes no count; the int* is skipped. */
        (void)va_arg(*ap, int*);
        break;
      case '%':
        break;
      default:
        /* %T, %S (internal only) and unknown conversions end the output,
        ** as in SQLite. */
        return n;
    }
  }
  return n;
}

#define WITH_ARGS(FMT, AP, BODY) do{ \
  XqArg aBuf_[24]; XqArg *aArg_ = 0; int nArg_; \
  va_list cp_; va_copy(cp_, AP); \
  nArg_ = collectArgs(FMT, &cp_, aBuf_, 24, &aArg_); \
  va_end(cp_); \
  if( nArg_>=0 ){ BODY; } \
  if( aArg_ && aArg_!=aBuf_ ) free(aArg_); \
}while(0)

char *sqlite3_vmprintf(const char *zFormat, va_list ap){
  char *z = 0;
  if( zFormat==0 ) return 0;
  WITH_ARGS(zFormat, ap, z = xq_vmprintf(zFormat, aArg_, nArg_));
  return z;
}

char *sqlite3_mprintf(const char *zFormat, ...){
  va_list ap;
  char *z;
  va_start(ap, zFormat);
  z = sqlite3_vmprintf(zFormat, ap);
  va_end(ap);
  return z;
}

char *sqlite3_vsnprintf(int n, char *zBuf, const char *zFormat, va_list ap){
  if( n<=0 || zBuf==0 ) return zBuf;
  if( zFormat==0 ){ zBuf[0] = 0; return zBuf; }
  WITH_ARGS(zFormat, ap, xq_vsnprintf(n, zBuf, zFormat, aArg_, nArg_));
  return zBuf;
}

char *sqlite3_snprintf(int n, char *zBuf, const char *zFormat, ...){
  va_list ap;
  va_start(ap, zFormat);
  zBuf = sqlite3_vsnprintf(n, zBuf, zFormat, ap);
  va_end(ap);
  return zBuf;
}

void sqlite3_str_vappendf(sqlite3_str *p, const char *zFormat, va_list ap){
  if( p==0 || zFormat==0 ) return;
  WITH_ARGS(zFormat, ap, xq_str_vappendf(p, zFormat, aArg_, nArg_));
}

void sqlite3_str_appendf(sqlite3_str *p, const char *zFormat, ...){
  va_list ap;
  va_start(ap, zFormat);
  sqlite3_str_vappendf(p, zFormat, ap);
  va_end(ap);
}

void sqlite3_log(int iErrCode, const char *zFormat, ...){
  va_list ap;
  if( zFormat==0 || !xq_log_enabled() ) return;
  va_start(ap, zFormat);
  WITH_ARGS(zFormat, ap, xq_log(iErrCode, zFormat, aArg_, nArg_));
  va_end(ap);
}

/* ------------------------------------------------------------ config */

int sqlite3_config(int op, ...){
  va_list ap;
  sqlite3_int64 a = 0, b = 0;
  void *p = 0, *q = 0;
  int rc;
  va_start(ap, op);
  switch( op ){
    case SQLITE_CONFIG_SINGLETHREAD:
    case SQLITE_CONFIG_MULTITHREAD:
    case SQLITE_CONFIG_SERIALIZED:
      break;
    case SQLITE_CONFIG_MALLOC:
    case SQLITE_CONFIG_GETMALLOC:
    case SQLITE_CONFIG_MUTEX:
    case SQLITE_CONFIG_GETMUTEX:
    case SQLITE_CONFIG_PCACHE:
    case SQLITE_CONFIG_GETPCACHE:
    case SQLITE_CONFIG_PCACHE2:
    case SQLITE_CONFIG_GETPCACHE2:
    case SQLITE_CONFIG_PCACHE_HDRSZ:
    case SQLITE_CONFIG_ROWID_IN_VIEW:
      p = va_arg(ap, void*);
      break;
    case SQLITE_CONFIG_SCRATCH:
    case SQLITE_CONFIG_PAGECACHE:
    case SQLITE_CONFIG_HEAP:
      p = va_arg(ap, void*);
      a = va_arg(ap, int);
      b = va_arg(ap, int);
      break;
    case SQLITE_CONFIG_LOOKASIDE:
      a = va_arg(ap, int);
      b = va_arg(ap, int);
      break;
    case SQLITE_CONFIG_LOG:
    case SQLITE_CONFIG_SQLLOG:
      p = (void*)va_arg(ap, void(*)(void));
      q = va_arg(ap, void*);
      break;
    case SQLITE_CONFIG_MMAP_SIZE:
      a = va_arg(ap, sqlite3_int64);
      b = va_arg(ap, sqlite3_int64);
      break;
    case SQLITE_CONFIG_MEMDB_MAXSIZE:
      a = va_arg(ap, sqlite3_int64);
      break;
    case SQLITE_CONFIG_PMASZ:
      a = va_arg(ap, unsigned int);
      break;
    case SQLITE_CONFIG_MEMSTATUS:
    case SQLITE_CONFIG_URI:
    case SQLITE_CONFIG_COVERING_INDEX_SCAN:
    case SQLITE_CONFIG_WIN32_HEAPSIZE:
    case SQLITE_CONFIG_STMTJRNL_SPILL:
    case SQLITE_CONFIG_SMALL_MALLOC:
    case SQLITE_CONFIG_SORTERREF_SIZE:
      a = va_arg(ap, int);
      break;
    default:
      va_end(ap);
      return SQLITE_ERROR;
  }
  va_end(ap);
  rc = xq_config(op, a, b, p, q);
  return rc;
}

int sqlite3_db_config(sqlite3 *db, int op, ...){
  va_list ap;
  sqlite3_int64 a = 0, b = 0;
  void *p = 0;
  int *pRes = 0;
  va_start(ap, op);
  switch( op ){
    case SQLITE_DBCONFIG_MAINDBNAME:
      p = va_arg(ap, char*);
      break;
    case SQLITE_DBCONFIG_LOOKASIDE:
      p = va_arg(ap, void*);
      a = va_arg(ap, int);
      b = va_arg(ap, int);
      break;
    default:
      if( op>=SQLITE_DBCONFIG_ENABLE_FKEY && op<=SQLITE_DBCONFIG_MAX ){
        a = va_arg(ap, int);
        pRes = va_arg(ap, int*);
      }
      break;
  }
  va_end(ap);
  return xq_db_config(db, op, a, b, p, pRes);
}

int sqlite3_vtab_config(sqlite3 *db, int op, ...){
  va_list ap;
  int arg = 0;
  va_start(ap, op);
  if( op==SQLITE_VTAB_CONSTRAINT_SUPPORT ) arg = va_arg(ap, int);
  va_end(ap);
  return xq_vtab_config(db, op, arg);
}

int sqlite3_test_control(int op, ...){
  va_list ap;
  XqTestArgs a;
  int rc;
  memset(&a, 0, sizeof(a));
  va_start(ap, op);
  switch( op ){
    case SQLITE_TESTCTRL_PRNG_SEED:              /* int, sqlite3* */
    case SQLITE_TESTCTRL_LOCALTIME_FAULT:        /* int [, xAltLocaltime] */
    case SQLITE_TESTCTRL_TRACEFLAGS:             /* int, u32* */
    case SQLITE_TESTCTRL_TUNE:                   /* int, int* */
    case SQLITE_TESTCTRL_BITVEC_TEST:            /* int, int* */
      a.i[0] = va_arg(ap, int);
      if( op==SQLITE_TESTCTRL_LOCALTIME_FAULT ){
        if( a.i[0]==2 ) a.p[0] = (void*)va_arg(ap, int(*)(const void*,void*));
      }else{
        a.p[0] = va_arg(ap, void*);
      }
      break;
    case SQLITE_TESTCTRL_FK_NO_ACTION:           /* sqlite3*, int */
    case SQLITE_TESTCTRL_SORTER_MMAP:
      a.p[0] = va_arg(ap, void*);
      a.i[0] = va_arg(ap, int);
      break;
    case SQLITE_TESTCTRL_OPTIMIZATIONS:          /* sqlite3*, u32 */
      a.p[0] = va_arg(ap, void*);
      a.i[0] = va_arg(ap, unsigned int);
      break;
    case SQLITE_TESTCTRL_FAULT_INSTALL:          /* int(*)(int) */
      a.p[0] = (void*)va_arg(ap, int(*)(int));
      break;
    case SQLITE_TESTCTRL_BENIGN_MALLOC_HOOKS:    /* void(*)(void) x2 */
      a.p[0] = (void*)va_arg(ap, void(*)(void));
      a.p[1] = (void*)va_arg(ap, void(*)(void));
      break;
    case SQLITE_TESTCTRL_PENDING_BYTE:           /* unsigned int */
      a.i[0] = va_arg(ap, unsigned int);
      break;
    case SQLITE_TESTCTRL_ASSERT:                 /* int */
    case SQLITE_TESTCTRL_ALWAYS:
    case SQLITE_TESTCTRL_ONCE_RESET_THRESHOLD:
    case SQLITE_TESTCTRL_NEVER_CORRUPT:
    case SQLITE_TESTCTRL_EXTRA_SCHEMA_CHECKS:
      a.i[0] = va_arg(ap, int);
      break;
    case SQLITE_TESTCTRL_JSON_SELFCHECK:         /* int* */
    case SQLITE_TESTCTRL_GETOPT:                 /* sqlite3*, int* */
    case SQLITE_TESTCTRL_INTERNAL_FUNCTIONS:     /* sqlite3* */
    case SQLITE_TESTCTRL_RESULT_INTREAL:         /* sqlite3_context* */
    case SQLITE_TESTCTRL_PARSER_COVERAGE:        /* FILE* */
    case SQLITE_TESTCTRL_SEEK_COUNT:             /* sqlite3*, u64* */
    case SQLITE_TESTCTRL_ATOF:                   /* const char*, double* */
    case SQLITE_TESTCTRL_VDBE_COVERAGE:          /* callback, void* */
      a.p[0] = va_arg(ap, void*);
      if( op==SQLITE_TESTCTRL_GETOPT || op==SQLITE_TESTCTRL_SEEK_COUNT
       || op==SQLITE_TESTCTRL_ATOF || op==SQLITE_TESTCTRL_VDBE_COVERAGE ){
        a.p[1] = va_arg(ap, void*);
      }
      break;
    case SQLITE_TESTCTRL_IMPOSTER:               /* sqlite3*, char*, int, int */
      a.p[0] = va_arg(ap, void*);
      a.p[1] = va_arg(ap, char*);
      a.i[0] = va_arg(ap, int);
      a.i[1] = va_arg(ap, int);
      break;
    case SQLITE_TESTCTRL_LOGEST:                 /* double, int*, u64*, int* */
      a.r = va_arg(ap, double);
      a.p[0] = va_arg(ap, int*);
      a.p[1] = va_arg(ap, sqlite3_uint64*);
      a.p[2] = va_arg(ap, int*);
      break;
    default:
      break;
  }
  va_end(ap);
  rc = xq_test_control(op, &a);
  return rc;
}

/* -------------------------------------------------------------- mutex */

/*
** sqlite3_mutex_*(): recursive and fast mutexes on POSIX threads, and
** the static ones (SQLITE_MUTEX_STATIC_*), for applications and
** extensions. The library itself does not lock connections
** (multi-thread mode, sqlite3_threadsafe() == 2).
*/
#ifdef XQ_NO_THREADS
struct sqlite3_mutex { int id; int nRef; };
static sqlite3_mutex aStatic[12];
sqlite3_mutex *sqlite3_mutex_alloc(int id){
  sqlite3_mutex *p;
  if( id==SQLITE_MUTEX_FAST || id==SQLITE_MUTEX_RECURSIVE ){
    p = malloc(sizeof(*p));
    if( p ){ p->id = id; p->nRef = 0; }
    return p;
  }
  if( id<2 || id-2>=12 ) return 0;
  return &aStatic[id-2];
}
void sqlite3_mutex_free(sqlite3_mutex *p){ if( p && p->id<=1 ) free(p); }
void sqlite3_mutex_enter(sqlite3_mutex *p){ if( p ) p->nRef++; }
int sqlite3_mutex_try(sqlite3_mutex *p){ if( p ) p->nRef++; return SQLITE_OK; }
void sqlite3_mutex_leave(sqlite3_mutex *p){ if( p ) p->nRef--; }
int sqlite3_mutex_held(sqlite3_mutex *p){ return p==0 || p->nRef>0; }
int sqlite3_mutex_notheld(sqlite3_mutex *p){ return p==0 || p->nRef==0; }
#else
struct sqlite3_mutex {
  pthread_mutex_t m;
  int id;
  int nRef;
  pthread_t owner;
};

#define N_STATIC_MUTEX 12
static sqlite3_mutex aStatic[N_STATIC_MUTEX];
static pthread_once_t staticOnce = PTHREAD_ONCE_INIT;

static void initMutex(sqlite3_mutex *p, int id){
  pthread_mutexattr_t attr;
  pthread_mutexattr_init(&attr);
  pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
  pthread_mutex_init(&p->m, &attr);
  pthread_mutexattr_destroy(&attr);
  p->id = id;
  p->nRef = 0;
}

static void initStatic(void){
  int i;
  for(i=0; i<N_STATIC_MUTEX; i++) initMutex(&aStatic[i], i+2);
}

sqlite3_mutex *sqlite3_mutex_alloc(int id){
  sqlite3_mutex *p;
  if( id==SQLITE_MUTEX_FAST || id==SQLITE_MUTEX_RECURSIVE ){
    p = malloc(sizeof(*p));
    if( p ) initMutex(p, id);
    return p;
  }
  if( id<2 || id-2>=N_STATIC_MUTEX ) return 0;
  pthread_once(&staticOnce, initStatic);
  return &aStatic[id-2];
}

void sqlite3_mutex_free(sqlite3_mutex *p){
  if( p==0 || p->id>1 ) return;
  pthread_mutex_destroy(&p->m);
  free(p);
}

void sqlite3_mutex_enter(sqlite3_mutex *p){
  if( p==0 ) return;
  pthread_mutex_lock(&p->m);
  p->owner = pthread_self();
  p->nRef++;
}

int sqlite3_mutex_try(sqlite3_mutex *p){
  if( p==0 ) return SQLITE_OK;
  if( pthread_mutex_trylock(&p->m)!=0 ) return SQLITE_BUSY;
  p->owner = pthread_self();
  p->nRef++;
  return SQLITE_OK;
}

void sqlite3_mutex_leave(sqlite3_mutex *p){
  if( p==0 ) return;
  p->nRef--;
  pthread_mutex_unlock(&p->m);
}

int sqlite3_mutex_held(sqlite3_mutex *p){
  return p==0 || (p->nRef>0 && pthread_equal(p->owner, pthread_self()));
}

int sqlite3_mutex_notheld(sqlite3_mutex *p){
  return p==0 || p->nRef==0 || !pthread_equal(p->owner, pthread_self());
}
#endif /* XQ_NO_THREADS */

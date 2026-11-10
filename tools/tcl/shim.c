/*
** The part of SQLite's testfixture that xqlite's TCL test harness
** (tools/tcl/README.md, docs/testing.md) replaces.
**
** SQLite's testfixture is tclsqlite.c and the test*.c helpers compiled
** together with SQLite's own sources, so the helpers call internal
** functions (sqlite3ErrName, sqlite3OsRead, sqlite3ValueNew ...) and read
** internal globals. The harness links the same helpers with a library
** that exports only the public API: libxqlite3, or SQLite's amalgamation,
** whose internal functions are static. This file gives them what they
** need:
**
**   - internal helpers rewritten on top of the public API (the error
**     names, the sqlite3Os* calls through sqlite3_file and sqlite3_vfs,
**     sqlite3_value replacements for the UTF conversions of test1.c, the
**     character table, memory helpers);
**   - the counters a SQLITE_TEST build of SQLite keeps (sqlite_search_count
**     and the like) as plain variables that stay 0, and the test-only
**     globals of os_unix.c;
**   - stubs for the internal functions of the helpers it cannot rebuild
**     (pager, btree and VDBE internals): calling one is an error that
**     names it, never a silent result;
**   - Init functions that do nothing for the helpers left out (test2.c,
**     test3.c, test5.c, rtree, fts5, rbu, recover, intck);
**   - xqtclTestInit, the TCLSH_INIT_PROC: sqlite3TestInit() of
**     test_tclsh.c, then Tcl commands replaced where the original reads
**     SQLite's structures (listed in aOverride below).
**
** Both builds of the harness (testfixture-xqlite, testfixture-sqlite) use
** this file, so a test that fails only because of it fails on both.
**
** Parts are copied from SQLite 3.54.1 (main.c, global.c, os.c), which is
** in the public domain.
*/
#include "sqliteInt.h"
#include "vdbeInt.h"
#include <tcl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* "sqlite" or "xqlite": the engine the fixture is linked with. */
#ifndef XQTCL_ENGINE
# define XQTCL_ENGINE "sqlite"
#endif

/* ------------------------------------------------------------ errors */

const char *sqlite3ErrName(int rc){
  static const struct { int rc; const char *z; } aName[] = {
#define N(X) { X, #X }
    N(SQLITE_OK), N(SQLITE_ERROR), N(SQLITE_ERROR_SNAPSHOT),
    N(SQLITE_ERROR_RETRY), N(SQLITE_ERROR_MISSING_COLLSEQ),
    N(SQLITE_INTERNAL), N(SQLITE_PERM), N(SQLITE_ABORT),
    N(SQLITE_ABORT_ROLLBACK), N(SQLITE_BUSY), N(SQLITE_BUSY_RECOVERY),
    N(SQLITE_BUSY_SNAPSHOT), N(SQLITE_LOCKED), N(SQLITE_LOCKED_SHAREDCACHE),
    N(SQLITE_NOMEM), N(SQLITE_READONLY), N(SQLITE_READONLY_RECOVERY),
    N(SQLITE_READONLY_CANTINIT), N(SQLITE_READONLY_ROLLBACK),
    N(SQLITE_READONLY_DBMOVED), N(SQLITE_READONLY_DIRECTORY),
    N(SQLITE_INTERRUPT), N(SQLITE_IOERR), N(SQLITE_IOERR_READ),
    N(SQLITE_IOERR_SHORT_READ), N(SQLITE_IOERR_WRITE), N(SQLITE_IOERR_FSYNC),
    N(SQLITE_IOERR_DIR_FSYNC), N(SQLITE_IOERR_TRUNCATE), N(SQLITE_IOERR_FSTAT),
    N(SQLITE_IOERR_UNLOCK), N(SQLITE_IOERR_RDLOCK), N(SQLITE_IOERR_DELETE),
    N(SQLITE_IOERR_NOMEM), N(SQLITE_IOERR_ACCESS),
    N(SQLITE_IOERR_CHECKRESERVEDLOCK), N(SQLITE_IOERR_LOCK),
    N(SQLITE_IOERR_CLOSE), N(SQLITE_IOERR_DIR_CLOSE), N(SQLITE_IOERR_SHMOPEN),
    N(SQLITE_IOERR_SHMSIZE), N(SQLITE_IOERR_SHMLOCK), N(SQLITE_IOERR_SHMMAP),
    N(SQLITE_IOERR_SEEK), N(SQLITE_IOERR_DELETE_NOENT), N(SQLITE_IOERR_MMAP),
    N(SQLITE_IOERR_GETTEMPPATH), N(SQLITE_IOERR_CONVPATH), N(SQLITE_CORRUPT),
    N(SQLITE_CORRUPT_VTAB), N(SQLITE_NOTFOUND), N(SQLITE_FULL),
    N(SQLITE_CANTOPEN), N(SQLITE_CANTOPEN_NOTEMPDIR), N(SQLITE_CANTOPEN_ISDIR),
    N(SQLITE_CANTOPEN_FULLPATH), N(SQLITE_CANTOPEN_CONVPATH),
    N(SQLITE_CANTOPEN_SYMLINK), N(SQLITE_PROTOCOL), N(SQLITE_EMPTY),
    N(SQLITE_SCHEMA), N(SQLITE_TOOBIG), N(SQLITE_CONSTRAINT),
    N(SQLITE_CONSTRAINT_UNIQUE), N(SQLITE_CONSTRAINT_TRIGGER),
    N(SQLITE_CONSTRAINT_FOREIGNKEY), N(SQLITE_CONSTRAINT_CHECK),
    N(SQLITE_CONSTRAINT_PRIMARYKEY), N(SQLITE_CONSTRAINT_NOTNULL),
    N(SQLITE_CONSTRAINT_COMMITHOOK), N(SQLITE_CONSTRAINT_VTAB),
    N(SQLITE_CONSTRAINT_FUNCTION), N(SQLITE_CONSTRAINT_ROWID),
    N(SQLITE_MISMATCH), N(SQLITE_MISUSE), N(SQLITE_NOLFS), N(SQLITE_AUTH),
    N(SQLITE_FORMAT), N(SQLITE_RANGE), N(SQLITE_NOTADB), N(SQLITE_ROW),
    N(SQLITE_NOTICE), N(SQLITE_NOTICE_RECOVER_WAL),
    N(SQLITE_NOTICE_RECOVER_ROLLBACK), N(SQLITE_NOTICE_RBU), N(SQLITE_WARNING),
    N(SQLITE_WARNING_AUTOINDEX), N(SQLITE_DONE),
#undef N
  };
  static char zBuf[50];
  int i, j, x = rc;
  /* As main.c: the extended code, then the primary one. */
  for(j=0; j<2; j++, x &= 0xff){
    for(i=0; i<(int)(sizeof(aName)/sizeof(aName[0])); i++){
      if( aName[i].rc==x ) return aName[i].z;
    }
  }
  sqlite3_snprintf(sizeof(zBuf), zBuf, "SQLITE_UNKNOWN(%d)", rc);
  return zBuf;
}

const char *sqlite3ErrStr(int rc){ return sqlite3_errstr(rc); }

/* ------------------------------------------------------------ memory, strings */

void *sqlite3MallocZero(u64 n){
  void *p = sqlite3_malloc64(n);
  if( p ) memset(p, 0, (size_t)n);
  return p;
}
void *sqlite3Realloc(void *p, u64 n){ return sqlite3_realloc64(p, n); }
void sqlite3DbFree(sqlite3 *db, void *p){ (void)db; sqlite3_free(p); }
int sqlite3StrICmp(const char *a, const char *b){ return sqlite3_stricmp(a, b); }
int sqlite3Strlen30(const char *z){
  return z ? 0x3fffffff & (int)strlen(z) : 0;
}
void sqlite3BeginBenignMalloc(void){}
void sqlite3EndBenignMalloc(void){}

/* sqlite3Atoi64 for UTF-8 only: 0 if z is a valid 64-bit integer (spaces
** around it allowed), 1 if not, 2 for an out-of-range integer. */
int sqlite3Atoi64(const char *z, i64 *pOut, int length, u8 enc){
  char zBuf[100];
  char *zEnd;
  long long v;
  (void)enc;
  if( length<0 || length>=(int)sizeof(zBuf) ) return 1;
  memcpy(zBuf, z, length);
  zBuf[length] = 0;
  errno = 0;
  v = strtoll(zBuf, &zEnd, 10);
  while( *zEnd==' ' || *zEnd=='\t' || *zEnd=='\n' || *zEnd=='\r' ) zEnd++;
  if( zEnd==zBuf || *zEnd ) return 1;
  *pOut = v;
  return errno==ERANGE ? 2 : 0;
}

/* global.c */
const unsigned char sqlite3CtypeMap[256] = {
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x01, 0x00, 0x80, 0x00, 0x40, 0x00, 0x00, 0x80,
  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c, 0x0c,
  0x0c, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x00, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x02,
  0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
  0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02, 0x02,
  0x02, 0x02, 0x02, 0x80, 0x00, 0x00, 0x00, 0x40,
  0x80, 0x2a, 0x2a, 0x2a, 0x2a, 0x2a, 0x2a, 0x22,
  0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
  0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22, 0x22,
  0x22, 0x22, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40,
  0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40, 0x40
};

/* The configuration structure that test1.c and test_malloc.c read in a
** few commands (shared cache, page cache and lookaside settings). The
** library's own is not reachable; this one stays zeroed. */
struct Sqlite3Config sqlite3Config;

/* The pending byte: test_multiplex.c reads it. Kept in step with
** sqlite3_test_control_pending_byte (see xqtclPendingByte). */
int sqlite3PendingByte = 0x40000000;

/* ------------------------------------------------------------ counters
** A SQLITE_TEST build of SQLite counts these in the core. Neither library
** does, so they stay 0 and the tests that read them fail on both. */
int sqlite3_search_count = 0;
int sqlite3_found_count = 0;
int sqlite3_sort_count = 0;
int sqlite3_max_blobsize = 0;
int sqlite3_like_count = 0;
int sqlite3_interrupt_count = 0;
int sqlite3_open_file_count = 0;
int sqlite3_current_time = 0;
int sqlite3_hostid_num = 0;
int sqlite3_xferopt_count = 0;
int sqlite3_pager_readdb_count = 0;
int sqlite3_pager_writedb_count = 0;
int sqlite3_pager_writej_count = 0;
int sqlite3_opentemp_count = 0;
int sqlite3_sync_count = 0;
int sqlite3_fullsync_count = 0;
int sqlite3_io_error_hit = 0;
int sqlite3_io_error_hardhit = 0;
int sqlite3_io_error_pending = 0;
int sqlite3_io_error_persist = 0;
int sqlite3_io_error_benign = 0;
int sqlite3_diskfull_pending = 0;
int sqlite3_diskfull = 0;
int sqlite3_memdebug_vfs_oom_test = 1;

/* ------------------------------------------------------------ os.c */

void sqlite3OsClose(sqlite3_file *pId){
  if( pId->pMethods ){
    pId->pMethods->xClose(pId);
    pId->pMethods = 0;
  }
}
int sqlite3OsRead(sqlite3_file *id, void *pBuf, int amt, i64 offset){
  return id->pMethods->xRead(id, pBuf, amt, offset);
}
int sqlite3OsWrite(sqlite3_file *id, const void *pBuf, int amt, i64 offset){
  return id->pMethods->xWrite(id, pBuf, amt, offset);
}
int sqlite3OsTruncate(sqlite3_file *id, i64 size){
  return id->pMethods->xTruncate(id, size);
}
int sqlite3OsSync(sqlite3_file *id, int flags){
  return flags ? id->pMethods->xSync(id, flags) : SQLITE_OK;
}
int sqlite3OsFileSize(sqlite3_file *id, i64 *pSize){
  return id->pMethods->xFileSize(id, pSize);
}
int sqlite3OsLock(sqlite3_file *id, int lockType){
  return id->pMethods->xLock(id, lockType);
}
int sqlite3OsUnlock(sqlite3_file *id, int lockType){
  return id->pMethods->xUnlock(id, lockType);
}
int sqlite3OsCheckReservedLock(sqlite3_file *id, int *pResOut){
  return id->pMethods->xCheckReservedLock(id, pResOut);
}
int sqlite3OsFileControl(sqlite3_file *id, int op, void *pArg){
  if( id->pMethods==0 ) return SQLITE_NOTFOUND;
  return id->pMethods->xFileControl(id, op, pArg);
}
void sqlite3OsFileControlHint(sqlite3_file *id, int op, void *pArg){
  if( id->pMethods ) (void)id->pMethods->xFileControl(id, op, pArg);
}
int sqlite3OsSectorSize(sqlite3_file *id){
  int (*xSectorSize)(sqlite3_file*) = id->pMethods->xSectorSize;
  return (xSectorSize ? xSectorSize(id) : SQLITE_DEFAULT_SECTOR_SIZE);
}
int sqlite3OsDeviceCharacteristics(sqlite3_file *id){
  if( id->pMethods==0 ) return 0;
  return id->pMethods->xDeviceCharacteristics(id);
}
int sqlite3OsShmLock(sqlite3_file *id, int offset, int n, int flags){
  return id->pMethods->xShmLock(id, offset, n, flags);
}
void sqlite3OsShmBarrier(sqlite3_file *id){
  id->pMethods->xShmBarrier(id);
}
int sqlite3OsShmUnmap(sqlite3_file *id, int deleteFlag){
  return id->pMethods->xShmUnmap(id, deleteFlag);
}
int sqlite3OsShmMap(sqlite3_file *id, int iPage, int pgsz, int bExtend,
                    void volatile **pp){
  return id->pMethods->xShmMap(id, iPage, pgsz, bExtend, pp);
}
int sqlite3OsFetch(sqlite3_file *id, i64 iOff, int iAmt, void **pp){
  if( id->pMethods->iVersion<3 || id->pMethods->xFetch==0 ){
    *pp = 0;
    return SQLITE_OK;
  }
  return id->pMethods->xFetch(id, iOff, iAmt, pp);
}
int sqlite3OsUnfetch(sqlite3_file *id, i64 iOff, void *p){
  if( id->pMethods->iVersion<3 || id->pMethods->xUnfetch==0 ) return SQLITE_OK;
  return id->pMethods->xUnfetch(id, iOff, p);
}
int sqlite3OsOpen(sqlite3_vfs *pVfs, const char *zPath, sqlite3_file *pFile,
                  int flags, int *pFlagsOut){
  return pVfs->xOpen(pVfs, zPath, pFile, flags & 0x1087f7f, pFlagsOut);
}
int sqlite3OsDelete(sqlite3_vfs *pVfs, const char *zPath, int dirSync){
  return pVfs->xDelete!=0 ? pVfs->xDelete(pVfs, zPath, dirSync) : SQLITE_OK;
}
int sqlite3OsAccess(sqlite3_vfs *pVfs, const char *zPath, int flags,
                    int *pResOut){
  return pVfs->xAccess(pVfs, zPath, flags, pResOut);
}
int sqlite3OsFullPathname(sqlite3_vfs *pVfs, const char *zPath, int nPathOut,
                          char *zPathOut){
  zPathOut[0] = 0;
  return pVfs->xFullPathname(pVfs, zPath, nPathOut, zPathOut);
}
void *sqlite3OsDlOpen(sqlite3_vfs *pVfs, const char *zPath){
  return pVfs->xDlOpen(pVfs, zPath);
}
void sqlite3OsDlError(sqlite3_vfs *pVfs, int nByte, char *zBufOut){
  pVfs->xDlError(pVfs, nByte, zBufOut);
}
void (*sqlite3OsDlSym(sqlite3_vfs *pVfs, void *pHdle, const char *zSym))(void){
  return pVfs->xDlSym(pVfs, pHdle, zSym);
}
void sqlite3OsDlClose(sqlite3_vfs *pVfs, void *pHandle){
  pVfs->xDlClose(pVfs, pHandle);
}
int sqlite3OsRandomness(sqlite3_vfs *pVfs, int nByte, char *zBufOut){
  return pVfs->xRandomness(pVfs, nByte, zBufOut);
}
int sqlite3OsSleep(sqlite3_vfs *pVfs, int nMicro){
  return pVfs->xSleep(pVfs, nMicro);
}
int sqlite3OsGetLastError(sqlite3_vfs *pVfs){
  return pVfs->xGetLastError ? pVfs->xGetLastError(pVfs, 0, 0) : 0;
}
int sqlite3OsCurrentTimeInt64(sqlite3_vfs *pVfs, sqlite3_int64 *pTimeOut){
  int rc;
  if( pVfs->iVersion>=2 && pVfs->xCurrentTimeInt64 ){
    rc = pVfs->xCurrentTimeInt64(pVfs, pTimeOut);
  }else{
    double r;
    rc = pVfs->xCurrentTime(pVfs, &r);
    *pTimeOut = (sqlite3_int64)(r*86400000.0);
  }
  return rc;
}
int sqlite3OsOpenMalloc(sqlite3_vfs *pVfs, const char *zFile,
                        sqlite3_file **ppFile, int flags, int *pOutFlags){
  int rc;
  sqlite3_file *pFile = (sqlite3_file *)sqlite3MallocZero(pVfs->szOsFile);
  if( pFile==0 ) return SQLITE_NOMEM;
  rc = sqlite3OsOpen(pVfs, zFile, pFile, flags, pOutFlags);
  if( rc!=SQLITE_OK ){
    sqlite3_free(pFile);
    *ppFile = 0;
  }else{
    *ppFile = pFile;
  }
  return rc;
}
void sqlite3OsCloseFree(sqlite3_file *pFile){
  sqlite3OsClose(pFile);
  sqlite3_free(pFile);
}

/* ------------------------------------------------------------ bitvec
** A plain bitmap in place of bitvec.c, for test_journal.c. */
struct Bitvec { u32 iSize; unsigned char a[1]; };
Bitvec *sqlite3BitvecCreate(u32 iSize){
  Bitvec *p = sqlite3MallocZero(sizeof(Bitvec) + iSize/8 + 1);
  if( p ) p->iSize = iSize;
  return p;
}
int sqlite3BitvecTest(Bitvec *p, u32 i){
  if( p==0 || i==0 || i>p->iSize ) return 0;
  i--;
  return (p->a[i/8] >> (i%8)) & 1;
}
int sqlite3BitvecSet(Bitvec *p, u32 i){
  if( p==0 ) return SQLITE_OK;
  if( i==0 || i>p->iSize ) return SQLITE_OK;
  i--;
  p->a[i/8] |= (unsigned char)(1 << (i%8));
  return SQLITE_OK;
}
void sqlite3BitvecDestroy(Bitvec *p){ sqlite3_free(p); }

/* ------------------------------------------------------------ values
** test1.c converts strings between UTF-8 and UTF-16 with sqlite3ValueNew,
** sqlite3ValueSetStr and sqlite3ValueText, then reads them with
** sqlite3_value_text16be() and the like. The build rewrites those reads
** of `pVal` in test1.c to the xqtcl_value_* functions below, so the
** values never reach the library. */
typedef struct XqVal XqVal;
struct XqVal {
  char *z8;          /* UTF-8, nul-terminated */
  int n8;            /* bytes in z8 */
  unsigned char *z16[2];   /* UTF-16LE, UTF-16BE, two nul bytes after */
};

static int xqUtf16Len(const unsigned char *z){
  int n = 0;
  while( z[n] || z[n+1] ) n += 2;
  return n;
}

/* UTF-16 (big-endian if be) to UTF-8, appended at z8. */
static int xqFrom16(const unsigned char *z, int n, int be, char *z8){
  int i = 0, o = 0;
  while( i+1<n ){
    unsigned c = be ? (z[i]<<8)|z[i+1] : z[i]|(z[i+1]<<8);
    i += 2;
    if( c>=0xd800 && c<0xdc00 && i+1<n ){
      unsigned c2 = be ? (z[i]<<8)|z[i+1] : z[i]|(z[i+1]<<8);
      if( c2>=0xdc00 && c2<0xe000 ){
        c = 0x10000 + ((c-0xd800)<<10) + (c2-0xdc00);
        i += 2;
      }
    }
    if( c<0x80 ){
      z8[o++] = (char)c;
    }else if( c<0x800 ){
      z8[o++] = (char)(0xc0|(c>>6));
      z8[o++] = (char)(0x80|(c&0x3f));
    }else if( c<0x10000 ){
      z8[o++] = (char)(0xe0|(c>>12));
      z8[o++] = (char)(0x80|((c>>6)&0x3f));
      z8[o++] = (char)(0x80|(c&0x3f));
    }else{
      z8[o++] = (char)(0xf0|(c>>18));
      z8[o++] = (char)(0x80|((c>>12)&0x3f));
      z8[o++] = (char)(0x80|((c>>6)&0x3f));
      z8[o++] = (char)(0x80|(c&0x3f));
    }
  }
  z8[o] = 0;
  return o;
}

static unsigned char *xqTo16(const char *z8, int n8, int be){
  const unsigned char *z = (const unsigned char *)z8;
  unsigned char *out = sqlite3_malloc64((u64)n8*4 + 4);
  int i = 0, o = 0;
  if( out==0 ) return 0;
  while( i<n8 ){
    unsigned c = z[i++];
    if( c>=0xc0 ){
      int extra = c>=0xf0 ? 3 : c>=0xe0 ? 2 : 1;
      c &= (0x3f >> extra);
      while( extra-- && i<n8 && (z[i]&0xc0)==0x80 ) c = (c<<6)|(z[i++]&0x3f);
    }
    if( c>=0x10000 ){
      unsigned hi = 0xd800 + ((c-0x10000)>>10), lo = 0xdc00 + ((c-0x10000)&0x3ff);
      out[o++] = (unsigned char)(be ? hi>>8 : hi&0xff);
      out[o++] = (unsigned char)(be ? hi&0xff : hi>>8);
      c = lo;
    }
    out[o++] = (unsigned char)(be ? c>>8 : c&0xff);
    out[o++] = (unsigned char)(be ? c&0xff : c>>8);
  }
  out[o] = out[o+1] = 0;
  return out;
}

static void xqValClear(XqVal *p){
  sqlite3_free(p->z8);
  sqlite3_free(p->z16[0]);
  sqlite3_free(p->z16[1]);
  memset(p, 0, sizeof(*p));
}

sqlite3_value *sqlite3ValueNew(sqlite3 *db){
  (void)db;
  return (sqlite3_value*)sqlite3MallocZero(sizeof(XqVal));
}
void sqlite3ValueFree(sqlite3_value *v){
  if( v ){
    xqValClear((XqVal*)v);
    sqlite3_free(v);
  }
}
void sqlite3ValueSetStr(sqlite3_value *v, int n, const void *z, u8 enc,
                        void (*xDel)(void*)){
  XqVal *p = (XqVal*)v;
  if( p==0 ) return;
  xqValClear(p);
  if( z==0 ) return;
  if( enc==SQLITE_UTF8 ){
    if( n<0 ) n = (int)strlen((const char*)z);
    p->z8 = sqlite3_malloc64((u64)n+1);
    if( p->z8 ){
      memcpy(p->z8, z, n);
      p->z8[n] = 0;
      p->n8 = n;
    }
  }else{
    int be = enc==SQLITE_UTF16BE;
    if( enc==SQLITE_UTF16 ) be = SQLITE_UTF16NATIVE==SQLITE_UTF16BE;
    if( n<0 ) n = xqUtf16Len((const unsigned char*)z);
    p->z8 = sqlite3_malloc64((u64)n*2 + 1);
    if( p->z8 ) p->n8 = xqFrom16((const unsigned char*)z, n, be, p->z8);
  }
  if( xDel && xDel!=SQLITE_STATIC && xDel!=SQLITE_TRANSIENT ) xDel((void*)z);
}
const void *sqlite3ValueText(sqlite3_value *v, u8 enc){
  XqVal *p = (XqVal*)v;
  int be;
  if( p==0 || p->z8==0 ) return 0;
  if( enc==SQLITE_UTF8 ) return p->z8;
  be = enc==SQLITE_UTF16BE || (enc==SQLITE_UTF16 && SQLITE_UTF16NATIVE==SQLITE_UTF16BE);
  if( p->z16[be]==0 ) p->z16[be] = xqTo16(p->z8, p->n8, be);
  return p->z16[be];
}
int sqlite3ValueBytes(sqlite3_value *v, u8 enc){
  XqVal *p = (XqVal*)v;
  const void *z = sqlite3ValueText(v, enc);
  if( z==0 ) return 0;
  return enc==SQLITE_UTF8 ? p->n8 : xqUtf16Len((const unsigned char*)z);
}
int xqtcl_value_bytes(sqlite3_value *v){ return sqlite3ValueBytes(v, SQLITE_UTF8); }
const unsigned char *xqtcl_value_text(sqlite3_value *v){
  return (const unsigned char*)sqlite3ValueText(v, SQLITE_UTF8);
}
const void *xqtcl_value_text16be(sqlite3_value *v){
  return sqlite3ValueText(v, SQLITE_UTF16BE);
}
const void *xqtcl_value_text16le(sqlite3_value *v){
  return sqlite3ValueText(v, SQLITE_UTF16LE);
}

/* ------------------------------------------------------------ varints
** test_func.c's test_decode and test_extract decode records with these
** and then hand SQLite's Mem structures to sqlite3_result_value(), which
** only SQLite's own library could read; xqtclTestInit replaces both SQL
** functions, so only sqlite3GetVarint is ever used. */
u8 sqlite3GetVarint(const unsigned char *p, u64 *v){
  u64 x = 0;
  int i;
  for(i=0; i<8; i++){
    x = (x<<7) | (p[i]&0x7f);
    if( (p[i]&0x80)==0 ){ *v = x; return (u8)(i+1); }
  }
  *v = (x<<8) | p[8];
  return 9;
}
u32 sqlite3VdbeSerialTypeLen(u32 t){
  static const u8 a[] = { 0, 1, 2, 3, 4, 6, 8, 8, 0, 0, 0, 0 };
  return t>=12 ? (t-12)/2 : a[t];
}

/* Internal functions the harness cannot provide. Each is reached only
** through a command or SQL function that xqtclTestInit replaces, so a
** call is a bug in the harness: say which and stop. */
static void xqUnreachable(const char *zName){
  fprintf(stderr, "xqlite tcl harness: %s (SQLite internal) called\n", zName);
  abort();
}
void sqlite3VdbeSerialGet(const unsigned char *a, u32 t, Mem *p){
  (void)a; (void)t; (void)p;
  xqUnreachable("sqlite3VdbeSerialGet");
}
Pager *sqlite3BtreePager(Btree *p){ (void)p; xqUnreachable("sqlite3BtreePager"); return 0; }
int *sqlite3PagerStats(Pager *p){ (void)p; xqUnreachable("sqlite3PagerStats"); return 0; }
void sqlite3PcacheStats(int *a, int *b, int *c, int *d){
  *a = *b = *c = *d = 0;
}
int sqlite3DbstatRegister(sqlite3 *db){ (void)db; return SQLITE_OK; }
int SQLITE_TCLAPI sqlite3BtreeSharedCacheReport(void *cd, Tcl_Interp *interp,
    int objc, Tcl_Obj *CONST objv[]){
  (void)cd; (void)objc; (void)objv;
  Tcl_SetResult(interp, "xqlite tcl harness: sqlite3_shared_cache_report "
      "needs SQLite internals", TCL_STATIC);
  return TCL_ERROR;
}

/* ------------------------------------------------------------ left-out helpers */
#define XQ_NO_INIT(NAME) int NAME(Tcl_Interp *interp){ (void)interp; return TCL_OK; }
XQ_NO_INIT(Sqlitetest2_Init)          /* pager internals */
XQ_NO_INIT(Sqlitetest3_Init)          /* btree internals */
XQ_NO_INIT(Sqlitetest5_Init)          /* sqlite3_value internals */
XQ_NO_INIT(Sqlitetestrtree_Init)      /* no rtree in either build */
XQ_NO_INIT(Sqlitetestrtreedoc_Init)
XQ_NO_INIT(Fts5tcl_Init)              /* no fts5 */
XQ_NO_INIT(SqliteRbu_Init)            /* no rbu */
XQ_NO_INIT(TestRecover_Init)          /* recover needs sqlite_dbpage */
XQ_NO_INIT(Sqlitetestintck_Init)

/* ------------------------------------------------------------ commands */

static int xqtclUnsupported(void *cd, Tcl_Interp *interp, int objc,
                            Tcl_Obj *CONST objv[]){
  (void)cd; (void)objc;
  Tcl_AppendResult(interp, "xqlite tcl harness: ",
      Tcl_GetString(objv[0]), " needs SQLite internals", (char*)0);
  return TCL_ERROR;
}

/* sqlite3_test_control_pending_byte NEW: as test1.c, and keeps
** sqlite3PendingByte (read by test_multiplex.c) in step. */
static int xqtclPendingByte(void *cd, Tcl_Interp *interp, int objc,
                            Tcl_Obj *CONST objv[]){
  int pbyte, rc;
  (void)cd;
  if( objc!=2 ){
    Tcl_WrongNumArgs(interp, 1, objv, "PENDING-BYTE");
    return TCL_ERROR;
  }
  if( Tcl_GetIntFromObj(interp, objv[1], &pbyte) ) return TCL_ERROR;
  rc = sqlite3_test_control(SQLITE_TESTCTRL_PENDING_BYTE, pbyte);
  sqlite3PendingByte = pbyte;
  Tcl_SetObjResult(interp, Tcl_NewIntObj(rc));
  return TCL_OK;
}

/* fake_big_file N FILENAME: test2.c's, which is left out with the rest of
** that file (a sparse file with 14 bytes at N MiB). */
static int xqtclFakeBigFile(void *cd, Tcl_Interp *interp, int objc,
                            Tcl_Obj *CONST objv[]){
  sqlite3_vfs *pVfs = sqlite3_vfs_find(0);
  sqlite3_file *fd = 0;
  const char *zName;
  char *zFile;
  int n, nFile, rc;
  (void)cd;
  if( objc!=3 ){
    Tcl_WrongNumArgs(interp, 1, objv, "N-MEGABYTES FILE");
    return TCL_ERROR;
  }
  if( Tcl_GetIntFromObj(interp, objv[1], &n) ) return TCL_ERROR;
  zName = Tcl_GetString(objv[2]);
  nFile = (int)strlen(zName);
  zFile = sqlite3_malloc(nFile+2);
  if( zFile==0 ) return TCL_ERROR;
  memcpy(zFile, zName, nFile+1);
  zFile[nFile+1] = 0;
  rc = sqlite3OsOpenMalloc(pVfs, zFile, &fd,
      (SQLITE_OPEN_CREATE|SQLITE_OPEN_READWRITE|SQLITE_OPEN_MAIN_DB), 0);
  if( rc ){
    Tcl_AppendResult(interp, "open failed: ", sqlite3ErrName(rc), (char*)0);
    sqlite3_free(zFile);
    return TCL_ERROR;
  }
  rc = sqlite3OsWrite(fd, "Hello, World!", 14, (i64)n*1024*1024);
  sqlite3OsCloseFree(fd);
  sqlite3_free(zFile);
  if( rc ){
    Tcl_AppendResult(interp, "write failed: ", sqlite3ErrName(rc), (char*)0);
    return TCL_ERROR;
  }
  return TCL_OK;
}

/* SQLITE_FCNTL_FILE_POINTER. libxqlite3 answers it only for files of a C
** VFS; on its built-in "unix" VFS the pointer stays NULL (docs/c-api.md),
** and the helpers below then dereference NULL. The fixture would crash
** at the first such call, which most journal, WAL and pager test files
** make at the top (atomic_batch_write): these wrappers turn it into a
** result or a Tcl error so the rest of the file runs, and the
** incompatibility shows as the failures of the tests that need it. */
static sqlite3_file *xqtclFilePointer(sqlite3 *db, const char *zDb){
  sqlite3_file *pFd = 0;
  if( sqlite3_file_control(db, zDb, SQLITE_FCNTL_FILE_POINTER, (void*)&pFd) ){
    return 0;
  }
  return pFd && pFd->pMethods ? pFd : 0;
}

/* atomic_batch_write PATH: as test1.c; 0 without a file pointer. */
static int xqtclAtomicBatchWrite(void *cd, Tcl_Interp *interp, int objc,
                                 Tcl_Obj *CONST objv[]){
  sqlite3 *db = 0;
  sqlite3_file *pFd;
  int bRes = 0;
  (void)cd;
  if( objc!=2 ){
    Tcl_WrongNumArgs(interp, 1, objv, "PATH");
    return TCL_ERROR;
  }
  if( sqlite3_open(Tcl_GetString(objv[1]), &db)!=SQLITE_OK ){
    Tcl_AppendResult(interp, sqlite3_errmsg(db), (char*)0);
    sqlite3_close(db);
    return TCL_ERROR;
  }
  pFd = xqtclFilePointer(db, "main");
  if( pFd && (pFd->pMethods->xDeviceCharacteristics(pFd)
              & SQLITE_IOCAP_BATCH_ATOMIC) ){
    bRes = 1;
  }
  Tcl_SetObjResult(interp, Tcl_NewIntObj(bRes));
  sqlite3_close(db);
  return TCL_OK;
}

/* vfs_shmlock DB DBNAME ..., vfs_set_readmark DB DBNAME ...,
** test_write_db DB ...: the original (saved in cd) if the database has a
** file pointer, else a Tcl error. */
static int xqtclNeedFilePointer(void *cd, Tcl_Interp *interp, int objc,
                                Tcl_Obj *CONST objv[]){
  extern int getDbPointer(Tcl_Interp*, const char*, sqlite3**);
  Tcl_CmdInfo *pOrig = (Tcl_CmdInfo*)cd;
  sqlite3 *db = 0;
  const char *zDb = "main";
  if( objc>=2 ){
    if( getDbPointer(interp, Tcl_GetString(objv[1]), &db) ) return TCL_ERROR;
    if( objc>=3 && strcmp(Tcl_GetString(objv[0]), "test_write_db")!=0 ){
      zDb = Tcl_GetString(objv[2]);
    }
    if( db && xqtclFilePointer(db, zDb)==0 ){
      Tcl_AppendResult(interp, Tcl_GetString(objv[0]),
          ": SQLITE_FCNTL_FILE_POINTER gave no file", (char*)0);
      return TCL_ERROR;
    }
  }
  return pOrig->objProc(pOrig->objClientData, interp, objc, objv);
}

static void xqtclNoInternals(sqlite3_context *ctx, int n, sqlite3_value **a){
  (void)n; (void)a;
  sqlite3_result_error(ctx, "xqlite tcl harness: this test function needs "
      "SQLite internals", -1);
}
/* After registerTestFunctions (test_func.c, an auto-extension too). */
static int xqtclReplaceFunctions(sqlite3 *db, char **pzErr, const void *p){
  (void)pzErr; (void)p;
  sqlite3_create_function(db, "test_decode", 4, SQLITE_UTF8, 0,
                          xqtclNoInternals, 0, 0);
  sqlite3_create_function(db, "test_extract", 2, SQLITE_UTF8, 0,
                          xqtclNoInternals, 0, 0);
  return SQLITE_OK;
}

static int xqtclReplaceFunctionsCmd(void *cd, Tcl_Interp *interp, int objc,
                                    Tcl_Obj *CONST objv[]){
  (void)cd; (void)interp; (void)objc; (void)objv;
  sqlite3_auto_extension((void(*)(void))xqtclReplaceFunctions);
  return TCL_OK;
}

/*
** TCLSH_INIT_PROC of the harness: everything sqlite3TestInit() of
** test_tclsh.c sets up, then the commands below in place of the ones
** that read SQLite's structures.
*/
const char *xqtclTestInit(Tcl_Interp *interp){
  extern const char *sqlite3TestInit(Tcl_Interp*);
  static const char *aOverride[] = {
    "uses_stmt_journal",          /* reads Vdbe.usesStmtJournal */
    "sqlite3_pager_refcounts",    /* reads Btree/Pager */
  };
  const char *zRet = sqlite3TestInit(interp);
  int i;
  for(i=0; i<(int)(sizeof(aOverride)/sizeof(aOverride[0])); i++){
    Tcl_CreateObjCommand(interp, aOverride[i], xqtclUnsupported, 0, 0);
  }
  Tcl_CreateObjCommand(interp, "atomic_batch_write", xqtclAtomicBatchWrite,
                       0, 0);
  {
    static const char *azNeed[] = {
      "vfs_shmlock", "vfs_set_readmark", "test_write_db"
    };
    static Tcl_CmdInfo aInfo[3];
    for(i=0; i<3; i++){
      if( Tcl_GetCommandInfo(interp, azNeed[i], &aInfo[i]) && aInfo[i].isNativeObjectProc ){
        Tcl_CreateObjCommand(interp, azNeed[i], xqtclNeedFilePointer,
                             &aInfo[i], 0);
      }
    }
  }
  /* From test2.c, which is left out. */
  Tcl_CreateObjCommand(interp, "sqlite3_test_control_pending_byte",
                       xqtclPendingByte, 0, 0);
  Tcl_CreateObjCommand(interp, "fake_big_file", xqtclFakeBigFile, 0, 0);
  Tcl_LinkVar(interp, "sqlite_pending_byte", (char*)&sqlite3PendingByte,
              TCL_LINK_INT | TCL_LINK_READ_ONLY);
  Tcl_LinkVar(interp, "sqlite_io_error_pending",
              (char*)&sqlite3_io_error_pending, TCL_LINK_INT);
  Tcl_LinkVar(interp, "sqlite_io_error_persist",
              (char*)&sqlite3_io_error_persist, TCL_LINK_INT);
  Tcl_LinkVar(interp, "sqlite_io_error_hit",
              (char*)&sqlite3_io_error_hit, TCL_LINK_INT);
  Tcl_LinkVar(interp, "sqlite_io_error_hardhit",
              (char*)&sqlite3_io_error_hardhit, TCL_LINK_INT);
  Tcl_LinkVar(interp, "sqlite_diskfull_pending",
              (char*)&sqlite3_diskfull_pending, TCL_LINK_INT);
  Tcl_LinkVar(interp, "sqlite_diskfull", (char*)&sqlite3_diskfull,
              TCL_LINK_INT);
  /* autoinstall_test_functions (test_func.c) installs the test SQL
  ** functions as an auto-extension; ours runs after it. */
  {
    Tcl_CmdInfo info;
    if( Tcl_GetCommandInfo(interp, "autoinstall_test_functions", &info) ){
      Tcl_CreateObjCommand(interp, "xqtcl_replace_functions",
                           xqtclReplaceFunctionsCmd, 0, 0);
      Tcl_Eval(interp, "rename autoinstall_test_functions "
                       "xqtcl_autoinstall_test_functions;"
                       "proc autoinstall_test_functions {} {"
                       "  xqtcl_autoinstall_test_functions;"
                       "  xqtcl_replace_functions }");
    }
  }
  /* The OOM-injecting malloc wrapper of test_malloc.c, which tester.tcl
  ** installs for every file, only with XQTCL_FAULTSIM=1. It wraps the
  ** methods of SQLITE_CONFIG_GETMALLOC; libxqlite3's call sqlite3_malloc()
  ** and so the wrapper again, without end (a stack overflow on the first
  ** allocation). Off, the fault-injection tests fail on both builds. */
  {
    const char *z = getenv("XQTCL_FAULTSIM");
    if( z==0 || strcmp(z, "1")!=0 ){
      Tcl_Eval(interp, "rename install_malloc_faultsim "
                       "xqtcl_install_malloc_faultsim;"
                       "proc install_malloc_faultsim {args} {}");
    }
  }
  Tcl_SetVar2(interp, "xqtcl_engine", 0, XQTCL_ENGINE, TCL_GLOBAL_ONLY);
  return zRet;
}

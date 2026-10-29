/* A library to preload into sqlite3 (DYLD_INSERT_LIBRARIES on macOS,
** LD_PRELOAD elsewhere) that crashes it: _exit(0) at the CRASH_AT-th
** change (a write, a truncation or an unlink) of a file whose name ends
** with CRASH_SUFFIX, before the change is made. Used by
** tools/interop-attach.sh and tools/gen-superjournal-fixtures.sh; `zig
** build tools` builds it for xqt (zig-out/lib/libcrashshim.*, see
** tools/xqt/lib/crash.zig).
**
**   cc -dynamiclib -o crashshim.dylib crashshim.c         (macOS)
**   cc -shared -fPIC -o crashshim.so crashshim.c -ldl     (Linux)
*/
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>
static int matches(const char *path){
  const char *suffix = getenv("CRASH_SUFFIX");
  size_t n, m;
  if( suffix==0 ) return 0;
  n = strlen(path); m = strlen(suffix);
  return n>=m && strcmp(path+n-m, suffix)==0;
}
static int fd_matches(int fd){
  char path[4096];
#ifdef __APPLE__
  if( fcntl(fd, F_GETPATH, path)==-1 ) return 0;
#else
  { char link[64]; ssize_t got;
    snprintf(link, sizeof(link), "/proc/self/fd/%d", fd);
    got = readlink(link, path, sizeof(path)-1);
    if( got<0 ) return 0;
    path[got] = 0; }
#endif
  return matches(path);
}
static void tick(int hit){
  static int count = 0;
  const char *at = getenv("CRASH_AT");
  if( at && hit && ++count==atoi(at) ) _exit(0);
}
#ifdef __APPLE__
static ssize_t my_pwrite(int fd, const void *b, size_t n, off_t o){ tick(fd_matches(fd)); return pwrite(fd, b, n, o); }
static ssize_t my_write(int fd, const void *b, size_t n){ tick(fd_matches(fd)); return write(fd, b, n); }
static int my_ftruncate(int fd, off_t n){ tick(fd_matches(fd)); return ftruncate(fd, n); }
static int my_unlink(const char *path){ tick(matches(path)); return unlink(path); }
__attribute__((used)) static struct { const void *a, *b; } interposers[]
  __attribute__((section("__DATA,__interpose"))) = {
  { (const void*)my_pwrite, (const void*)pwrite },
  { (const void*)my_write, (const void*)write },
  { (const void*)my_ftruncate, (const void*)ftruncate },
  { (const void*)my_unlink, (const void*)unlink },
};
#else
#define NEXT(name, type) static type real; if( !real ) real = (type)dlsym(RTLD_NEXT, name)
ssize_t pwrite(int fd, const void *b, size_t n, off_t o){
  NEXT("pwrite", ssize_t(*)(int, const void*, size_t, off_t));
  tick(fd_matches(fd)); return real(fd, b, n, o);
}
ssize_t pwrite64(int fd, const void *b, size_t n, off_t o){
  NEXT("pwrite64", ssize_t(*)(int, const void*, size_t, off_t));
  tick(fd_matches(fd)); return real(fd, b, n, o);
}
ssize_t write(int fd, const void *b, size_t n){
  NEXT("write", ssize_t(*)(int, const void*, size_t));
  tick(fd_matches(fd)); return real(fd, b, n);
}
int ftruncate(int fd, off_t n){
  NEXT("ftruncate", int(*)(int, off_t));
  tick(fd_matches(fd)); return real(fd, n);
}
int ftruncate64(int fd, off_t n){
  NEXT("ftruncate64", int(*)(int, off_t));
  tick(fd_matches(fd)); return real(fd, n);
}
int unlink(const char *path){
  NEXT("unlink", int(*)(const char*));
  tick(matches(path)); return real(path);
}
#endif

/* Prints every SQL keyword with its parser token code, one per line, from
** the keywordhash.h made by mkkeywordhash. Used by xqt gen parser. */
#include <stdio.h>
#include <assert.h>
#include "parse.h"
typedef long long i64;
typedef unsigned char u8;
static unsigned char sqlite3UpperToLower[256];
#define charMap(X) sqlite3UpperToLower[(unsigned char)X]
#define SQLITE_ASCII 1
#define SQLITE_OK 0
#define SQLITE_ERROR 1
#define testcase(X)
#include "keywordhash.h"
int main(void){
  int i;
  for(i=0; i<256; i++){
    sqlite3UpperToLower[i] = (i>='A' && i<='Z') ? i+32 : i;
  }
  for(i=0; i<SQLITE_N_KEYWORD; i++){
    const char *z; int n, code = TK_ID;
    sqlite3_keyword_name(i, &z, &n);
    keywordCode(z, n, &code);
    printf("%.*s %d\n", n, z, code);
  }
  return 0;
}

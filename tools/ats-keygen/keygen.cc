// Prints ATS master cache keys for URLs read from stdin. Built by build.sh.
// Output, one line per URL:
//   default  ignore_query  generation=3  hash_get92  <TAB> url
#include "proxy/hdrs/HTTP.h"
#include "proxy/hdrs/URL.h"
#include "tscore/CryptoHash.h"
#include <cstdio>
#include <iostream>
#include <string>

extern int cmd_disable_pfreelist;

static void
hex(const CryptoHash &h)
{
  for (int i = 0; i < CRYPTO_HASH_SIZE; ++i) {
    printf("%02x", h.u8[i]);
  }
}

int
main()
{
  cmd_disable_pfreelist = true;
  http_init();
  std::string line;
  while (std::getline(std::cin, line)) {
    URL      url;
    HdrHeap *heap = new_HdrHeap();
    url.create(heap);
    const char *start = line.data();
    if (url.parse(&start, line.data() + line.size()) != ParseResult::DONE) {
      printf("PARSE_ERROR\t%s\n", line.c_str());
      heap->destroy();
      continue;
    }
    CryptoHash a, b, c, d;
    url.hash_get(&a);
    url.hash_get(&b, true);
    url.hash_get(&c, false, 3);
    url.hash_get92(&d);
    hex(a); printf(" "); hex(b); printf(" "); hex(c); printf(" "); hex(d);
    printf("\t%s\n", line.c_str());
    heap->destroy();
  }
}

// Decodes the alternate vectors of cache fragments with ATS master's own
// HTTPInfo::unmarshal, as golden output for cyclone. Built by build.sh.
//
// Input, one per line on stdin:  SPAN_PATH OFFSET
// (the byte offset of a Doc, as `cyc-doc dir --entries` prints it). Assumes
// the non-FIPS Doc layout: hlen at 48, header at 72.
//
// Output, per alternate (strings printed with C escapes for non-printables):
//   doc SPAN_FILE_NAME OFFSET alt I
//   object_key HEX  object_size N  frags N [OFFSETS...]
//   times REQUEST_SENT RESPONSE_RECEIVED
//   request METHOD SCHEME HOST PORT PATH PARAMS QUERY FRAGMENT VERSION
//   > NAME: VALUE
//   response STATUS REASON VERSION
//   < NAME: VALUE
#include "proxy/hdrs/HTTP.h"
#include "proxy/hdrs/URL.h"
#include "tscore/CryptoHash.h"
#include <cstdio>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <string>
#include <string_view>
#include <unistd.h>
#include <vector>

extern int cmd_disable_pfreelist;

static void
str(std::string_view s)
{
  putchar('"');
  for (unsigned char c : s) {
    if (c == '"' || c == '\\') {
      printf("\\%c", c);
    } else if (c < 0x20 || c >= 0x7f) {
      printf("\\x%02x", c);
    } else {
      putchar(c);
    }
  }
  putchar('"');
}

static std::string_view
sv(const char *p, int len)
{
  return p ? std::string_view(p, len) : std::string_view();
}

static void
fields(HTTPHdr &h, char dir)
{
  for (auto &f : h) {
    printf("%c ", dir);
    str(f.name_get());
    putchar(' ');
    str(f.value_get());
    putchar('\n');
  }
}

int
main()
{
  cmd_disable_pfreelist = true;
  http_init();
  std::string path;
  long long   offset;
  while (std::cin >> path >> offset) {
    int fd = open(path.c_str(), O_RDONLY);
    if (fd < 0) {
      perror(path.c_str());
      return 1;
    }
    unsigned char doc[72];
    if (pread(fd, doc, sizeof(doc), offset) != sizeof(doc)) {
      perror("pread");
      return 1;
    }
    uint32_t hlen;
    memcpy(&hlen, doc + 48, 4);
    // Header buffers must be 8-byte aligned; vector<uint64_t> is.
    std::vector<uint64_t> store((hlen + 7) / 8 + 1);
    char                 *buf = reinterpret_cast<char *>(store.data());
    if (pread(fd, buf, hlen, offset + 72) != (ssize_t)hlen) {
      perror("pread");
      return 1;
    }
    close(fd);
    const char *name = strrchr(path.c_str(), '/') ? strrchr(path.c_str(), '/') + 1 : path.c_str();

    char *p   = buf;
    int   len = hlen;
    for (int i = 0; len > 0; ++i) {
      int r = HTTPInfo::unmarshal(p, len, nullptr);
      if (r < 0) {
        printf("doc %s %lld alt %d unmarshal failed\n", name, offset, i);
        break;
      }
      HTTPInfo info;
      info.m_alt = reinterpret_cast<HTTPCacheAlt *>(p);
      printf("doc %s %lld alt %d\n", name, offset, i);
      char hex[CRYPTO_HEX_SIZE];
      printf("object_key %s  object_size %lld  frags %d", info.object_key_get().toHexStr(hex),
             (long long)info.object_size_get(), info.get_frag_offset_count());
      for (int j = 0; j < info.get_frag_offset_count(); ++j) {
        printf(" %llu", (unsigned long long)info.get_frag_table()[j]);
      }
      printf("\ntimes %lld %lld\n", (long long)info.request_sent_time_get(), (long long)info.response_received_time_get());

      HTTPHdr     *req = info.request_get();
      HTTPHdrImpl *rq  = req->m_http;
      URLImpl     *u   = rq->u.req.m_url_impl;
      printf("request ");
      str(sv(rq->u.req.m_ptr_method, rq->u.req.m_len_method));
      for (auto s : {sv(u->m_ptr_scheme, u->m_len_scheme), sv(u->m_ptr_host, u->m_len_host), sv(u->m_ptr_port, u->m_len_port),
                     sv(u->m_ptr_path, u->m_len_path), sv(u->m_ptr_params, u->m_len_params), sv(u->m_ptr_query, u->m_len_query),
                     sv(u->m_ptr_fragment, u->m_len_fragment)}) {
        putchar(' ');
        str(s);
      }
      printf(" %d.%d\n", rq->m_version.get_major(), rq->m_version.get_minor());
      fields(*req, '>');

      HTTPHdr     *resp = info.response_get();
      HTTPHdrImpl *rs   = resp->m_http;
      printf("response %d ", rs->u.resp.m_status);
      str(sv(rs->u.resp.m_ptr_reason, rs->u.resp.m_len_reason));
      printf(" %d.%d\n", rs->m_version.get_major(), rs->m_version.get_minor());
      fields(*resp, '<');

      p   += r;
      len -= r;
    }
  }
}

// Runs ATS master's own alternate-matching code (HttpTransactCache.cc) on
// test cases, as golden output for cyclone's src/select.zig. Built by
// build.sh, which feeds it the cases from gen-select-cases.py; the result is
// src/testdata/select_golden.txt.
//
// Input on stdin (values escape tab, newline and backslash as \t \n \\):
//   case N
//   cfg ACCEPT CHARSET ENCODING LANGUAGE UA   (ignore_*_mismatch 0..2;
//                                              UA 1: global_user_agent_header set)
//   c NAME<TAB>VALUE      a field of the client request
//   r NAME<TAB>VALUE      a field of the stored request
//   s NAME<TAB>VALUE      a field of the stored response
//   end
//   date TEXT             a Date value to parse
//
// Output: every input line, and after each `end`
//   = Q VAR ACCEPT CHARSET ENCODING LANGUAGE GZIP BR ZSTD
// Q is calculate_quality_of_match, VAR CalcVariability (0 none, 1 some,
// 2 all), ACCEPT..LANGUAGE the four calculate_quality_of_*_match functions
// on the first fields (ACCEPT is "-" without both Accept and Content-Type),
// and GZIP..ZSTD match_content_encoding on the client's Accept-Encoding.
// After each `date`:  = SECONDS (mime_parse_date).
#include "api/HttpAPIHooks.h"
#include "iocore/cache/HttpConfigAccessor.h"
#include "iocore/cache/HttpTransactCache.h"
#include "proxy/hdrs/HTTP.h"
#include "proxy/hdrs/MIME.h"
#include <cstdio>
#include <iostream>
#include <string>
#include <string_view>

extern int cmd_disable_pfreelist;

// No plugins: the select-alternate hook list is empty. These stand in for
// src/api, which would pull in the event system.
APIHook *
APIHooks::head() const
{
  return nullptr;
}

int
APIHook::invoke(int, void *) const
{
  return 0;
}

namespace
{
struct Config : HttpConfigAccessor {
  int8_t ign[4] = {2, 2, 2, 2};
  bool   ua     = false;

  int8_t
  get_ignore_accept_mismatch() const override
  {
    return ign[0];
  }
  int8_t
  get_ignore_accept_charset_mismatch() const override
  {
    return ign[1];
  }
  int8_t
  get_ignore_accept_encoding_mismatch() const override
  {
    return ign[2];
  }
  int8_t
  get_ignore_accept_language_mismatch() const override
  {
    return ign[3];
  }
  const char *
  get_global_user_agent_header() const override
  {
    return ua ? "User-Agent: cyclone" : nullptr;
  }
};

std::string
unescape(std::string_view s)
{
  std::string out;
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '\\' && i + 1 < s.size()) {
      char c = s[++i];
      out += c == 't' ? '\t' : c == 'n' ? '\n' : c;
    } else {
      out += s[i];
    }
  }
  return out;
}

void
add(HTTPHdr &h, std::string_view line)
{
  auto        tab   = line.find('\t');
  std::string name  = unescape(line.substr(0, tab));
  std::string value = tab == std::string_view::npos ? "" : unescape(line.substr(tab + 1));
  MIMEField  *f     = h.field_create(name);
  h.field_attach(f);
  h.field_value_set(f, value);
}

MIMEField *
find(HTTPHdr &h, std::string_view name)
{
  return h.field_find(name);
}

void
q(float v)
{
  printf(" %.9g", v);
}
} // namespace

int
main()
{
  cmd_disable_pfreelist = true;
  http_init();
  http_global_hooks = new HttpAPIHooks;

  Config      cfg;
  HTTPHdr     client, req, resp;
  std::string line;
  while (std::getline(std::cin, line)) {
    puts(line.c_str());
    std::string_view l = line;
    if (l.starts_with("case ")) {
      cfg = Config{};
      client.create(HTTPType::REQUEST);
      req.create(HTTPType::REQUEST);
      resp.create(HTTPType::RESPONSE);
      client.method_set("GET"sv);
      req.method_set("GET"sv);
      resp.status_set(HTTPStatus::OK);
    } else if (l.starts_with("cfg ")) {
      int a, c, e, g, u;
      sscanf(line.c_str() + 4, "%d %d %d %d %d", &a, &c, &e, &g, &u);
      cfg.ign[0] = a, cfg.ign[1] = c, cfg.ign[2] = e, cfg.ign[3] = g, cfg.ua = u != 0;
    } else if (l.starts_with("c ")) {
      add(client, l.substr(2));
    } else if (l.starts_with("r ")) {
      add(req, l.substr(2));
    } else if (l.starts_with("s ")) {
      add(resp, l.substr(2));
    } else if (l == "end") {
      printf("=");
      q(HttpTransactCache::calculate_quality_of_match(&cfg, &client, &req, &resp));
      printf(" %d", static_cast<int>(HttpTransactCache::CalcVariability(&cfg, &client, &req, &resp)));
      MIMEField *accept = find(client, static_cast<std::string_view>(MIME_FIELD_ACCEPT)), *ctype = find(resp, static_cast<std::string_view>(MIME_FIELD_CONTENT_TYPE));
      if (accept && ctype) {
        q(HttpTransactCache::calculate_quality_of_accept_match(accept, ctype));
      } else {
        printf(" -");
      }
      q(HttpTransactCache::calculate_quality_of_accept_charset_match(find(client, static_cast<std::string_view>(MIME_FIELD_ACCEPT_CHARSET)), ctype,
                                                                     find(req, static_cast<std::string_view>(MIME_FIELD_ACCEPT_CHARSET))));
      q(HttpTransactCache::calculate_quality_of_accept_encoding_match(
        find(client, static_cast<std::string_view>(MIME_FIELD_ACCEPT_ENCODING)), find(resp, static_cast<std::string_view>(MIME_FIELD_CONTENT_ENCODING)), find(req, static_cast<std::string_view>(MIME_FIELD_ACCEPT_ENCODING))));
      q(HttpTransactCache::calculate_quality_of_accept_language_match(
        find(client, static_cast<std::string_view>(MIME_FIELD_ACCEPT_LANGUAGE)), find(resp, static_cast<std::string_view>(MIME_FIELD_CONTENT_LANGUAGE)), find(req, static_cast<std::string_view>(MIME_FIELD_ACCEPT_LANGUAGE))));
      MIMEField *ae = find(client, static_cast<std::string_view>(MIME_FIELD_ACCEPT_ENCODING));
      for (const char *enc : {"gzip", "br", "zstd"}) {
        printf(" %d", HttpTransactCache::match_content_encoding(ae, enc) ? 1 : 0);
      }
      putchar('\n');
      client.destroy();
      req.destroy();
      resp.destroy();
    } else if (l.starts_with("date ")) {
      std::string text = unescape(l.substr(5));
      printf("= %lld\n", static_cast<long long>(mime_parse_date(text.data(), text.data() + text.size())));
    }
  }
  return 0;
}

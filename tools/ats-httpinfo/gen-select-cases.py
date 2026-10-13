#!/usr/bin/env python3
"""Test cases for alternate matching, in selectq.cc's input format.

Deterministic (fixed seed). Mixes realistic Accept-* / Content-* / Vary
values with the corner cases ATS's parsers treat specially: q values,
wildcards, quotes, empty list items, white space, case, duplicate fields.

usage: gen-select-cases.py [N_CASES [SEED]]
"""

import random
import sys

rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 20261012)

QS = ["", ";q=1", ";q=0", ";q=0.5", ";q=0.001", ";q=1.0", ";Q=0.3", "; q = 0.7", ";q=0.123456789",
      ";q=abc", ";q=-1", ";q=2", ";q=.5", ";q=1e-1", ";q", ";level=1", ";level=1;q=0.2", ";quality=0.1"]
TYPES = ["text/html", "text/plain", "text/*", "*/*", "*", "image/webp", "image/*", "image/png",
         "application/json", "application/octet-stream", "TEXT/HTML", "text/html ", " text/ html", "text"]
CHARSETS = ["utf-8", "UTF-8", "iso-8859-1", "koi8-r", "*", "", "unicode-1-1"]
ENCODINGS = ["gzip", "x-gzip", "br", "deflate", "identity", "compress", "x-compress", "zstd", "*", "GZIP", ""]
LANGS = ["en", "en-US", "en-us", "de", "de-CH", "fr", "*", "EN", "en-", "e", "identity", "zh-Hant-TW"]
VARY_NAMES = ["Accept-Encoding", "accept-encoding", "Accept", "Accept-Language", "Accept-Charset",
              "User-Agent", "Cookie", "X-Foo", "*", ""]
UAS = ["curl/8.0", "Mozilla/5.0", "mozilla/5.0", ""]
COOKIES = ["a=1", "a=1; b=2", "A=1", ""]


def lst(pool, n_max=4, qs=True):
    items = []
    for _ in range(rng.randint(1, n_max)):
        v = rng.choice(pool)
        if qs and rng.random() < 0.5:
            v += rng.choice(QS)
        items.append(v)
    seps = [", ", ",", " , ", ",  ", ",\t"]
    out = items[0]
    for v in items[1:]:
        out += rng.choice(seps) + v
    r = rng.random()
    if r < 0.05:
        out = '"' + out + '"'
    elif r < 0.10:
        out = out + ","
    elif r < 0.13:
        out = "," + out
    return out


def content_type():
    t = rng.choice(["text/html", "text/plain", "image/webp", "image/png", "application/json", "TEXT/HTML", "text"])
    r = rng.random()
    if r < 0.4:
        t += "; charset=" + rng.choice(["utf-8", "UTF-8", "iso-8859-1", "koi8-r", '"utf-8"'])
    elif r < 0.5:
        t += ";charset=utf-8;format=flowed"
    return t


def value_for(name, side):
    if name == "Accept":
        return lst(TYPES)
    if name == "Accept-Charset":
        return lst(CHARSETS)
    if name == "Accept-Encoding":
        return lst(ENCODINGS)
    if name == "Accept-Language":
        return lst(LANGS)
    if name == "User-Agent":
        return rng.choice(UAS)
    if name == "Cookie":
        return rng.choice(COOKIES)
    if name == "Content-Type":
        return content_type()
    if name == "Content-Encoding":
        return lst(["gzip", "x-gzip", "br", "identity", "deflate", "", "GZIP"], 2, qs=False)
    if name == "Content-Language":
        return lst(["en", "en-US", "de", "fr", "EN", ""], 3, qs=False)
    if name == "Vary":
        return lst(VARY_NAMES, 3, qs=False)
    raise ValueError(name)


REQ_FIELDS = ["Accept", "Accept-Charset", "Accept-Encoding", "Accept-Language", "User-Agent", "Cookie"]
RESP_FIELDS = ["Content-Type", "Content-Encoding", "Content-Language", "Vary"]


def fields(names, p):
    out = []
    for n in names:
        if rng.random() < p:
            out.append((rng.choice([n, n.lower(), n.upper()]) if rng.random() < 0.1 else n, value_for(n, None)))
            if rng.random() < 0.05:
                out.append((n, value_for(n, None)))  # a duplicate field
    rng.shuffle(out)
    return out


def esc(s):
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def case(n):
    lines = [f"case {n}"]
    if rng.random() < 0.7:
        cfg = [2, 2, 2, 2, 0]
    else:
        cfg = [rng.randint(0, 2) for _ in range(4)] + [rng.randint(0, 1)]
    lines.append("cfg " + " ".join(map(str, cfg)))
    client = fields(REQ_FIELDS, 0.6)
    stored = fields(REQ_FIELDS, 0.6)
    if rng.random() < 0.4:
        # Often the stored request repeats the client's values, as when the
        # same client asks again.
        stored = [(k, v) for k, v in client if rng.random() < 0.8] + stored[:1]
    resp = fields(RESP_FIELDS, 0.6)
    for tag, fs in (("c", client), ("r", stored), ("s", resp)):
        for k, v in fs:
            lines.append(f"{tag} {esc(k)}\t{esc(v)}")
    lines.append("end")
    return lines


DATES = [
    "Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT", "Sun Nov  6 08:49:37 1994",
    "Mon, 05 Oct 2026 12:00:00 GMT", "Thu, 01 Jan 1970 00:00:00 GMT", "Wed, 31 Dec 1969 23:59:59 GMT",
    "Tue, 19 Jan 2038 03:14:07 GMT", "Fri, 31 Dec 2037 23:59:59 GMT", "Sat, 29 Feb 2020 23:59:60 GMT",
    "06 Nov 1994 08:49:37 GMT", "mon, 05 oct 2026 12:00:00 gmt", "Monday, 05-Oct-26 12:00:00 GMT",
    "Mon Oct  5 12:00:00 2026", "Mon, 5 Oct 2026 12:00:00 GMT", "   Mon, 05 Oct 2026 12:00:00 GMT",
    "Mon, 05 Oct 2026 12:00 GMT", "Mon, 05 Oct 2026", "", "0", "yesterday", "Mon, 05 Xyz 2026 12:00:00 GMT",
    "Mo, 05 Oct 2026 12:00:00 GMT", "Mon, 05 Oct 69 12:00:00 GMT", "Mon, 05 Oct 70 12:00:00 GMT",
    "Mon, -5 Oct 2026 12:00:00 GMT", "Mon, 05 October 2026 12:00:00 GMT", "Mon, 99999999999 Oct 2026 12:00:00 GMT",
]


# Cases the random ones seldom hit: an empty last item is a zero-length
# value to the Vary comparison, an empty field is not.
FIXED = [
    [("c", "X", "a"), ("r", "X", "a"), ("r", "X", '""'), ("s", "Vary", "X")],
    [("c", "X", "a"), ("r", "X", "a"), ("r", "X", ""), ("s", "Vary", "X")],
    [("c", "X", "a"), ("r", "X", "a, ,"), ("s", "Vary", "X")],
    [("c", "X", "a,"), ("r", "X", "a, ,"), ("s", "Vary", "X")],
    [("c", "X", "a,,b"), ("r", "X", "a, b"), ("s", "Vary", "X")],
    [("c", "X", '"a,b"'), ("r", "X", '"a,b"'), ("s", "Vary", "X")],
    [("c", "X", '"a\\",b"'), ("r", "X", '"a\\",b"'), ("s", "Vary", "x")],
    [("c", "Accept-Encoding", "gzip"), ("r", "Accept-Encoding", "gzip"), ("s", "Vary", "*")],
]


ETAGS = ['"v1"', 'W/"v1"', '"v2"', '""', 'v1', '"v1', '"a,b"', "*"]
DATES_COND = ["Mon, 05 Oct 2026 12:00:00 GMT", "Sun, 04 Oct 2026 12:00:00 GMT", "Tue, 06 Oct 2026 12:00:00 GMT",
              "Mon, 05 Oct 2026 12:00:01 GMT", "garbage", "", "Monday, 05-Oct-26 12:00:00 GMT"]
RECEIVED = [1791201600, 1791200000, 1791300000]


def tag_list():
    items = [rng.choice(ETAGS) for _ in range(rng.randint(1, 3))]
    return rng.choice([", ", ","]).join(items)


def cond_case(n):
    lines = ["cond %d" % n, "recv %d %d" % (rng.choice(RECEIVED), rng.choice([200, 200, 200, 404, 203]))]
    resp = []
    if rng.random() < 0.7:
        resp.append(("ETag", rng.choice(ETAGS)))
    if rng.random() < 0.6:
        resp.append(("Last-Modified", rng.choice(DATES_COND)))
    if rng.random() < 0.5:
        resp.append(("Date", rng.choice(DATES_COND)))
    req = []
    for name, gen in (("If-None-Match", tag_list), ("If-Modified-Since", lambda: rng.choice(DATES_COND)),
                      ("If-Match", tag_list), ("If-Unmodified-Since", lambda: rng.choice(DATES_COND)),
                      ("If-Range", lambda: rng.choice(ETAGS + DATES_COND))):
        if rng.random() < 0.35:
            req.append((name, gen()))
    for k, v in req:
        lines.append("c %s\t%s" % (k, esc(v)))
    for k, v in resp:
        lines.append("s %s\t%s" % (k, esc(v)))
    lines.append("end")
    return lines


def main():
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 800
    for i, fields in enumerate(FIXED, 1):
        print(f"case f{i}\ncfg 2 2 2 2 0")
        for tag, k, v in fields:
            print(f"{tag} {esc(k)}\t{esc(v)}")
        print("end")
    for i in range(1, n + 1):
        print("\n".join(case(i)))
    for d in DATES:
        print("date " + esc(d))
    for i in range(1, n // 2 + 1):
        print("\n".join(cond_case(i)))


if __name__ == "__main__":
    main()

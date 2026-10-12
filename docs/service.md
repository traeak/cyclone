# cyclone-d

`cyclone-d` serves lookups and objects from an ATS cache over HTTP/1.1, on
unix domain sockets and TCP. Like the tools, it reads the cache as it is on
disk: nothing else may write the spans while it runs.

```
cyclone-d --span /dev/sdb --span /dev/sdc --unix /run/cyclone.sock --listen 127.0.0.1:8090
curl --unix-socket /run/cyclone.sock 'http://x/v1/body?url=http%3A%2F%2Forigin.test%2Fa.js' -H 'Accept-Encoding: gzip'
```

It takes the same span options as the tools (`--span`, `--seed`, `--skip`,
`--avg-obj-size`, `--hash`, `--volumes`), plus:

| option | |
|---|---|
| `--unix PATH` | listen on a unix socket (repeatable); a stale socket file is removed first |
| `--listen HOST:PORT` | listen on TCP (repeatable); `[::1]:PORT` for IPv6 |
| `--max-connections N` | connections served at once (default 256); beyond that, accepting waits |
| `--record NAME=VALUE` | a records.yaml setting alternate selection follows (`normalize_ae`, `ignore_accept_*_mismatch`, `global_user_agent_header`) |
| `--disk-directories` | read directories from the spans for each lookup instead of loading them at startup |
| `--access-log` | one line per request on stderr: method, target, status, bytes, time |

All stripes are opened at startup, and their directories (the copy ATS would
use) are read into memory, one task per stripe so stripes on different disks
load at once. That takes 10 bytes per directory entry, the same as ATS
itself: the directory size `cyc-doc stripe` shows, about `cache size /
avg_obj_size × 10` bytes (1.25 GB for 1 TB at the default 8000).

What a request reads from the spans, with directories in memory:

| request | reads |
|---|---|
| lookup | the Doc header of each entry whose tag matches (usually one) |
| object or body, data in the head Doc | that Doc header, then the head fragment in one read |
| body of N more fragments | for each, its Doc header when the chain is followed, the header again and the data when it is read |

With `--disk-directories`, each lookup also reads the bucket's entries, 10
bytes at a time (usually two reads).

## Requests

GET or HEAD. KEY is a cache key in hex (as `cyc-key` prints it); U is a
cache-key URL, percent-encoded (`+` is not a space).

| route | answer |
|---|---|
| `/v1/key?url=U` | `{"input", "key"}` |
| `/v1/lookup/KEY`, `/v1/lookup?url=U` | the directory probe, as `cyc-lookup --json` |
| `/v1/object/KEY`, `?url=U` | the object report, as `cyc-doc object --json`; `&alt=N`, `&range=SPEC` |
| `/v1/body/KEY`, `?url=U` | the body; `&alt=N` |

The JSON reports always answer 200 (a miss is in the report); a bad key or
parameter is 400, an unknown path 404 (with this list), a method other than
GET or HEAD 405.

### Choosing the alternate

Without `alt`, `object` and `body` choose the alternate as ATS would for a GET
with **this request's own header fields** (see "Choosing an alternate" in
`format.md`): a proxy can pass its client's Accept-Encoding, Accept-Language
and so on through. With `alt=N`, that alternate is read.

### Bodies

A body answer has the stored response's status, reason and header fields,
less hop-by-hop fields and Content-Length (set from the body), plus:

| field | |
|---|---|
| `X-Cyclone-Cache` | `hit`; or why there is no body: `miss`, `no-match` (no alternate fits the request; ATS would go to the origin), `no-such-alternate`, `incomplete` (a fragment is missing, or the alternate is one ATS refuses), `error` |
| `X-Cyclone-Key` | the key |
| `X-Cyclone-Alternate` | the alternate read |

Without a body to send, the answer is 404 (500 for `error`) with the object
report as JSON, which says what was found.

A `Range` header with one range (`bytes=A-B`, `A-`, `-N`) on a stored 200
gives 206 with `Content-Range`, reading only the fragments that hold it; a
range starting past the end gives 416 with `Content-Range: bytes */SIZE`. A
Range that cannot be served as one range (several ranges, bad syntax) is
ignored and the whole body sent, as RFC 9110 allows. `If-Range` lets the
range through only when it equals the stored strong ETag or Last-Modified.

The fragment chain is followed and checked before the header is sent, so an
incomplete object is answered with 404 rather than a short body. The body is
then pulled fragment by fragment into the connection's buffer
(`object.BodyReader`); each fragment's Doc is checked again when reading
reaches it, and if it no longer matches, the connection is closed mid-body.

## Design

- `src/service.zig`: the operations, independent of the transport. A
  `Request` (operation, target, alternate, the caller's header fields, range)
  gets a `Response` whose body is bytes or a `BodyReader` to pull from.
- `src/http_server.zig`: HTTP/1.1 on `std.http.Server`, keep-alive, HEAD
  without reading the body.
- `src/report.zig`: the JSON reports, shared with `cyc-doc` and `cyc-lookup`.
- `src/bin/cyclone_d.zig`: options, listeners, one task per connection
  (`std.Io.Group.concurrent`) up to `--max-connections`.
- `Stripe.loadDirectory` / `Cache.loadDirectories`: the directories in
  memory; `dir.BucketChain` walks a bucket from memory or from the span.

The `BodyReader` is pulled, not pushed: HTTP/1.1 pulls as fast as the socket
takes it; an HTTP/2 transport would pull as far as a stream's flow-control
window allows, without changing the service.

Verified by `tools/fixture/check.sh` (check 10): every alternate's body and
status, HEAD lengths, ranges with and without If-Range, 416, ignored multiple
ranges, `object` and `lookup` JSON equal to the tools', selection by the
request's own fields as live ATS served it (`select.tsv`), errors, and 32
connections reading every large body at once; all over one keep-alive
connection plus the 32. It runs twice, with directories in memory and with
`--disk-directories`.

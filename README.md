# cyclone

Read the Apache Traffic Server disk cache without Traffic Server.

cyclone is a Zig library, a set of command-line tools and a small HTTP service
that understand the on-disk cache of ATS master: spans, stripes, directories,
Docs, the marshalled alternate vector, and whole objects split over many
fragments. It finds an object the way ATS would (cache key, stripe
assignment, directory bucket), chooses an alternate the way ATS would
(`SelectFromAlternates`, Vary), and reads its body, a range of it, or answers
a conditional request, without running Traffic Server.

Everything is **offline**: ATS must not be running on the spans while
cyclone uses them. Everything is also **read-only**, except `cyc-delete`,
which removes objects by changing stripe directories as ATS's own remove
does.

## Status

| | |
|---|---|
| ATS version | master only. Stripes of the versions master reads (21 to 24.3) are accepted; only caches written by master itself have been checked |
| Cache keys | MD5 (the non-FIPS build). SHA-256 keys can be made, but the FIPS `Doc` layout is refused, as nothing has checked it yet |
| Platform | Linux (`cyclone-d` uses `signalfd`); the tools are portable Zig |
| Service | HTTP/1.1 over unix sockets and TCP; no HTTP/2 |

## Building

Needs Zig 0.17.

```
zig build                          # debug build into zig-out/bin
zig build -Doptimize=ReleaseFast   # for real caches and the service
zig build test                     # unit tests, including the ATS golden data
```

| program | |
|---|---|
| `cyc-key` | make a cache key from a cache-key URL |
| `cyc-lookup` | find where a key lives: stripe, bucket, matching directory entries |
| `cyc-doc` | read whole objects, and inspect spans, stripes, directories and single Docs |
| `cyc-delete` | remove objects (writes to the spans) |
| `cyclone-d` | serve lookups, objects and bodies over HTTP/1.1 |

`zig build cyc-key -- ARGS` builds and runs one tool. Each has `--help`.

## Describing the cache

cyclone reads no ATS configuration. Each tool is told the layout instead:

```
--span PATH [--seed TEXT] [--skip BYTES]   each span, in storage.yaml order
--avg-obj-size [VOL=]N                     what sized the directories (default 8000)
--volumes N,M,...                          the volumes a host record uses
--hash md5|sha256                          not recorded on disk (default md5)
```

**Span order and naming matter.** ATS assigns keys to stripes with a hash
seeded by each span's name: its storage.yaml `hash_seed`, or else the path
exactly as ATS was configured with it. Give the spans in storage.yaml order,
and when `PATH` is not the string ATS used (a relative path, a different
symlink), pass that string with `--seed`. Otherwise lookups go to the wrong
stripes and every object misses.

`--avg-obj-size` must be the value the directories were sized with
(records.yaml `min_average_object_size`, or a volume's `avg_obj_size`). If it
is wrong, `cyc-doc stripe` finds the footer elsewhere and reports the range of
sizes that would fit.

## Using the tools

```
$ cyc-key 'http://example.com/a.js'
$ cyc-key --explain 'http://example.com/a.js?v=1'      # the exact bytes hashed

$ cyc-lookup --span /dev/sdb --span /dev/sdc 'http://example.com/a.js'

$ cyc-doc span   --span /dev/sdb --span /dev/sdc
$ cyc-doc stripe --span /dev/sdb --span /dev/sdc --json
$ cyc-doc dir    --span /dev/sdb --span /dev/sdc --entries --docs

$ cyc-doc object --span /dev/sdb --span /dev/sdc 'http://example.com/a.js'
$ cyc-doc object --span /dev/sdb --span /dev/sdc 'http://example.com/a.js' \
      --select --req-header 'Accept-Encoding: gzip' --body > a.js.gz
$ cyc-doc object --span /dev/sdb --span /dev/sdc KEY --alt 1 --range bytes=0-1023 --body
```

`cyc-doc object` follows the fragment chain as ATS reads it and reports any
fragment that is missing or does not match; `--body` exits 1 if the object is
incomplete. Most commands take `--json`.

## Deleting objects

```
$ cyc-delete --span /dev/sdb --span /dev/sdc --dry-run 'http://example.com/a.js'
$ cyc-delete --span /dev/sdb --span /dev/sdc - < urls.txt
```

`cyc-delete` removes each object's head entry from its stripe's directory,
as ATS's remove does; the data stays on disk, unreachable, until the cache
overwrites it. Each changed stripe's directory is written to its other copy
with the next sync serial, as ATS's shutdown sync writes it, so the copy in
use stays intact until the new one is complete, and the result is read back
before it reports success.

**Stop ATS first.** `cyc-delete` refuses to write a span another process has
open (it looks through `/proc`; as a non-root user it cannot see other
users' processes). If ATS keeps its directories in shared memory
(`proxy.config.cache.shm.enabled`), remove the `/dev/shm/ats-*` segments
before starting it again, or it will restart from them and the deletions are
lost; `cyc-delete` warns when it sees them.

## The service

```
cyclone-d --span /dev/sdb --span /dev/sdc --unix /run/cyclone.sock --listen 127.0.0.1:8090
curl --unix-socket /run/cyclone.sock \
     'http://x/v1/body?url=http%3A%2F%2Fexample.com%2Fa.js' -H 'Accept-Encoding: gzip'
```

`cyclone-d` opens the spans once, keeps the stripe directories in memory (10
bytes per directory entry, as ATS does), and answers:

| route | |
|---|---|
| `/v1/key`, `/v1/lookup` | cache keys and directory probes |
| `/v1/object` | the object report, as `cyc-doc object --json` |
| `/v1/body` | the body, with the stored status and header fields; Range, If-Range and conditional requests as ATS answers them from the cache |
| `/v1/stripes`, `/v1/dir` | stripe headers, directory statistics, and a streamed directory scan |

The alternate is chosen from the request's own header fields, so a proxy can
pass its client's Accept-Encoding and the like through. It stops gracefully on
SIGTERM. See [docs/service.md](docs/service.md) for the options, every route,
and its limits.

## How it is checked

cyclone is checked against ATS itself rather than against a reading of its
source:

- **ATS's own code.** Small harnesses link ATS master's real functions and
  write golden data that the unit tests replay. This covers cache keys
  (`tools/ats-keygen`), the layout of the marshalled headers, alternate
  decoding, alternate selection, and conditional requests
  (`tools/ats-httpinfo`).
- **A live ATS.** `tools/fixture/make-fixture.sh` runs ATS master in a sandbox
  in front of a test origin, fills two small spans with known objects
  (several fragments, Vary alternates, ETags), records what ATS logged and
  served, and stops it cleanly. `tools/fixture/check.sh` then runs 13 checks of
  the tools and `cyclone-d` against that fixture, comparing them with ATS's
  logs and responses and with the bodies the origin sent.
- **ATS reading what cyclone wrote.** For `cyc-delete`, the real ATS is
  started on a copy of the fixture that cyclone changed, and must miss
  exactly the deleted objects and serve everything else unchanged.

```
tools/fixture/make-fixture.sh ATS_PREFIX tests/fixtures/basic   # an installed ATS master
zig build -Doptimize=ReleaseFast && tools/fixture/check.sh
ATS_PREFIX=/path/to/ats tools/fixture/check.sh                  # also runs ATS on cyc-delete's output
```

## Documentation

- [docs/format.md](docs/format.md): the on-disk format, byte by byte, with the
  ATS source each part comes from.
- [docs/service.md](docs/service.md): `cyclone-d`.
- [PLAN.md](PLAN.md): decisions, and what has been built in what order.

## Layout of the source

```
src/format/   pure decoders over byte slices: span, stripe, dir, doc, http (alternates)
src/          the library: key, url, assign, cache, stripe, dir, doc, object,
              select, conditional, report; dir_edit, delete and guard for
              cyc-delete; service and http_server for cyclone-d
src/bin/      the programs
src/testdata/ golden data written by the ATS harnesses
tools/        ATS harnesses (C++, built against an ATS checkout) and the fixture scripts
```

## License

Apache License 2.0; see [LICENSE](LICENSE). cyclone ports parts of Apache
Traffic Server, whose notice is carried in [NOTICE](NOTICE).

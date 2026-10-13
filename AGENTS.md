# AGENTS.md

Guidance for coding agents working on cyclone. Read README.md first for what
the project is; PLAN.md records the decisions and the order things were built
in; docs/format.md is the on-disk format with ATS source references.

## Ground rules

- **Offline, and read-only except `cyc-delete`.** The code may assume
  nothing else uses the spans while it runs; do not add locking or
  re-reading for a live cache. Only `dir_edit.zig` (through `cyc-delete`)
  writes, and only directory copies, the way ATS's own sync writes them.
  Everything else opens spans read-only and must stay that way. A new kind
  of write needs the same standard: ATS itself started on cyclone's output
  must accept it (see `check-delete.sh`), with a negative control showing
  the check would fail without the change.
- **ATS master is the reference.** The source is at `../trafficserver`. When
  porting behaviour, port what ATS actually does, quirks included, and name
  the function and file it comes from in a comment (`SelectFromAlternates` in
  HttpTransactCache.cc, `url_CryptoHash_get_general`, ...). Do not "fix" a
  quirk without saying so in the docs.
- **Verify against ATS, not against your reading of it.** Anything that
  decides a result (keys, layout, decoding, selection, conditionals) is
  checked against ATS's own code (golden data from `tools/ats-*`) and against
  a live ATS (the fixture). New behaviour of that kind needs the same.
- Zig 0.17, std only; no dependencies.

## Commands

```
zig build                              # debug build
zig build -Doptimize=ReleaseFast       # what check.sh and benchmarks use
zig build test                         # unit tests, golden replays included
zig fmt src                            # before committing
tools/fixture/check.sh                 # 13 checks against the fixture; needs a build first
ATS_PREFIX=/path/to/ats tools/fixture/check.sh   # check 13 also starts ATS on cyc-delete's output
```

`check.sh` needs `tests/fixtures/basic` (not committed). Making it needs an
installed ATS master:

```
tools/fixture/make-fixture.sh ATS_PREFIX tests/fixtures/basic
tools/ats-httpinfo/build.sh ../trafficserver .ats-build tests/fixtures/basic   # alts_golden.txt for check 6
```

Without `alts_golden.txt` check 6 is skipped; without `select.tsv` check 9 is.

## Where things are

| | |
|---|---|
| `src/format/` | pure decoders over byte slices, no I/O: span, stripe, dir, doc, http (alternate vector, header heaps) |
| `src/key.zig`, `src/url.zig` | cache keys; URL → key |
| `src/assign.zig` | the stripe assignment table |
| `src/span.zig`, `src/stripe.zig`, `src/dir.zig`, `src/doc.zig` | reading those structures from a span |
| `src/cache.zig` | spans + table + stripes + probe; shared by tools and service |
| `src/object.zig` | head, alternates, fragment chain, `BodyReader`, ranges |
| `src/select.zig`, `src/conditional.zig` | ATS's alternate selection and conditional requests |
| `src/dir_edit.zig`, `src/delete.zig`, `src/guard.zig` | changing directories (ATS's remove and sync), deleting objects, and the checks before writing |
| `src/report.zig` | the JSON reports, shared by the tools and `cyclone-d` |
| `src/service.zig` | `cyclone-d`'s operations, independent of transport; bodies are a pull `Source` |
| `src/http_server.zig`, `src/bin/cyclone_d.zig` | HTTP/1.1 transport, listeners, shutdown |
| `src/bin/` | the four programs; `src/cli.zig` holds the shared options |
| `src/testdata/` | golden data from the ATS harnesses (regenerate, never hand-edit) |
| `tools/ats-keygen`, `tools/ats-httpinfo` | C++ harnesses linked against ATS's real functions |
| `tools/fixture/` | `origin.py`, `make-fixture.sh`, `check.sh`, `check-delete.sh` |

## Golden data and the fixture

- `tools/ats-keygen/build.sh ../trafficserver` regenerates
  `src/testdata/key_golden.txt`; `tools/ats-httpinfo/build.sh ../trafficserver`
  regenerates `hdr_layout.txt` and `select_golden.txt` (the selection cases
  and the `cond` blocks for conditionals, from `gen-select-cases.py`).
- The harnesses build into `.ats-build/`. **If `../trafficserver` has moved
  (rebase, pull), rerun `build.sh`** before trusting a mismatch: a stale
  object there once produced 15 false conditional mismatches.
- The fixture's ATS install may be older than the checkout. Say which ATS
  revision golden data and fixture came from when it matters.
- New fixture data goes through `make-fixture.sh` (recorded from the live ATS,
  e.g. with `Cache-Control: only-if-cached`) and a check in `check.sh`.
- `check.sh` runs under `/bin/sh` with `set -eu`: no bashisms, and guard
  commands whose failure is expected (`wait $pid || true`).

## Pitfalls

- **Span paths seed stripe assignment.** The fixture was written with absolute
  span paths; passing `tests/fixtures/basic/spans/...` relatively sends every
  lookup to the wrong stripe and everything misses. Use absolute paths (as
  `check.sh` does) or `--seed`.
- Do not use `pkill -f` / `pgrep -f` with a pattern that also appears in your
  own command line: it matches the shell running it. Use the PID from `$!`.
- Unix socket paths are limited to 107 bytes; long scratch directories fail.
- Copying spans elsewhere changes their path, and so their stripe hash: pass
  `--seed ORIGINAL_PATH` to cyclone and `hash_seed` in ATS's storage.yaml,
  as `check-delete.sh` does.
- ATS logs `recovery clearing offsets` on every restart; it is not a sign of
  a damaged directory. `clearing cache directory` or `clearing the disk`
  are.
- Files in `/proc` report size 0: read them with `readerStreaming`, not by
  size.
- Zig 0.17 specifics met so far:
  - `std.log` is filtered out in ReleaseFast; the programs print with
    `std.debug.print`.
  - `zig fmt` rewrites `@intFromEnum` to `@backingInt`.
  - `std.http.Server`'s `BodyWriter.end` asserts every content-length byte
    was written, even for HEAD (eliding): write them with `splatByteAll`.
  - `respond` always sends a content-length, so 304 and 204 are written by
    `respondWithoutBody` in `http_server.zig`. `discardBody` is private; set
    `reader.state = .ready` instead.
  - `Io.Uring` (the evented backend) has no listen, accept or socket I/O yet,
    so `cyclone-d` runs on `Io.Threaded`: one OS thread per connection.

## Style

- Match the surrounding code: doc comments on public items, comments that say
  why or which ATS function, little else. Decode with explicit
  little-endian reads, not `extern struct` punning; ATS bit-fields are
  decoded by hand as its `dir_*` macros do.
- Docs (`docs/*.md`, help texts) are plain prose and tables; update them with
  the behaviour, and record finished steps in PLAN.md.
- Commits: an imperative subject line, then a body that says what changed and
  how it was verified. Commit only when asked.

# cyclone — plan

A standalone Zig 0.17 toolkit for reading the Apache Traffic Server (ATS) disk cache,
done in three stages:

1. a library that understands the on-disk format
2. CLI tools built on it: `cyc-key` (makes cache keys), `cyc-doc` (reads whole objects), `cyc-lookup` (key → object)
3. a long-running service that offers the same operations over a unix domain socket or TCP

## Decisions

| Topic | Decision |
|---|---|
| ATS version | **master only** (`../trafficserver`). Accept the cache DB versions that master accepts. No 9.2 support. |
| Hash type | **Default MD5** (128-bit keys, non-FIPS `Doc` layout), because existing cache volumes use MD5. The cache does not record its hash type anywhere on disk (see below), so `--hash md5\|sha256` overrides the default. SHA-256 (FIPS) support is not required now, but key width and `Doc` layout are chosen at runtime from this setting so it can be added without restructuring. |
| Live cache | **Offline only.** ATS is stopped while the tools run, so there are no races and the on-disk directory is authoritative (as of the last sync, which happens at a clean shutdown). |
| Layout | **Given on the command line.** We do not parse `storage.yaml`, `volume.config` or `hosting.config`. |
| Lookup input | **A formed cache key.** `cyc-key` turns a cache-key URL string into the 128-bit key. Lookups take the hex key, or a URL that goes through the same code. |
| `cyc-doc` output | **Whole objects**: the alternate vector, then all fragments of the chosen alternate, reassembled. Single-fragment access stays available as a debug option. |

Everything is **read-only**. The tools never write to a span.

Reference source: `../trafficserver` (`src/iocore/cache`, `include/iocore/cache`, `src/proxy/hdrs/URL.cc`,
`src/proxy/hdrs/HTTP.cc` / `HdrHeap.cc`) and the existing C++ tool `src/traffic_cache_tool` as prior art.

---

## Terminology (as ATS uses it)

| Term | Meaning |
|---|---|
| **Span** | A raw device or file. It starts with a `DiskHeader` (magic `0xABCD1237`) that lists its stripe blocks. |
| **Stripe** | A contiguous region of a span. It holds two header/directory/footer copies (A and B) followed by the **content area**. The content area is the *cyclone buffer*: a circular log written at `write_pos`, with a `phase` bit that flips on every wrap. |
| **Volume** | A logical grouping of stripes. Keys are spread across a volume's stripes through the stripe-assignment hash table. |
| **Directory** | segments × buckets × `DIR_DEPTH`(4) entries of 10 bytes (`Dir`, 5 × u16). Each entry holds offset (40 bits), size/big, a 12-bit tag, phase, head, pinned, and `next` (the chain index). |
| **Doc** | A fragment in the content area. Header magic is `0x5F129B13`, with `len`, `total_len`, `first_key`, `key`, `hlen`, `doc_type`, version, serials, `pinned`, `checksum`. Then `hlen` bytes of marshalled header data, then body data. |
| **Cache key** | A 128-bit `CryptoHash`. Its 32-bit slices select the stripe, the segment/bucket, and the tag. |

### How a whole object is stored

```
URL key ──dir──► first Doc ("vector" Doc, key = first_key = URL key)
                   hlen region = CacheHTTPInfoVector: N alternates, each one
                   HTTPCacheAlt { request hdr, response hdr, m_object_key (earliest key),
                                  object size, frag offset table, ... }
alt.m_object_key ──dir──► earliest Doc (fragment 0 of that alternate's body)
next_CacheKey(k) ──dir──► fragment 1 ──► fragment 2 ...  until total_len is covered
```
A small single-alternate object can carry its body directly in the vector Doc. The earliest key is random (`rand_CacheKey`), so it can only be found by decoding `HTTPCacheAlt`. That makes **HTTPInfo decoding a core requirement, not an optional extra.**

---

## Command-line layout spec

Every tool takes the same layout arguments, which replace parsing ATS config files:

```
--span PATH[:SKIP_BYTES]     (repeatable, in the same order as storage.yaml; ORDER MATTERS for stripe assignment)
--volume N                   (which volume number to look in; default: all/only)
```
- The span's own `DiskHeader` already lists its stripes, with offsets, lengths and volume numbers. So the CLI only needs span paths and their order; stripes are discovered.
- The stripe-assignment table is rebuilt from each stripe's `hash_id`. Upstream seeds that from the span path string plus offset/length, so `--span` must use the **exact path string ATS was configured with**, or provide `--span PATH --as /dev/disk/by-id/...` to override the hash name. (To be confirmed in Phase 0.)
- Later, the same layout can be loaded from a small file of our own (`--layout layout.zon`).

---

## Phase 0 — Format spec and test fixtures

- [ ] `docs/format.md`: byte-exact layouts with endianness, alignment, and the master source line each one came from:
  - `DiskHeader` / `DiskStripeBlock` (span start offset, `STORE_BLOCK_SIZE` = 8192)
  - `StripeHeaderFooter` (magic `0xF1D0F00D`, version, `write_pos`, `agg_pos`, `phase`, `cycle`, serials, `dirty`, `sector_size`, `freelist[]`). Include the rules for choosing A vs B.
  - Stripe geometry: segments/buckets from stripe length and average object size, directory length, where the content area starts.
  - `Dir` bit layout, `dir_offset` → byte offset (`CACHE_BLOCK_SHIFT` = 9), `big`/`size` → approximate length
  - `Doc` header (non-FIPS)
  - Stripe `hash_id` seeding, `build_vol_hash_table`, and key → stripe / segment / bucket / tag
  - `next_CacheKey` / `CacheKey_next_table`
  - Marshalled `CacheHTTPInfoVector` / `HTTPCacheAlt` / `HdrHeap` (offset-swizzled pointers, string heaps)
  - Well-known header string table (`src/proxy/hdrs/HdrToken.cc`). Master's cache DB is version 24.3 (`include/iocore/cache/CacheVersion.h:40`), and 24.3 changed how stored objects refer to this table. Port that handling.
- [ ] **Fixture script**: build master ATS, run it with one or two small file-backed spans (e.g. 2 × 256 MB) and two volumes, and load a known URL set: tiny, multi-fragment (> `target_fragment_size`), multiple alternates (`Vary`), query strings, and a non-default port. Stop ATS cleanly and snapshot the span files and the URL list (`tests/fixtures/`, not committed if large).
- [ ] Golden outputs from `traffic_cache_tool` and from ATS debug tag `url_cachekey` (prints the exact string that gets hashed), used to cross-check `cyc-key`.

## Phase 1 — `cyclone` core library (Zig module)

Pure decoding, separated from I/O so it can be unit-tested on byte slices.

```
src/
  format/      span.zig  stripe.zig  dir.zig  doc.zig  http_info.zig  hdr_heap.zig  version.zig
  key.zig      CacheKey type, hex parse/format, next/prev, URL → key (port of url_CryptoHash_get_general)
  io/          span_reader.zig   (positional reads, aligned buffers, std.Io)
  layout.zig   CLI layout → spans → stripes → volumes; stripe hash table
  lookup.zig   key → stripe → bucket chain → Dir → Doc
  object.zig   vector Doc → alternates → fragment walk → body reader
```

- Decode with explicit little-endian reads (`std.mem.readInt`) instead of `extern struct` punning. The bit-fields in `Dir` and `Doc` are compiler-defined in C++, so decode them by hand, the same way the `dir_*` macros do.
- Validate everything: magic, version, bounds, checksum (when not `DOC_NO_CHECKSUM`), `key` matching what was requested, and `total_len` consistency across fragments.
- I/O goes through `std.Io` (0.17 ships `Threaded` and `Uring` backends).
- Unit tests: hand-built byte vectors plus fixture-driven tests (`zig build test`).

## Phase 2 — CLI tools

All three are executables in `build.zig` sharing the module. They can later merge into one `cyclone <subcommand>`.

### `cyc-key` — make a cache key (kept simple)
```
cyc-key 'http://example.com/path?q=1'            → 32-hex-digit key
cyc-key --ignore-query --generation 3 URL
cyc-key --explain URL                            → shows the canonical string + port bytes that were hashed
```
A port of `url_CryptoHash_get_general`: it lowercases and unescapes scheme and host, unescapes user and password, copies path and query verbatim, then adds the canonical port (u16, little-endian) and an optional generation (i64). The URL parser handles only what a cache-key URL needs.

### `cyc-doc` — read a whole object
```
cyc-doc object   --span cache.db KEY|URL [--alt N | --select [--req-header 'NAME: VALUE']...]
                 [--range SPEC] [--headers | --body > out.bin] [--json]
cyc-doc fragment --span cache.db --at SPAN:OFFSET [--headers | --data] [--json]   # one Doc, by location
```
- Default output: object summary, the list of alternates (request URL, status, content type, size, Vary), and fragment chain health.
- `--headers` prints the stored request/response headers. `--body` streams the reassembled body of the selected alternate.
- `fragment` reads only the Doc at one location (debug mode); `--data` writes its data bytes.
- Supporting debug subcommands: `span` (DiskHeader + stripes), `stripe` (A/B headers, geometry, write_pos/phase), `dir` (walk/dump entries, stats).

### `cyc-lookup` — key → location
```
cyc-lookup --span s0.db --span s1.db [--volume 1] (--key HEX | --url URL)
```
Prints the chosen stripe, segment/bucket, the chain walk (tag matches, phase/offset validity), and the matching Doc locations. It is the locating half of `cyc-doc --key`, exposed for debugging and scripting.

## Phase 3 — Service

A daemon (`cyclone-d`) that opens the spans once, keeps stripe headers and directories in memory, and answers requests.

- **Transport**: unix domain socket and TCP, both through `std.Io.net`.
- **Protocol**: put the operations behind a transport-independent request/response layer (`key`, `lookup`, `object_info`, `object_body` (streamed), `stripe_info`, `dir_scan`), then add transports:
  1. **HTTP/1.1 with keep-alive via `std.http.Server`** first. It is already in std, and `curl --unix-socket` can test it.
  2. **h2c** if benchmarks show that multiplexing per connection matters. Zig std has no HTTP/2, so this means our own framer/HPACK or binding nghttp2.
  3. **A compact length-prefixed binary protocol** for a controlled LAN.
- Offline-only still applies: the daemon assumes nothing else writes the spans.

---

## Still open

- ~~Is the hash type stored on disk?~~ **No.** `CryptoContext::Setting` is fixed at build time (`src/tscore/CryptoHash.cc:33-37`: MD5, or SHA-256 when `TS_ENABLE_FIPS`), and there is no runtime config. Neither `DiskHeader`, `StripeHeaderFooter` nor `Doc` records it, and the stripe version number is the same for both. Hence the default of MD5 plus `--hash`. Optional later: a `--check-hash` sanity probe that reads a few head Docs and checks that `len`/`hlen`/`first_key`↔dir-tag are consistent under the chosen layout (non-FIPS `Doc` header = 72 bytes, FIPS = 104), and warns on a mismatch.
- How exactly is the stripe `hash_id` seeded: which path string, and what to do when it is a device symlink? This decides whether a `--as` override is needed.
- ~~How should `cyc-doc` pick an alternate by default?~~ Index 0 (`--alt N`); `--select` with `--req-header` matches as ATS does.

## Immediate next steps

1. ~~`zig init` skeleton~~ done: module `cyclone` (`src/root.zig`), tools in `src/bin/`, `zig build test`, `zig build cyc-key -- ARGS`.
2. ~~`cyc-key`~~ done: `src/url.zig` ports `url_parse` + `url_CryptoHash_get_general` (and the 9.2 variant). Its output matches keys from ATS master's own code (`tools/ats-keygen`, golden data in `src/testdata/`) for 68 URLs × 4 option sets. SHA-256 output is not yet checked against a FIPS build.
3. `docs/format.md` + decoders for the span header, stripe header and `Dir`, then `cyc-doc span|stripe|dir` against a fixture.
   - ~~Span~~ done: `src/format/span.zig`, `src/span.zig`, `cyc-doc span`, matches ATS's own log for the fixture. Fixture: `tools/fixture/make-fixture.sh ATS_PREFIX tests/fixtures/basic`.
   - ~~Stripe~~ done: `src/format/stripe.zig`, `src/stripe.zig`, `cyc-doc stripe`. Geometry comes from `--avg-obj-size [VOL=]N`. If the footer is not where that puts it, a footer scan reports the matching `avg_obj_size` range (exact value still needed for bucket count).
   - ~~Directory~~ done: `src/format/dir.zig`, `src/dir.zig` (one segment at a time), `cyc-doc dir` (stats, `--entries`, `--segment`). Fixture: all 49 URL keys found at their predicted bucket and tag.
   - ~~Stripe assignment~~ done: `src/assign.zig`. `cyc-lookup` works up to directory candidates (`--volumes`, `--table`, batch via `-`). `tools/fixture/check.sh` compares the tools with ATS's own fixture log: key strings, directory sizes, table, and lookups.
   - ~~`Doc` header~~ done: `src/format/doc.zig` (MD5 and FIPS layouts, checksum), `src/doc.zig` (read, verdict against a key). `cyc-lookup` confirms each tag match against the Doc: hit, stale, collision. `cyc-doc dir --docs` shows each entry's Doc and which key it is filed under. The 5 extra heads in the fixture are the 3 large objects' earliest fragments and the 2 Vary objects' second alternates (check 5 in `check.sh`).
4. ~~Lookup~~ done.
5. ~~HTTPInfo decoding~~ done: `src/format/http.zig` decodes the alternate vector (alternates, both heaps, URL, fields, fragment offset table, both table formats). Layout offsets are checked against ATS's compiled structs (`tools/ats-httpinfo`, `src/testdata/hdr_layout.txt`), and every fixture alternate matches ATS's own `HTTPInfo::unmarshal` (check 6). `cyc-doc fragment --at S:OFFSET [--headers|--data]` shows one Doc. Not verified: the FIPS layout (refused), and pre-24.2 Docs (no sample).
6. ~~Whole objects~~ done: `src/cache.zig` (spans + assignment table + stripes + probe, shared by the tools and later the service), `src/object.zig` (head, alternates, fragment chain, body). `cyc-doc object KEY|URL [--alt N] [--headers | --body] [--json]` reports each fragment and any inconsistency, and `--body` streams the body (exit 1 if incomplete). `cyc-lookup --stripe S:B` finds a data-fragment key in its object's stripe. Check 7 compares every alternate's body with what the origin sent.
7. ~~Alternate selection and range reads~~ done: `src/select.zig` ports `SelectFromAlternates` (quality from Accept, Accept-Charset, Accept-Encoding, Accept-Language; Vary; age tie-break; Accept-Encoding normalization), checked against ATS's own functions on 808 generated cases (`tools/ats-httpinfo/selectq.cc`, `src/testdata/select_golden.txt`) and against what the live ATS served for 29 requests (check 9). `cyc-doc object --select [--req-header ...] [--record NAME=VALUE]`. Range reads (`--range`) seek with the fragment offset table as ATS does and read only the fragments needed (check 8).
8. ~~Service, HTTP/1.1~~ done: `cyclone-d` (`docs/service.md`). `src/service.zig` is the transport-independent layer (key, lookup, object report, body); bodies are pulled from `object.BodyReader`, so an HTTP/2 transport can pull per its flow-control window. `src/http_server.zig` is HTTP/1.1 on `std.http.Server` over unix sockets and TCP, one task per connection. JSON reports moved to `src/report.zig`, shared with the tools. Check 10 runs the daemon on the fixture. Rough numbers (ReleaseFast, warm page cache, unix socket, curl): ~20k small bodies/s on one keep-alive connection, ~110k/s over 8, ~2 GB/s for a 9 MB body.
9. ~~Directories in memory~~ done: `Stripe.loadDirectory`, `Cache.loadDirectories` (one task per stripe), `dir.BucketChain` walks a bucket from memory or the span. `cyclone-d` loads them at startup (`--disk-directories` to not). Reads per request from the spans: lookup 3 → 1, small body 5 → 2 (the head fragment is now read in one call, bounded by the entry's approximate size). End-to-end time on the fixture barely changes (~44 µs per request over curl, page cache warm): the saved reads were page-cache hits; it matters on a cold cache and under load.
10. Next, open: `stripe_info` and `dir_scan` operations; conditional requests (304); graceful shutdown; h2c if multiplexing proves to matter (see the transport list above).

# ATS cache on-disk format

Reference for ATS master (cache DB version 24.3, non-FIPS). All integers are
little-endian, laid out as GCC lays out the C++ structs on x86-64. Source
paths are relative to the trafficserver tree.

## Span

A span is a raw device or a file (`storage.yaml` `cache.spans`). ATS reads
it through `CacheDisk` (`src/iocore/cache/CacheDisk.cc`).

### Where the header is

```
skip = ROUND_TO_STORE_BLOCK(offset < START_POS ? START_POS + alignment : offset)
```
(`CacheProcessor::start_internal`, `src/iocore/cache/CacheProcessor.cc`)

| Constant | Value | Defined in |
|---|---|---|
| `STORE_BLOCK_SIZE` | 8192 | `include/iocore/cache/Store.h` |
| `START_POS` | 16 × 512 = 8192 | `src/iocore/cache/StripeSM.h` |
| `STRIPE_BLOCK_SIZE` (`MIN_STRIPE_SIZE`) | 128 MB | `src/iocore/cache/Stripe.h` |
| `DISK_HEADER_MAGIC` | `0xABCD1237` | `src/iocore/cache/P_CacheDisk.h` |

`offset` is 0 unless configured, and `alignment` comes from the device
geometry (0 for files), so the header is normally at byte 8192. cyclone
probes from 8192 up to 1 MB in store-block steps; `--skip` overrides that.

The span length ATS works with is `blocks = size / 8192 - skip / 8192`
store blocks. For a file, `size` is the file size. For a block device, it is
the device size (`BLKGETSIZE64`).

### `DiskHeader` (32 bytes + entries)

| Offset | Type | Field | Meaning |
|---|---|---|---|
| 0 | u32 | `magic` | `0xABCD1237` |
| 4 | u32 | `num_volumes` | distinct volume numbers on this span |
| 8 | u32 | `num_free` | free stripe blocks |
| 12 | u32 | `num_used` | stripe blocks in use |
| 16 | u32 | `num_diskvol_blks` | entries in `vol_info[]` |
| 20 | — | padding | |
| 24 | u64 | `num_blocks` | span length in store blocks; must equal `blocks` |
| 32 | `DiskStripeBlock[]` | `vol_info` | `num_diskvol_blks` entries |

If `num_blocks` does not match, ATS clears the span, with one exception. A
header written by ATS 3.2 is off by exactly `skip - skip / 8192`, and ATS
accepts that (`CacheDisk::openStart`).

### `DiskStripeBlock` (24 bytes)

| Offset | Type | Field | Meaning |
|---|---|---|---|
| 0 | u64 | `offset` | byte offset of the stripe from the start of the device (not from `skip`) |
| 8 | u64 | `len` | stripe length in store blocks |
| 16 | i32 | `number` | volume number |
| 20 | u32 bits 0–2 | `type` | `CacheType`: 0 none, 1 HTTP, 2 RTSP |
| 20 | u32 bit 3 | `free` | 1 = unallocated |

### Header size and the first stripe

ATS reserves header space for the most stripe blocks the span could ever
hold, not for how many it has (`CacheDisk::open`):

```
start = skip
repeat 3 times:
    l = blocks * 8192 - (start - skip)
    header_len = l >= 128 MB ? 56 + (l / 128 MB - 1) * 24 : 56     # 56 = sizeof(DiskHeader)
    start = skip + header_len
start = skip + ROUND_TO_STORE_BLOCK(header_len)
```
The first stripe starts at `start` (16384 for any span under ~43 GB).
Stripes are allocated in 128 MB multiples.

### Stripes, volumes, and the stripe hash text

Each used `DiskStripeBlock` becomes one stripe (`Cache::open`). For each
volume, ATS takes spans in configuration order, and within a span takes
that volume's blocks in header order.

Each stripe is identified by its **hash text** (`Stripe::_init_hash_text`):

```
"<seed> <offset>:<len>"        e.g. "/var/cache/ats/disk0 16384:16384"
```
Here `seed` is the span's `hash_seed` from storage.yaml if set, otherwise
the span path exactly as configured. `offset` is the block's byte offset and
`len` is its length in store blocks. MD5 of this text is the stripe's
`hash_id`, which seeds the key-to-stripe assignment table. So a lookup must
use the same seed ATS used (`--seed`).

Verified against the fixture (`tools/fixture/make-fixture.sh`): ATS logged
`Stripe seed-span1 16384:16384` and `.../span0.db 134234112:32768`, and
`cyc-doc span` reports the same values.

## Stripe

One used `DiskStripeBlock` = one stripe (`src/iocore/cache/Stripe.{h,cc}`,
`StripeSM.cc`). The stripe's `skip` is the block's `offset`, and its `len`
is `block.len * 8192` bytes.

### Layout

```
skip ──► copy A:  header   StripeHeaderFooter + u16 freelist[segments]   rounded to 8 KB  (headerlen)
                  entries  segments × buckets × 4 × 10-byte Dir           rounded to 8 KB
                  footer   StripeHeaderFooter                             rounded to 8 KB
         copy B:  same, at skip + dirlen
start ─► content area (the cyclone buffer), to skip + len
```
`dirlen = headerlen + entries + footer` and `start = skip + 2 * dirlen`.

### Geometry (`Stripe::_init_data`)

The directory is sized from the stripe length and the volume's
`avg_obj_size`. That is storage.yaml `volumes[].avg_obj_size` if set,
otherwise `proxy.config.cache.min_average_object_size` (default 8000). Each
pass sizes the directory from the space the previous pass left for content:

```
start = skip
repeat 3 times:
    total_entries = (len - (start - skip)) / avg_obj_size
    total_buckets = total_entries / 4
    segments      = ceil(total_buckets / 16384)        # a segment holds at most 16384 buckets
    buckets       = ceil(total_buckets / segments)     # buckets per segment
    start         = skip + 2 * dirlen
```
`avg_obj_size` is not stored on disk, so `--avg-obj-size [VOL=]N` supplies it.
If the footer is not where that value puts it, `cyc-doc stripe` scans for
copy A's footer (a block matching header A's magic, sync serial and create
time) and reports which `avg_obj_size` values give that directory length.
Many values give the same length but different bucket counts, and lookups
need the exact bucket count, so the configured value is still required.

Verified against the fixture: ATS logged 188416 directory bytes for a
128 MB stripe and 352256 for a 256 MB one, which matches the computed
`dirlen` (1 × 4182 and 1 × 8366 buckets).

### `StripeHeaderFooter` (72 bytes + freelist)

| Offset | Type | Field | Meaning |
|---|---|---|---|
| 0 | u32 | `magic` | `0xF1D0F00D` |
| 4 | u16, u16 | `version` | major, minor; master writes 24.3 and reads majors 21–24 |
| 8 | i64 | `create_time` | unix time the stripe was initialized |
| 16 | i64 | `write_pos` | next write position, byte offset in the span |
| 24 | i64 | `last_write_pos` | |
| 32 | i64 | `agg_pos` | |
| 40 | u32 | `generation` | commented "token generation, cannot be 0", but master never sets it (0) |
| 44 | u32 | `phase` | flips each time `write_pos` wraps |
| 48 | u32 | `cycle` | number of wraps |
| 52 | u32 | `sync_serial` | bumped on each directory sync |
| 56 | u32 | `write_serial` | |
| 60 | u32 | `dirty` | the periodic sync clears it before writing; the shutdown sync writes it set |
| 64 | u32 | `sector_size` | |
| 68 | u32 | unused | |
| 72 | u16[segments] | `freelist` | header only: head entry index of each segment's free list |

### Choosing a copy (`StripeSM::handle_header_read`)

With A header/footer serials `ha`/`fa` and B serials `hb`/`fb`:

```
if ha == fa and (ha >= hb or hb != fb):  use A
elif hb == fb:                            use B
else:                                     no usable copy (ATS clears the stripe)
```
The chosen copy must then have the magic in header and footer, and a major
version in 21–24 (`handle_dir_read`).

## Directory

The entries region of the chosen copy is `segments` consecutive segments
of `buckets × 4` entries (`Directory::get_segment`). Entry `i` of segment
`s` is at `entries_offset + (s * buckets * 4 + i) * 10`.

### `Dir` entry (10 bytes = 5 × u16)

Bit fields as the `dir_*` macros in `P_CacheDir.h` read them:

| Word | Bits | Field | Meaning |
|---|---|---|---|
| w[0] | 0–15 | offset bits 0–15 | |
| w[1] | 0–7 | offset bits 16–23 | |
| w[1] | 8–9 | `big` | size unit is `512 << (3 * big)`: 512 B, 4 KB, 32 KB, 256 KB |
| w[1] | 10–15 | `size` | approximate size = `(size + 1)` units, an upper bound |
| w[2] | 0–11 | `tag` | `key.slice32(2) & 0xfff` |
| w[2] | 12 | `phase` | the stripe phase when the fragment was written |
| w[2] | 13 | `head` | first Doc of an object (the one holding the alternate vector) |
| w[2] | 14 | `pinned` | |
| w[3] | 0–15 | `next` | next entry in the chain, as an index in the segment; 0 = end |
| w[4] | 0–15 | offset bits 24–39 | |

`offset` (40 bits) counts 512-byte blocks from the content start, plus one,
and 0 means empty. The fragment is at span byte
`start + (offset - 1) * 512` (`Stripe::vol_offset`).

Free entries reuse w[2] as `prev`, the back link of the segment's doubly
linked free list, so their tag and flag bits are meaningless.

### Buckets, chains and the free list

- `slice32(i)` is the i-th little-endian u32 of the 16-byte key.
- A key's segment is `slice32(0) % segments` and its bucket is
  `slice32(1) % buckets`. Its tag is `slice32(2) & 0xfff`
  (`Directory::probe`).
- Row 0 of each bucket (entry `bucket * 4`) is the chain head. An empty head
  (offset 0) means an empty bucket, and its `next` must be 0
  (`check_segment`).
- Rows 1–3 of every bucket form a pool shared by the whole segment.
  Entries in the pool are either chain links for any bucket or on the free
  list. The free list starts at the header's `freelist[segment]`; a fresh
  segment chains all rows 1–3 there (`init_segment`).
- A probe walks the bucket's chain and compares tags. Every tag match is a
  candidate, which the Doc's full key must then confirm.

### Validity (`Stripe::dir_valid`)

With `blk = offset - 1` and the header's `phase`, `write_pos` and `agg_pos`:

```
entry phase == header phase:  valid if blk <  (write_pos - start) / 512    # written this lap
entry phase != header phase:  valid if blk >= (agg_pos  - start) / 512     # last lap, not yet overwritten
```
ATS also counts its in-memory write buffer, which is empty offline. On
startup, ATS runs recovery (`handle_recover_from_data`) and may drop
entries near `write_pos` that were written after the last directory sync.
cyclone reports the directory as it is on disk.

Verified against the fixture: all 49 distinct cache keys have a head entry
at the bucket and tag their key predicts. In each stripe, the approximate
entry sizes add up exactly to how far `write_pos` advanced.

## Key → stripe

A key is stored in exactly one stripe, chosen through a 32707-slot table
(`build_vol_hash_table` in `CacheProcessor.cc`, `Cache::key_to_stripe` in
`Cache.cc`).

### Which stripes, in which order

The table belongs to a *host record*:

- **Generic record** (no `hosting.config` entries): every HTTP volume, in
  `cp_list` order. On a cache that already exists, `cplist_init` builds that
  order by walking spans in configuration order, and each span's stripe
  blocks in header order, adding each volume number the first time it
  appears.
- **`hosting.config` line or `@volume=` remap directive**: the listed
  volumes, in the order listed (`CacheHostRecord::Init`).
- **`proxy.config.cache.default_volumes`**: likewise a list of volumes.

Within a volume, stripes come in span order, and within a span in header
order (`Cache::open`). cyclone takes the list with `--volumes N,M,...`;
the default is the generic record.

### Building the table

```
for each stripe i:   requested[i] = 32707 * blocks_i / total_blocks     (+ remainder spread round-robin; informational)
                     points: len_i / 8 MB values of the LCG
                             x = x * 1103515145 + 12345 (u32), seeded with (u32) fold(hash_id_i)
sort all (value, stripe) points by value
width = 2^32 / 32707                                   # 131316
for slot j:          pos = width / 2 + j * width
                     advance to the first point with value >= pos (or the last point)
                     table[j] = that point's stripe
```
- `hash_id` is MD5 of the stripe's hash text (`"<seed> <offset>:<len>"`;
  see Span), or SHA-256 in FIPS builds.
- `fold()` XORs its 64-bit words; the low 32 bits seed the LCG.
- ATS sorts with `qsort`, which is not guaranteed stable. Equal values from
  two stripes are possible but vanishingly rare.

### Using it

```
slot   = (key.slice32(2) >> 12) % 32707
stripe = record.stripes[table[slot]]
```
Then the stripe's directory is probed as described under Directory.

Verified against the fixture (`tools/fixture/check.sh`): ATS logged
"requested 6542/6542/13082/6541, got 6780/6976/11036/7915", and
`cyc-lookup --table` reproduces it. All 49 URLs resolve to exactly one valid
head entry. With the wrong span seed, 20–28 of the 49 resolve to the wrong
stripe and miss, so `--seed` must match what ATS hashed.

## Doc (fragment header)

Every fragment in a stripe's content area starts with a `Doc`
(`src/iocore/cache/P_CacheDoc.h`), then `hlen` bytes of header, then data:
`len` bytes in all. The directory entry's approximate size is `len` rounded
up (`Stripe::round_to_approx_size`), so `len <= dir_approx_size`.

### Layout (72 bytes; 104 in FIPS builds)

| off | type | field | notes |
|---:|---|---|---|
| 0 | u32 | `magic` | `0x5F129B13` (`DOC_CORRUPT` `0xDEADBABE` is set in memory on a failed read) |
| 4 | u32 | `len` | this fragment, Doc included, unrounded |
| 8 | u64 | `total_len` | object length (see below) |
| 16 | key | `first_key` | the object's key; for HTTP the cache key of the URL |
| 32 | key | `key` | this fragment's key |
| 48 | u32 | `hlen` | header bytes after the Doc |
| 52 | u8 | `doc_type` | `CacheFragType`: 3 = HTTP |
| 53 | u8 | `v_major` | `CACHE_DB_MAJOR_VERSION` (24) |
| 54 | u8 | `v_minor` | `CACHE_DB_MINOR_VERSION` (3) |
| 55 | u8 | `unused` | 0 |
| 56 | u32 | `sync_serial` | |
| 60 | u32 | `write_serial` | |
| 64 | u32 | `pinned` | pinned-until time, 0 if not pinned |
| 68 | u32 | `checksum` | `DOC_NO_CHECKSUM` `0xA0B0C0D0` unless `proxy.config.cache.enable_checksum` |

Keys are `CryptoHash`: 16 bytes with MD5. In FIPS builds they are 32 bytes
(SHA-256), `first_key` stays at 16, and `key` moves to the end (offset 72),
so the fixed fields start at 48.

- `data_len = len - sizeof(Doc) - hlen` (0 if negative).
- The checksum is the sum, as C `char`, of the bytes from the end of the Doc
  to `len`: signed on x86, unsigned on ARM.
- A Doc newer than the running cache version is treated as corrupt
  (`CacheVC::handleReadDone`).
- The aggregator writes a *sync marker* when it flushes with nothing queued:
  a Doc with zero keys, no header or data, and `len` of one approximate unit.

### Which key an entry is filed under

`init_document` / `update_document_key` in `StripeSM.cc`:

- The **first write of an object** (`use_first_key`) is filed under
  `first_key`, marked head. For HTTP it carries the alternate vector in its
  header (`hlen > 0`). If the object fits, its data rides along and
  `data_len == total_len` (a *single-fragment* object). Its `key` is
  derived from the earliest key (`prev_CacheKey`), or random if it has no data.
- **Data fragments** are filed under their own `key`. Fragment 0 (the
  *earliest* fragment) is marked head too (`dir_set_head(!vc->fragment)`).
  Their `first_key` is still the object's key.
- When an **alternate** is added (Vary), the vector is rewritten under
  `first_key` with all alternates, carrying the new alternate's data if it
  fits (its `key` is then that alternate's earliest key). The earlier
  single-fragment Doc stays where it is, filed under its alternate's earliest
  key, and still serves that alternate's data. Its header still holds the
  old one-alternate vector.
- All of an object's Docs live in the stripe its `first_key` picks, whatever
  their own keys would pick (the read keeps the head's stripe). So a data
  fragment can only be looked up in its head's stripe.

So a lookup by a URL's key confirms a hit when the entry's Doc has
`first_key == key`, which is what `CacheVC::openReadStartHead` checks; a
mismatch is a tag collision and the probe goes on.

In the fixture, there are 56 head entries for 50 URLs: 50 vectors (each
filed under its URL's key), 4 earliest fragments of the 4 multi-fragment
objects, and the 2 original Docs of the 2 Vary objects
(`tools/fixture/check.sh`, check 5). Each multi-fragment object is a 2.4 KB
vector Doc plus 1 MiB data fragments.

## Alternates (`HTTPInfo`)

An HTTP head Doc's header (`hlen` bytes) is a `CacheHTTPInfoVector`: one
marshalled alternate after another until the header ends
(`CacheVC::unmarshal_http_info`). Each is a C++ struct copied byte for byte
(x86-64), with pointers turned into offsets. The offsets below are checked
against the compiled structs: `tools/ats-httpinfo/build.sh` writes
`src/testdata/hdr_layout.txt`, and a unit test compares
`src/format/http.zig` with it.

```
HTTPCacheAlt                 248 bytes (HTTP_ALT_MARSHAL_SIZE)
fragment offset table        u64 × count, only if count > 4
request HdrHeap              rounded up to 8
response HdrHeap             rounded up to 8
well-known-string identity   u64, only with magic MARSHALED_WKS
```

### `HTTPCacheAlt` (248 bytes, MD5 build)

| off | type | field | notes |
|---:|---|---|---|
| 0 | u32 | `m_magic` | `0xdcbadeee` MARSHALED_WKS (24.3+), `0xdcbadeed` MARSHALED (older) |
| 4 | i32 | `m_writeable` | 0 |
| 12 | i32 | `m_id` | |
| 16 | i32 | `m_rid` | |
| 20 | key | `m_object_key` | the alternate's earliest key: its first data fragment |
| 36 | i64 | `m_object_size` | as two i32 halves, low first |
| 48 | ptr | `m_request_hdr.m_heap` | offset of the request heap from the alternate, 0 if none |
| 112 | ptr | `m_response_hdr.m_heap` | same for the response |
| 176 | i64 | `m_request_sent_time` | Unix seconds |
| 184 | i64 | `m_response_received_time` | |
| 192 | i32 | `m_frag_offset_count` | number of fragments − 1 |
| 200 | ptr | `m_frag_offsets` | offset of the external table, used if count > 4 |
| 208 | u64×4 | `m_integral_frag_offsets` | used if count ≤ 4 |

Fragment offset *i* is the body offset where fragment *i+1* starts. In the
fixture every fragment holds 1048504 bytes of data (1 MiB less the Doc).

Before cache version 24.2 (`CACHE_DB_FRAG_OFFSET_TABLE_VERSION`), the external
table held only the offsets past the first 4, and the first 4 stayed in the
integral slots (`HTTPInfo::unmarshal_v24_1`). Those Docs also predate
MARSHALED_WKS. The offsets for a FIPS build (32-byte keys) are not verified, so
cyclone refuses to decode alternates with `--hash sha256`.

The bytes each part takes are summed the way ATS does: 248, plus the
external table, plus each heap rounded up to 8, plus the identity. The parts'
positions come from their offsets.

### `HdrHeap` (marshalled)

| off | type | field | notes |
|---:|---|---|---|
| 0 | u32 | `m_magic` | `0xdcbafeed` MARSHALED |
| 16 | ptr | `m_data_start` | 136, the end of this header |
| 24 | u32 | `m_size` | end of the object area |
| 28 | u8 | `m_writeable` | 0 |
| 40 | u32 | `m_free_size` | 0 |
| 64 | ptr | `m_ronly_heap[0].m_heap_start` | == `m_size`: the strings follow the objects |
| 72 | i32 | `m_ronly_heap[0].m_heap_len` | |

The heap is `m_size + m_heap_len` bytes. ATS checks it as above
(`HdrHeap::check_marshalled`). Every pointer inside it, to an object or a
string, is an offset from the heap's start. All strings are copied into the
heap; well-known strings are stored as strings too, so decoding needs no
token table. 24.3 objects carry the writer's table identity only so ATS can
rebuild its well-known-string indexes.

Objects follow each other from `m_data_start`, each starting with a u32
`HdrHeapObjImpl`: type in bits 0–7 (1 raw, 2 URL, 3 HTTP header, 4 MIME
header, 5 field block), length in bits 8–27. The first HTTP header object is
the header.

| object | field offsets |
|---|---|
| `HTTPHdrImpl` (48) | polarity i32 @4 (1 request, 2 response); version u8 major, u8 minor @8; request: URL ptr @16, method ptr @24, len u16 @32; response: reason ptr @16, len u16 @24, status i16 @26; fields (MIME header) ptr @40 |
| `URLImpl` (112) | u16 lengths @4.. and pointers @24.. for scheme, user, password, host, port, path, params, query, fragment |
| `MIMEHdrImpl` (592) | first field block inline @64 |
| `MIMEFieldBlockImpl` (528) | freetop u32 @4; next block ptr @8; 16 slots of 32 bytes @16 |
| `MIMEField` (32) | name ptr @0; value ptr @8; name len u16 @26; u32 @28: value len bits 0–23, readiness bits 28–29 (2 = live) |

The fields of a header are the live slots below `freetop` in each block of
the chain, in order. Deleted fields stay in their slots; ATS added `Via` to
the stored request and then deleted it, so it is in the string heap but not
in the header.

Verified on the fixture: `tools/ats-httpinfo/build.sh ATS_SRC BUILD FIXTURE`
decodes every head Doc with ATS's own `HTTPInfo::unmarshal`
(`alts_golden.txt`), and check 6 of `tools/fixture/check.sh` compares all 54
alternates field by field with `cyc-doc fragment`. That includes a 9-fragment
object, whose 8 offsets need the external table.

## Whole objects

How ATS reads an object (`CacheVC::openReadStartHead`,
`openReadStartEarliest`, `openReadReadDone` in `CacheRead.cc`), and how
`src/object.zig` follows it:

1. Find the head: probe the key's stripe and bucket; the first entry that is
   valid and whose Doc has `first_key == key` (a mismatch is a collision and
   the probe goes on).
2. Decode the alternates and pick one (ATS: `SelectFromAlternates` on the
   request, or 0 when `select_alternate` is off; cyclone: `--alt N`, default 0).
   ATS refuses the alternate if its response `Content-Length` differs from
   `object_size`.
3. `key = alternate.object_key`. If that is the head Doc's own `key`, the
   body is the head's data (a single-fragment object, `doc_pos = prefix_len`).
4. Otherwise probe for `key` **in the head's stripe**: the first valid entry
   whose Doc has `key == key`. Its data (after `prefix_len`) is the next part
   of the body. Then `key = next_CacheKey(key)` and repeat until
   `object_size` bytes are read. A missing fragment truncates the object
   (ATS logs "Document ... truncated" and deletes the earliest entry).
5. An object of size 0 reads no fragments.

`next_CacheKey` maps byte 0 through a 256-entry permutation table and each
later byte *i* through the table at `(next[i-1] + key[i]) & 0xff`
(`CacheKey_next_table`, `CacheDir.cc`); `prev_CacheKey` is its inverse. A
vector Doc written alone has `key = prev_CacheKey(earliest key)`.

The alternate's fragment offset table gives where each fragment after the
first starts in the body. ATS uses it to start a range read at the right
fragment; for a whole read it is a consistency check. In the fixture every
fragment but the last holds 1048504 bytes (1 MiB less the Doc); the last
holds the rest, here up to 1053251.

Verified on the fixture (`tools/fixture/check.sh`, check 7): for all 50
URLs, every alternate is complete and its body is byte for byte one the
origin sent for that URL, and every body sent is in some alternate. That
covers single-fragment objects, bodies in the head Doc, Vary alternates whose
body is in the original Doc, and 3- and 9-fragment objects.

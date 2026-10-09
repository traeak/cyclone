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

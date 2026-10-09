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

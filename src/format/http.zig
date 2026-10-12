//! Marshalled alternates (`HTTPCacheAlt` + two `HdrHeap`s), the header of an
//! HTTP head Doc. From ATS master src/proxy/hdrs/HTTP.cc (`HTTPInfo::marshal`,
//! `HTTPInfo::unmarshal`), HdrHeap.cc, MIME.cc and URL.cc.
//!
//! These are C++ structs copied byte for byte (x86-64 layout), with pointers
//! turned into offsets: an alternate's heap pointers are offsets from the
//! alternate, and every pointer inside a heap (objects and strings) is an
//! offset from that heap. The offsets below come from the compiled structs
//! (`tools/ats-httpinfo`, `src/testdata/hdr_layout.txt`) and a test checks
//! them.
//!
//! A Doc's header is a sequence of alternates (`CacheHTTPInfoVector`), each:
//!
//!   HTTPCacheAlt                 248 bytes
//!   frag offset table            only if more than 4 offsets (u64 each)
//!   request HdrHeap              rounded up to 8
//!   response HdrHeap             rounded up to 8
//!   well-known-string identity   u64, only with magic MARSHALED_WKS
//!
//! Strings are stored, never well-known-string indexes alone, so decoding
//! needs no token table.

const std = @import("std");
const hash = @import("../hash.zig");
const CacheKey = @import("../key.zig").CacheKey;

pub const alt_magic = struct {
    pub const alive = 0xabcddeed;
    pub const marshaled = 0xdcbadeed;
    /// Followed by the writer's well-known-string table identity (24.3+).
    pub const marshaled_wks = 0xdcbadeee;
    pub const dead = 0x0deadeed;
};
pub const heap_magic_marshaled = 0xdcbafeed;

/// Byte offsets in the marshalled structs (x86-64, MD5 keys).
pub const layout = struct {
    pub const alt_size = 248; // HTTP_ALT_MARSHAL_SIZE
    pub const alt_magic_at = 0;
    pub const alt_writeable = 4;
    pub const alt_id = 12;
    pub const alt_rid = 16;
    pub const alt_object_key = 20;
    pub const alt_object_size = 36;
    pub const alt_request_hdr = 48; // HTTPHdr; its m_heap is at 0
    pub const alt_response_hdr = 112;
    pub const alt_request_sent_time = 176;
    pub const alt_response_received_time = 184;
    pub const alt_frag_offset_count = 192;
    pub const alt_frag_offsets = 200;
    pub const alt_integral_frag_offsets = 208;
    pub const n_integral_frag_offsets = 4;

    pub const heap_hdr_size = 136; // HDR_HEAP_HDR_SIZE
    pub const heap_magic = 0;
    pub const heap_data_start = 16;
    pub const heap_size = 24;
    pub const heap_writeable = 28;
    pub const heap_free_size = 40;
    pub const heap_ronly_start = 56 + 8; // m_ronly_heap[0].m_heap_start
    pub const heap_ronly_len = 56 + 16; // m_ronly_heap[0].m_heap_len

    // HdrHeapObjImpl: u32 at 0, type bits 0-7, length bits 8-27.

    pub const http_size = 48;
    pub const http_polarity = 4;
    pub const http_version = 8; // u8 major, u8 minor
    pub const http_url = 16;
    pub const http_method = 24;
    pub const http_method_len = 32;
    pub const http_reason = 16;
    pub const http_reason_len = 24;
    pub const http_status = 26;
    pub const http_fields = 40;

    pub const mime_size = 592;
    pub const mime_first_fblock = 64;

    pub const fblock_size = 528;
    pub const fblock_freetop = 4;
    pub const fblock_next = 8;
    pub const fblock_slots = 16;
    pub const slots_per_block = 16;

    pub const field_size = 32;
    pub const field_name = 0;
    pub const field_value = 8;
    pub const field_len_name = 26;
    /// u32: len_value bits 0-23, readiness bits 28-29, flags bits 30-31.
    pub const field_bits = 28;
    pub const readiness_live = 2;

    pub const url_size = 112;
    /// m_len_* (u16) and m_ptr_* (pointer) of scheme, user, password, host,
    /// port, path, params, query, fragment, in that order.
    pub const url_len = 4;
    pub const url_ptr = 24;
};

pub const ObjType = enum(u8) {
    empty = 0,
    raw = 1,
    url = 2,
    http_header = 3,
    mime_header = 4,
    field_block = 5,
    _,
};

pub const Polarity = enum(i32) { unknown = 0, request = 1, response = 2, _ };

pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const Url = struct {
    scheme: []const u8 = "",
    user: []const u8 = "",
    password: []const u8 = "",
    host: []const u8 = "",
    port: []const u8 = "",
    path: []const u8 = "",
    params: []const u8 = "",
    query: []const u8 = "",
    fragment: []const u8 = "",

    /// The URL with each part present written out, as `url_print` does.
    pub fn format(u: Url, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (u.scheme.len != 0) try w.print("{s}://", .{u.scheme});
        if (u.user.len != 0) {
            try w.writeAll(u.user);
            if (u.password.len != 0) try w.print(":{s}", .{u.password});
            try w.writeByte('@');
        }
        try w.writeAll(u.host);
        if (u.port.len != 0) try w.print(":{s}", .{u.port});
        try w.print("/{s}", .{u.path});
        if (u.params.len != 0) try w.print(";{s}", .{u.params});
        if (u.query.len != 0) try w.print("?{s}", .{u.query});
        if (u.fragment.len != 0) try w.print("#{s}", .{u.fragment});
    }
};

pub const Header = struct {
    polarity: Polarity,
    version_major: u8,
    version_minor: u8,
    /// Request only.
    method: []const u8 = "",
    url: ?Url = null,
    /// Response only.
    status: i16 = 0,
    reason: []const u8 = "",
    /// Live fields in slot order, as ATS iterates them.
    fields: []const Field,

    /// First field with this name (case-insensitive).
    pub fn get(h: Header, name: []const u8) ?[]const u8 {
        for (h.fields) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
        return null;
    }
};

pub const Alternate = struct {
    magic: u32,
    id: i32,
    rid: i32,
    /// Key of the alternate's first data fragment (the earliest key).
    object_key: CacheKey,
    object_size: i64,
    request_sent_time: i64,
    response_received_time: i64,
    /// Byte offset in the body where fragment i+1 starts; one fewer than
    /// the number of fragments.
    frag_offsets: []const u64,
    request: ?Header,
    response: ?Header,
    /// The writer's well-known-string identity (magic MARSHALED_WKS only).
    wks_identity: ?u64,
    /// Bytes this alternate takes in the vector.
    marshal_len: usize,
};

pub const Error = error{
    /// The bytes end before the structure does.
    Truncated,
    BadAltMagic,
    BadHeapMagic,
    /// A heap header that fails ATS's `check_marshalled` tests.
    BadHeap,
    /// A pointer outside its heap, misaligned, or to the wrong object type.
    BadPointer,
    BadObject,
    NoHttpHeader,
    BadFragTable,
    /// Alternates are laid out for MD5 keys; the FIPS layout is unverified.
    UnsupportedHashType,
    OutOfMemory,
};

/// The first Doc version with a complete fragment offset table
/// (`CACHE_DB_FRAG_OFFSET_TABLE_VERSION`). Older Docs store only the offsets
/// past the 4 integral ones (`HTTPInfo::unmarshal_v24_1`).
pub fn fullFragTable(v_major: u8, v_minor: u8) bool {
    return v_major > 24 or (v_major == 24 and v_minor >= 2);
}

/// Decodes every alternate in a head Doc's header (`hlen` bytes), as
/// `CacheVC::unmarshal_http_info` walks them. Strings point into `buf`.
/// Allocates field lists and offset tables; pass an arena.
pub fn decodeVector(gpa: std.mem.Allocator, buf: []const u8, hash_type: hash.HashType, full_frag_table: bool) Error![]Alternate {
    var alts: std.ArrayList(Alternate) = .empty;
    errdefer alts.deinit(gpa);
    var at: usize = 0;
    while (at < buf.len) {
        if (buf.len - at < layout.alt_size) return error.Truncated;
        const alt = try decodeAlternate(gpa, buf[at..], hash_type, full_frag_table);
        try alts.append(gpa, alt);
        at += alt.marshal_len;
    }
    return alts.toOwnedSlice(gpa);
}

fn rd(comptime T: type, b: []const u8, at: usize) Error!T {
    if (at + @sizeOf(T) > b.len) return error.Truncated;
    return std.mem.readInt(T, b[at..][0..@sizeOf(T)], .little);
}

fn round8(n: usize) usize {
    return std.mem.alignForward(usize, n, 8);
}

/// One alternate at the start of `buf` (which may run on past it).
pub fn decodeAlternate(gpa: std.mem.Allocator, buf: []const u8, hash_type: hash.HashType, full_frag_table: bool) Error!Alternate {
    if (hash_type != .md5) return error.UnsupportedHashType;
    if (buf.len < layout.alt_size) return error.Truncated;
    const magic = try rd(u32, buf, layout.alt_magic_at);
    if (magic != alt_magic.marshaled and magic != alt_magic.marshaled_wks) return error.BadAltMagic;
    if (!full_frag_table and magic == alt_magic.marshaled_wks) return error.BadAltMagic;

    // `len` as ATS tracks it: what is left for this alternate's parts.
    var len: usize = buf.len - layout.alt_size;

    var key: CacheKey = .{ .hash_type = hash_type };
    @memcpy(key.bytes[0..16], buf[layout.alt_object_key..][0..16]);

    const count_raw = try rd(i32, buf, layout.alt_frag_offset_count);
    if (count_raw < 0) return error.BadFragTable;
    const count: usize = @intCast(count_raw);
    const n_int = layout.n_integral_frag_offsets;
    // m_frag_offsets holds the table's offset from the alternate.
    const table_at = try rd(u64, buf, layout.alt_frag_offsets);
    const stored = if (count <= n_int) 0 else if (full_frag_table) count else count - n_int;
    const size = stored * 8;
    if (stored != 0 and (size > len or table_at > buf.len or buf.len - table_at < size)) return error.BadFragTable;
    const frags = try gpa.alloc(u64, count);
    errdefer gpa.free(frags);
    if (count > n_int) {
        const first = count - stored;
        for (0..first) |i| frags[i] = try rd(u64, buf, layout.alt_integral_frag_offsets + i * 8);
        for (first..count) |i| frags[i] = try rd(u64, buf, table_at + (i - first) * 8);
        len -= size;
    } else {
        for (frags, 0..) |*f, i| f.* = try rd(u64, buf, layout.alt_integral_frag_offsets + i * 8);
    }

    var hdrs: [2]?Header = .{ null, null };
    for (&hdrs, [_]usize{ layout.alt_request_hdr, layout.alt_response_hdr }) |*h, field_at| {
        const heap_at = try rd(u64, buf, field_at);
        if (heap_at == 0) continue;
        if (heap_at >= buf.len) return error.BadPointer;
        const r = try decodeHeap(gpa, buf[heap_at..], len);
        h.* = r.header;
        // ATS lets `len` go negative here and fails later; stop now.
        if (r.consumed > len) return error.Truncated;
        len -= r.consumed;
    }

    var identity: ?u64 = null;
    if (magic == alt_magic.marshaled_wks) {
        if (len < 8) return error.Truncated;
        identity = try rd(u64, buf, buf.len - len);
        len -= 8;
    }

    return .{
        .magic = magic,
        .id = try rd(i32, buf, layout.alt_id),
        .rid = try rd(i32, buf, layout.alt_rid),
        .object_key = key,
        .object_size = try rd(i64, buf, layout.alt_object_size),
        .request_sent_time = try rd(i64, buf, layout.alt_request_sent_time),
        .response_received_time = try rd(i64, buf, layout.alt_response_received_time),
        .frag_offsets = frags,
        .request = hdrs[0],
        .response = hdrs[1],
        .wks_identity = identity,
        .marshal_len = buf.len - len,
    };
}

/// A marshalled heap at the start of `buf`: its bytes, and where its
/// objects end.
const Heap = struct {
    bytes: []const u8,
    data_start: usize,
    /// End of the object area (`m_size`); strings follow.
    objects_end: usize,

    fn objType(h: Heap, at: usize) Error!ObjType {
        return @fromBackingInt(@intCast(@as(u8, @truncate(try rd(u32, h.bytes, at)))));
    }

    fn objLen(h: Heap, at: usize) Error!usize {
        return (try rd(u32, h.bytes, at) >> 8) & 0xfffff;
    }

    /// Follows an object pointer stored at `at`: null, or the offset of an
    /// object of type `want` and at least `size` bytes inside the heap.
    fn obj(h: Heap, at: usize, want: ObjType, size: usize) Error!?usize {
        const p = try rd(u64, h.bytes, at);
        if (p == 0) return null;
        if (p < h.data_start or p % 8 != 0 or p > h.objects_end or h.objects_end - p < size) return error.BadPointer;
        if (try h.objType(p) != want) return error.BadPointer;
        return p;
    }

    /// A string: pointer at `ptr_at`, length `len`. A null pointer is "".
    fn str(h: Heap, ptr_at: usize, len: usize) Error![]const u8 {
        const p = try rd(u64, h.bytes, ptr_at);
        if (p == 0) return "";
        if (p > h.bytes.len or h.bytes.len - p < len) return error.BadPointer;
        return h.bytes[p..][0..len];
    }
};

/// `HdrHeap::unmarshal`: checks the heap and finds its HTTP header. `avail`
/// is ATS's remaining `len`; `consumed` is what the heap takes from it.
fn decodeHeap(gpa: std.mem.Allocator, buf: []const u8, avail: usize) Error!struct { header: Header, consumed: usize } {
    const L = layout;
    if (buf.len < L.heap_hdr_size) return error.Truncated;
    if (try rd(u32, buf, L.heap_magic) != heap_magic_marshaled) return error.BadHeapMagic;
    const size = try rd(u32, buf, L.heap_size);
    const ronly_start = try rd(u64, buf, L.heap_ronly_start);
    const ronly_len = try rd(i32, buf, L.heap_ronly_len);
    if (size < L.heap_hdr_size or size != ronly_start or ronly_len < 0) return error.BadHeap;
    const total = @as(usize, size) + @as(usize, @intCast(ronly_len));
    if (total > avail or total > buf.len) return error.BadHeap;
    if (buf[L.heap_writeable] != 0 or try rd(u32, buf, L.heap_free_size) != 0) return error.BadHeap;
    const data_start = try rd(u64, buf, L.heap_data_start);
    if (data_start < L.heap_hdr_size or data_start > size) return error.BadHeap;

    const h: Heap = .{ .bytes = buf[0..total], .data_start = data_start, .objects_end = size };

    // Walk the objects as unmarshal does; the first HTTP header is the one.
    var http: ?usize = null;
    var at: usize = data_start;
    while (at < size) {
        if (at % 8 != 0) return error.BadObject;
        const t = try h.objType(at);
        switch (t) {
            .empty, .raw, .url, .http_header, .mime_header, .field_block => {},
            _ => return error.BadObject,
        }
        if (t == .http_header and http == null) http = at;
        const n = try h.objLen(at);
        if (n == 0 or n > size - at) return error.BadObject;
        at += n;
    }
    const hp = http orelse return error.NoHttpHeader;
    if (size - hp < L.http_size) return error.BadObject;

    const polarity: Polarity = @fromBackingInt(@intCast(try rd(i32, buf, hp + L.http_polarity)));
    var header: Header = .{
        .polarity = polarity,
        .version_major = buf[hp + L.http_version],
        .version_minor = buf[hp + L.http_version + 1],
        .fields = &.{},
    };
    switch (polarity) {
        .request => {
            header.method = try h.str(hp + L.http_method, try rd(u16, buf, hp + L.http_method_len));
            if (try h.obj(hp + L.http_url, .url, L.url_size)) |u| header.url = try decodeUrl(h, u);
        },
        .response => {
            header.reason = try h.str(hp + L.http_reason, try rd(u16, buf, hp + L.http_reason_len));
            header.status = try rd(i16, buf, hp + L.http_status);
        },
        else => {},
    }
    if (try h.obj(hp + L.http_fields, .mime_header, L.mime_size)) |m| header.fields = try decodeFields(gpa, h, m);
    return .{ .header = header, .consumed = round8(total) };
}

fn decodeUrl(h: Heap, at: usize) Error!Url {
    var u: Url = .{};
    inline for (.{ "scheme", "user", "password", "host", "port", "path", "params", "query", "fragment" }, 0..) |name, i| {
        const len = try rd(u16, h.bytes, at + layout.url_len + 2 * i);
        @field(u, name) = try h.str(at + layout.url_ptr + 8 * i, len);
    }
    return u;
}

/// Live fields of a MIME header in slot order, over its chain of field
/// blocks (the first one inline).
fn decodeFields(gpa: std.mem.Allocator, h: Heap, mime: usize) Error![]const Field {
    const L = layout;
    var fields: std.ArrayList(Field) = .empty;
    errdefer fields.deinit(gpa);
    var block: ?usize = mime + L.mime_first_fblock;
    var blocks: usize = 0;
    while (block) |b| : (blocks += 1) {
        if (blocks > h.objects_end / L.fblock_size) return error.BadPointer; // a loop
        if (try h.objType(b) != .field_block) return error.BadObject;
        const freetop = try rd(u32, h.bytes, b + L.fblock_freetop);
        if (freetop > L.slots_per_block) return error.BadObject;
        for (0..freetop) |i| {
            const f = b + L.fblock_slots + i * L.field_size;
            const bits = try rd(u32, h.bytes, f + L.field_bits);
            if ((bits >> 28) & 3 != L.readiness_live) continue;
            try fields.append(gpa, .{
                .name = try h.str(f + L.field_name, try rd(u16, h.bytes, f + L.field_len_name)),
                .value = try h.str(f + L.field_value, bits & 0xffffff),
            });
        }
        block = try h.obj(b + L.fblock_next, .field_block, L.fblock_size);
    }
    return fields.toOwnedSlice(gpa);
}

test "layout matches the ATS build (src/testdata/hdr_layout.txt)" {
    const L = layout;
    const want = .{
        .{ "const HTTP_ALT_MARSHAL_SIZE", L.alt_size },
        .{ "field HTTPCacheAlt.m_magic", L.alt_magic_at },
        .{ "field HTTPCacheAlt.m_writeable", L.alt_writeable },
        .{ "field HTTPCacheAlt.m_id", L.alt_id },
        .{ "field HTTPCacheAlt.m_rid", L.alt_rid },
        .{ "field HTTPCacheAlt.m_object_key", L.alt_object_key },
        .{ "field HTTPCacheAlt.m_object_size", L.alt_object_size },
        .{ "field HTTPCacheAlt.m_request_hdr", L.alt_request_hdr },
        .{ "field HTTPCacheAlt.m_response_hdr", L.alt_response_hdr },
        .{ "field HTTPCacheAlt.m_request_sent_time", L.alt_request_sent_time },
        .{ "field HTTPCacheAlt.m_response_received_time", L.alt_response_received_time },
        .{ "field HTTPCacheAlt.m_frag_offset_count", L.alt_frag_offset_count },
        .{ "field HTTPCacheAlt.m_frag_offsets", L.alt_frag_offsets },
        .{ "field HTTPCacheAlt.m_integral_frag_offsets", L.alt_integral_frag_offsets },
        .{ "field HTTPHdr.m_heap", 0 },
        .{ "const HTTPCacheAlt::N_INTEGRAL_FRAG_OFFSETS", L.n_integral_frag_offsets },
        .{ "const HDR_HEAP_HDR_SIZE", L.heap_hdr_size },
        .{ "field HdrHeap.m_magic", L.heap_magic },
        .{ "field HdrHeap.m_data_start", L.heap_data_start },
        .{ "field HdrHeap.m_size", L.heap_size },
        .{ "field HdrHeap.m_writeable", L.heap_writeable },
        .{ "field HdrHeap.m_free_size", L.heap_free_size },
        .{ "field HdrHeap.m_ronly_heap", L.heap_ronly_start - 8 },
        .{ "field StrHeapDesc.m_heap_start", 8 },
        .{ "field StrHeapDesc.m_heap_len", 16 },
        .{ "bits HdrHeapObjImpl.m_type", "0 0 8" },
        .{ "bits HdrHeapObjImpl.m_length", "0 8 20" },
        .{ "const sizeof(HTTPHdrImpl)", L.http_size },
        .{ "field HTTPHdrImpl.m_polarity", L.http_polarity },
        .{ "field HTTPHdrImpl.m_version", L.http_version },
        .{ "field HTTPHdrImpl.u.req.m_url_impl", L.http_url },
        .{ "field HTTPHdrImpl.u.req.m_ptr_method", L.http_method },
        .{ "field HTTPHdrImpl.u.req.m_len_method", L.http_method_len },
        .{ "field HTTPHdrImpl.u.resp.m_ptr_reason", L.http_reason },
        .{ "field HTTPHdrImpl.u.resp.m_len_reason", L.http_reason_len },
        .{ "field HTTPHdrImpl.u.resp.m_status", L.http_status },
        .{ "field HTTPHdrImpl.m_fields_impl", L.http_fields },
        .{ "const sizeof(MIMEHdrImpl)", L.mime_size },
        .{ "field MIMEHdrImpl.m_first_fblock", L.mime_first_fblock },
        .{ "const sizeof(MIMEFieldBlockImpl)", L.fblock_size },
        .{ "const MIME_FIELD_BLOCK_SLOTS", L.slots_per_block },
        .{ "field MIMEFieldBlockImpl.m_freetop", L.fblock_freetop },
        .{ "field MIMEFieldBlockImpl.m_next", L.fblock_next },
        .{ "field MIMEFieldBlockImpl.m_field_slots", L.fblock_slots },
        .{ "const sizeof(MIMEField)", L.field_size },
        .{ "field MIMEField.m_ptr_name", L.field_name },
        .{ "field MIMEField.m_ptr_value", L.field_value },
        .{ "field MIMEField.m_len_name", L.field_len_name },
        .{ "bits MIMEField.m_len_value", "28 0 24" },
        .{ "bits MIMEField.m_readiness", "28 28 2" },
        .{ "const MIME_FIELD_SLOT_READINESS_LIVE", L.readiness_live },
        .{ "const sizeof(URLImpl)", L.url_size },
        .{ "field URLImpl.m_len_scheme", L.url_len },
        .{ "field URLImpl.m_len_fragment", L.url_len + 2 * 8 },
        .{ "field URLImpl.m_ptr_scheme", L.url_ptr },
        .{ "field URLImpl.m_ptr_fragment", L.url_ptr + 8 * 8 },
    };
    const text = @embedFile("../testdata/hdr_layout.txt");
    inline for (want) |w| {
        var found = false;
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, w[0] ++ " ")) continue;
            found = true;
            const rest = line[w[0].len + 1 ..];
            if (@TypeOf(w[1]) != comptime_int) {
                try std.testing.expectEqualStrings(w[1], rest);
            } else {
                var it = std.mem.splitScalar(u8, rest, ' ');
                const got = try std.fmt.parseInt(i64, it.next().?, 10);
                std.testing.expectEqual(@as(i64, w[1]), got) catch |err| {
                    std.debug.print("{s}\n", .{w[0]});
                    return err;
                };
            }
        }
        if (!found) {
            std.debug.print("missing from hdr_layout.txt: {s}\n", .{w[0]});
            return error.TestUnexpectedResult;
        }
    }
}

// Real vectors from the test fixture (tools/fixture): the header of a Vary
// object's head Doc (two alternates, Accept-Encoding gzip and none), of a
// 3 MB object's (three fragments), and of a 9 MB object's (nine fragments, so
// the offset table is stored after the alternate).
const vector_vary = @embedFile("../testdata/vector_vary.bin");
const vector_large = @embedFile("../testdata/vector_large.bin");
const vector_huge = @embedFile("../testdata/vector_huge.bin");

test "decode a two-alternate vector" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alts = try decodeVector(arena.allocator(), vector_vary, .md5, true);
    try std.testing.expectEqual(2, alts.len);
    try std.testing.expectEqual(vector_vary.len, alts[0].marshal_len + alts[1].marshal_len);
    for (alts, [_][]const u8{ "gzip", "none" }) |a, enc| {
        try std.testing.expectEqual(alt_magic.marshaled_wks, a.magic);
        try std.testing.expectEqual(1001, a.object_size);
        try std.testing.expectEqual(0, a.frag_offsets.len);
        const req = a.request.?;
        try std.testing.expectEqual(Polarity.request, req.polarity);
        try std.testing.expectEqualStrings("GET", req.method);
        try std.testing.expectEqualStrings("vary/1", req.url.?.path);
        try std.testing.expectEqualStrings("18081", req.url.?.port);
        try std.testing.expectEqualStrings("127.0.0.1:18081", req.get("host").?);
        const resp = a.response.?;
        try std.testing.expectEqual(200, resp.status);
        try std.testing.expectEqualStrings("OK", resp.reason);
        try std.testing.expectEqual(1, resp.version_major);
        try std.testing.expectEqual(1, resp.version_minor);
        try std.testing.expectEqualStrings("Accept-Encoding", resp.get("Vary").?);
        try std.testing.expectEqualStrings(enc, resp.get("X-Encoding").?);
    }
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("http://127.0.0.1:18081/vary/1", try std.fmt.bufPrint(&buf, "{f}", .{alts[0].request.?.url.?}));
}

test "decode fragment offsets" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alts = try decodeVector(arena.allocator(), vector_large, .md5, true);
    try std.testing.expectEqual(1, alts.len);
    try std.testing.expectEqual(3149827, alts[0].object_size);
    try std.testing.expectEqualSlices(u64, &.{ 1048504, 2097008 }, alts[0].frag_offsets);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("8a0f3dc24fd9dc5e0108227dd2df6a11", try std.fmt.bufPrint(&buf, "{f}", .{alts[0].object_key}));
}

test "decode an external fragment offset table" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alts = try decodeVector(arena.allocator(), vector_huge, .md5, true);
    try std.testing.expectEqual(1, alts.len);
    try std.testing.expectEqual(vector_huge.len, alts[0].marshal_len);
    try std.testing.expectEqual(9441283, alts[0].object_size);
    var want: [8]u64 = undefined;
    for (&want, 1..) |*w, i| w.* = i * (1024 * 1024 - 72);
    try std.testing.expectEqualSlices(u64, &want, alts[0].frag_offsets);
}

test "truncated and corrupted vectors fail cleanly" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Every truncation either errors or decodes fewer alternates.
    for (0..vector_vary.len) |n| {
        if (decodeVector(gpa, vector_vary[0..n], .md5, true)) |alts| {
            try std.testing.expect(alts.len < 2);
        } else |_| {}
    }

    // Random byte damage must never crash the decoder; any result is fine.
    var copy: [vector_vary.len]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const rand = prng.random();
    for (0..20000) |i| {
        const src: []const u8 = if (i % 2 == 0) vector_vary else vector_huge;
        @memcpy(copy[0..src.len], src);
        for (0..rand.intRangeAtMost(usize, 1, 8)) |_| {
            copy[rand.uintLessThan(usize, src.len)] = rand.int(u8);
        }
        _ = decodeVector(gpa, copy[0..src.len], .md5, true) catch {};
        _ = decodeVector(gpa, copy[0..src.len], .md5, false) catch {};
    }

    try std.testing.expectError(error.UnsupportedHashType, decodeVector(gpa, vector_vary, .sha256, true));
    // A 24.1 reader refuses MARSHALED_WKS, as ATS does.
    try std.testing.expectError(error.BadAltMagic, decodeVector(gpa, vector_vary, .md5, false));
}

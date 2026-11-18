//! Deterministic inputs for the benchmark suite: literal sets, corpora and
//! the pattern files the regex comparison reads. Every generator takes a
//! seed, so the same command produces the same bytes on every machine.

const std = @import("std");

pub const Rng = struct {
    s: u64,

    pub fn init(seed: u64) Rng {
        return .{ .s = (seed +% 1) *% 0x9E3779B97F4A7C15 | 1 };
    }

    pub fn next(r: *Rng) u64 {
        r.s ^= r.s << 13;
        r.s ^= r.s >> 7;
        r.s ^= r.s << 17;
        return r.s;
    }

    pub fn below(r: *Rng, n: u64) u64 {
        return r.next() % n;
    }

    /// A value in `lo..hi`, both inclusive.
    pub fn range(r: *Rng, lo: u64, hi: u64) u64 {
        return lo + r.below(hi - lo + 1);
    }
};

pub const words = [_][]const u8{
    "the",   "of",    "and",    "to",     "in",      "a",      "is",      "that",  "for",
    "it",    "as",    "was",    "with",   "be",      "by",     "on",      "not",   "he",
    "this",  "are",   "or",     "his",    "from",    "at",     "which",   "but",   "have",
    "an",    "had",   "they",   "you",    "were",    "their",  "one",     "all",   "we",
    "can",   "her",   "has",    "there",  "been",    "if",     "more",    "when",  "will",
    "would", "who",   "so",     "no",     "she",     "other",  "its",     "may",   "these",
    "about", "them",  "than",   "some",   "time",    "into",   "only",    "do",    "could",
    "new",   "after", "first",  "also",   "made",    "two",    "like",    "over",  "such",
    "most",  "where", "people", "before", "through", "should", "between", "under", "never",
};

/// What the literals are made of, and which corpus they are searched in.
pub const Family = enum {
    /// Lowercase ASCII letters, searched in English-like text.
    text,
    /// Any byte value, searched in executable-like binary data.
    binary,
};

pub const min_literal = 12;
pub const max_literal = 24;

/// A literal set: `n` strings of `min_literal` to `max_literal` bytes in
/// one allocation.
pub const LiteralSet = struct {
    store: []u8,
    items: [][]const u8,

    pub fn deinit(self: *LiteralSet, gpa: std.mem.Allocator) void {
        gpa.free(self.items);
        gpa.free(self.store);
        self.* = undefined;
    }

    pub fn totalBytes(self: *const LiteralSet) usize {
        return self.store.len;
    }
};

pub fn literalSet(gpa: std.mem.Allocator, family: Family, n: usize) !LiteralSet {
    var r: Rng = .init(0x11_7e_4a_15 ^ (@as(u64, n) << 8) ^ @backingInt(family));
    const items = try gpa.alloc([]const u8, n);
    errdefer gpa.free(items);
    const lens = try gpa.alloc(u8, n);
    defer gpa.free(lens);
    var total: usize = 0;
    for (lens) |*l| {
        l.* = @intCast(r.range(min_literal, max_literal));
        total += l.*;
    }
    const store = try gpa.alloc(u8, total);
    var off: usize = 0;
    for (items, lens) |*item, l| {
        const s = store[off..][0..l];
        for (s) |*c| c.* = switch (family) {
            .text => 'a' + @as(u8, @intCast(r.below(26))),
            .binary => @truncate(r.next()),
        };
        item.* = s;
        off += l;
    }
    return .{ .store = store, .items = items };
}

/// Average distance between planted needles in every corpus.
pub const plant_every = 4096;

const Planter = struct {
    r: Rng,
    plants: []const []const u8,
    next_at: usize,

    fn init(seed: u64, plants: []const []const u8) Planter {
        var r: Rng = .init(seed);
        const first = r.range(plant_every / 2, plant_every * 3 / 2);
        return .{ .r = r, .plants = plants, .next_at = first };
    }

    /// The next needle to plant when `pos` has reached the next planting
    /// point, cycling through the plants.
    fn due(p: *Planter, pos: usize) ?[]const u8 {
        if (p.plants.len == 0 or pos < p.next_at) return null;
        p.next_at = pos + p.r.range(plant_every / 2, plant_every * 3 / 2);
        // Spread over the whole set without favouring the first entries.
        const k = p.r.below(p.plants.len);
        return p.plants[k];
    }
};

/// Appends bytes until `len`, dropping whatever would overflow.
const Filler = struct {
    buf: []u8,
    len: usize = 0,

    fn full(f: *const Filler) bool {
        return f.len == f.buf.len;
    }

    fn put(f: *Filler, bytes: []const u8) void {
        const n = @min(bytes.len, f.buf.len - f.len);
        @memcpy(f.buf[f.len..][0..n], bytes[0..n]);
        f.len += n;
    }

    fn byte(f: *Filler, b: u8) void {
        if (f.len < f.buf.len) {
            f.buf[f.len] = b;
            f.len += 1;
        }
    }
};

/// English-like words separated by spaces and newlines, with a needle from
/// `plants` every `plant_every` bytes on average.
pub fn textCorpus(gpa: std.mem.Allocator, len: usize, seed: u64, plants: []const []const u8) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    var f: Filler = .{ .buf = buf };
    var r: Rng = .init(seed);
    var planter: Planter = .init(seed ^ 0xfeed, plants);
    while (!f.full()) {
        if (planter.due(f.len)) |p| f.put(p) else f.put(words[r.below(words.len)]);
        f.byte(if (r.below(12) == 0) '\n' else ' ');
    }
    return buf;
}

/// Executable-like bytes: zero padding, high-entropy code, ASCII strings,
/// little-endian integer tables and 0xcc/0x90 padding, with a needle from
/// `plants` every `plant_every` bytes on average.
pub fn binaryCorpus(gpa: std.mem.Allocator, len: usize, seed: u64, plants: []const []const u8) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    var f: Filler = .{ .buf = buf };
    var r: Rng = .init(seed);
    var planter: Planter = .init(seed ^ 0xbeef, plants);
    while (!f.full()) {
        if (planter.due(f.len)) |p| f.put(p);
        switch (r.below(8)) {
            0, 1 => for (0..r.range(16, 512)) |_| f.byte(0),
            2, 3, 4 => for (0..r.range(64, 1024)) |_| f.byte(@truncate(r.next())),
            5 => for (0..r.range(1, 6)) |_| {
                f.put(words[r.below(words.len)]);
                f.byte(if (r.below(3) == 0) ' ' else 0);
            },
            6 => for (0..r.range(8, 64)) |_| {
                var le: [4]u8 = undefined;
                std.mem.writeInt(u32, &le, @intCast(r.below(4096)), .little);
                f.put(&le);
            },
            else => {
                const pad: u8 = if (r.below(2) == 0) 0xcc else 0x90;
                for (0..r.range(4, 64)) |_| f.byte(pad);
            },
        }
    }
    return buf;
}

const http_paths = [_][]const u8{ "/", "/index.php", "/api/items", "/search", "/login", "/static/app.js", "/user/profile", "/cart/add", "/wp-admin/admin-ajax.php", "/download" };
const http_agents = [_][]const u8{
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0",
    "curl/8.7.1",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36",
};

fn putWord(f: *Filler, r: *Rng) void {
    f.put(words[r.below(words.len)]);
}

fn putHex(f: *Filler, r: *Rng, n: usize) void {
    const digits = "0123456789abcdef";
    for (0..n) |_| f.byte(digits[r.below(16)]);
}

fn putNumber(f: *Filler, r: *Rng) void {
    var tmp: [20]u8 = undefined;
    f.put(std.fmt.bufPrint(&tmp, "{d}", .{r.below(100000)}) catch unreachable);
}

/// HTTP/1.1 requests (query strings, headers, form and JSON bodies) with a
/// needle from `plants` every `plant_every` bytes on average, placed in a
/// parameter value the way an attack payload arrives.
pub fn httpCorpus(gpa: std.mem.Allocator, len: usize, seed: u64, plants: []const []const u8) ![]u8 {
    const buf = try gpa.alloc(u8, len);
    var f: Filler = .{ .buf = buf };
    var r: Rng = .init(seed);
    var planter: Planter = .init(seed ^ 0xcafe, plants);
    while (!f.full()) {
        const plant = planter.due(f.len);
        const kind = r.below(3);
        f.put(if (kind == 0) "GET " else "POST ");
        f.put(http_paths[r.below(http_paths.len)]);
        if (kind == 0) {
            for (0..r.range(1, 4)) |k| {
                f.byte(if (k == 0) '?' else '&');
                putWord(&f, &r);
                f.byte('=');
                if (k == 0 and plant != null) f.put(plant.?) else putWord(&f, &r);
            }
        }
        f.put(" HTTP/1.1\r\nHost: shop.example.test\r\nUser-Agent: ");
        f.put(http_agents[r.below(http_agents.len)]);
        f.put("\r\nAccept: text/html,application/json;q=0.9,*/*;q=0.8\r\nAccept-Language: en-US,en;q=0.5\r\nCookie: session=");
        putHex(&f, &r, 32);
        f.put("; theme=dark\r\n");
        switch (kind) {
            1 => {
                f.put("Content-Type: application/x-www-form-urlencoded\r\n\r\n");
                for (0..r.range(2, 6)) |k| {
                    if (k > 0) f.byte('&');
                    putWord(&f, &r);
                    f.byte('=');
                    if (k == 0 and plant != null) f.put(plant.?) else {
                        putWord(&f, &r);
                        f.byte('+');
                        putWord(&f, &r);
                    }
                }
                f.put("\r\n");
            },
            2 => {
                f.put("Content-Type: application/json\r\n\r\n{\"name\":\"");
                if (plant) |p| f.put(p) else putWord(&f, &r);
                f.put("\",\"count\":");
                putNumber(&f, &r);
                f.put(",\"tags\":[\"");
                putWord(&f, &r);
                f.put("\",\"");
                putWord(&f, &r);
                f.put("\"]}\r\n");
            },
            else => f.put("\r\n"),
        }
    }
    return buf;
}

/// One pattern of a pattern file.
pub const PatternLine = struct {
    name: []const u8,
    case_insensitive: bool,
    dot_all: bool,
    pattern: []const u8,
    /// A string the pattern matches, planted in the corpus.
    sample: []const u8,
};

/// Parse a pattern file: one `name<TAB>flags<TAB>pattern<TAB>sample` per
/// line, where flags is `-` or any of `i` (ASCII case-insensitive) and `s`
/// (dot matches newline), and the sample takes `\xHH`, `\\`, `\t`, `\r` and
/// `\n` escapes. `#` starts a comment line. Slices point into `text` and
/// into `arena`.
pub fn parsePatternFile(arena: std.mem.Allocator, text: []const u8) ![]PatternLine {
    var out: std.ArrayList(PatternLine) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const name = fields.next() orelse return error.BadPatternFile;
        const flags = fields.next() orelse return error.BadPatternFile;
        const pattern = fields.next() orelse return error.BadPatternFile;
        const sample = fields.next() orelse return error.BadPatternFile;
        if (fields.next() != null) return error.BadPatternFile;
        var entry: PatternLine = .{
            .name = name,
            .case_insensitive = false,
            .dot_all = false,
            .pattern = pattern,
            .sample = try unescape(arena, sample),
        };
        if (!std.mem.eql(u8, flags, "-")) for (flags) |c| switch (c) {
            'i' => entry.case_insensitive = true,
            's' => entry.dot_all = true,
            else => return error.BadPatternFile,
        };
        try out.append(arena, entry);
    }
    return out.toOwnedSlice(arena);
}

fn unescape(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '\\') {
            try out.append(arena, s[i]);
            continue;
        }
        i += 1;
        if (i == s.len) return error.BadPatternFile;
        switch (s[i]) {
            '\\' => try out.append(arena, '\\'),
            't' => try out.append(arena, '\t'),
            'r' => try out.append(arena, '\r'),
            'n' => try out.append(arena, '\n'),
            'x' => {
                if (i + 2 >= s.len) return error.BadPatternFile;
                try out.append(arena, try std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16));
                i += 2;
            },
            else => return error.BadPatternFile,
        }
    }
    return out.toOwnedSlice(arena);
}

/// The corpus a pattern file is searched in.
pub const RegexCorpus = enum { binary, http };

pub const regex_corpus_len = 8 << 20;

pub fn regexCorpus(gpa: std.mem.Allocator, kind: RegexCorpus, lines: []const PatternLine) ![]u8 {
    const plants = try gpa.alloc([]const u8, lines.len);
    defer gpa.free(plants);
    for (lines, plants) |l, *p| p.* = l.sample;
    return switch (kind) {
        .binary => binaryCorpus(gpa, regex_corpus_len, 0xc1a5, plants),
        .http => httpCorpus(gpa, regex_corpus_len, 0xc25, plants),
    };
}

test "parse a pattern file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const lines = try parsePatternFile(arena_state.allocator(), "# comment\na\tis\t\\x00.b\t\\x00zb\n\nc\t-\tc+\tcc\n");
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expect(lines[0].case_insensitive and lines[0].dot_all);
    try std.testing.expectEqualSlices(u8, "\x00zb", lines[0].sample);
    try std.testing.expect(!lines[1].case_insensitive);
}

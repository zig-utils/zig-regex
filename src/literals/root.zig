//! Multi-literal search engines shared by zig-anti-virus (signature
//! prefiltering) and zig-waf (`@pm` phrase matching).
//!
//! - `Teddy`: SIMD search for up to 64 literals.
//! - `AhoCorasick`: binary-safe automaton for any number of literals, with
//!   all-matches and leftmost-longest search and streaming.
//!
//! Every engine is built once into a relocatable little-endian blob that can
//! be written out, mmapped read-only and searched in place. Searching never
//! allocates.

const std = @import("std");

pub const types = @import("types.zig");
pub const Pattern = types.Pattern;
pub const Match = types.Match;
pub const Options = types.Options;

pub const blob = @import("blob.zig");
pub const LoadError = blob.LoadError;
pub const simd = @import("simd.zig");

pub const teddy = @import("teddy.zig");
pub const Teddy = teddy.Teddy;

pub const aho_corasick = @import("aho_corasick.zig");
pub const AhoCorasick = aho_corasick.AhoCorasick;

/// Naive reference matchers used as the oracle by the differential tests.
pub const naive = @import("naive.zig");

test {
    std.testing.refAllDecls(@This());
}

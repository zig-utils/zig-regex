//! Rust `regex` crate counterpart to benchmarks/findall_throughput.zig.
//!
//! Reads a haystack from stdin, compiles the pattern, runs one warmup, then
//! times N iterations of counting all matches. Prints `total iterations
//! elapsed_ns` to stdout — the same format the Zig program emits — so
//! benchmarks/compare.sh can compare them head-to-head.

use std::io::Read;
use std::time::Instant;
use regex::Regex;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let pattern = args.get(1).expect("usage: rust-bench <pattern> [iterations]");
    let iterations: usize = args.get(2).and_then(|s| s.parse().ok()).unwrap_or(1);

    let mut haystack = String::new();
    std::io::stdin().read_to_string(&mut haystack).unwrap();

    let re = Regex::new(pattern).unwrap();
    let _ = re.find_iter(&haystack).count(); // warmup

    let start = Instant::now();
    let mut total = 0usize;
    for _ in 0..iterations {
        total += re.find_iter(&haystack).count();
    }
    let elapsed = start.elapsed();

    println!("{} {} {}", total, iterations, elapsed.as_nanos());
}

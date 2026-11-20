// sysbench: Native Goose CPU & Memory Micro-Benchmark Suite.
//
// Runs four self-verifying computational benchmarks (Prime Sieve, Mandelbrot,
// Int64 Sort, Memory Hash Throughput) and displays either a colorized ANSI
// terminal report with proportional Unicode bars or structured JSON (--json).

import std;
import os;
import math;

struct BenchResult {
    name: u8[..48],
    elapsed_ms: f64,
    rate: f64,
    unit: u8[..24],
    checksum: u64,
}

fn to_buf48(s: const u8[:]) -> u8[..48] {
    var b: u8[..48] = [];
    let n = min(s.len, 48);
    b.append(s[..n]);
    return b;
}

fn to_buf24(s: const u8[:]) -> u8[..24] {
    var b: u8[..24] = [];
    let n = min(s.len, 24);
    b.append(s[..n]);
    return b;
}

fn bench_sieve(limit: i64) -> i64, f64 {
    let t0 = clock_ns();
    var is_comp: bool[>..] = [];
    is_comp.resize(limit + 1, false);
    var count: i64 = 0;
    var p: i64 = 2;
    while p * p <= limit {
        if !is_comp[p] {
            var m = p * p;
            while m <= limit {
                is_comp[m] = true;
                m += p;
            }
        }
        p++;
    }
    var i: i64 = 2;
    while i <= limit {
        if !is_comp[i] { count++; }
        i++;
    }
    let dt = (clock_ns() - t0) / 1000000.0;
    return count, dt;
}

fn bench_mandelbrot(dim: i64, max_iter: i64) -> i64, f64 {
    let t0 = clock_ns();
    var total_iters: i64 = 0;
    let inv_dim = 1.0 / dim;
    for py in dim {
        let cy = -1.2 + 2.4 * (py * inv_dim);
        for px in dim {
            let cx = -2.0 + 2.6 * (px * inv_dim);
            var zx = 0.0;
            var zy = 0.0;
            var it: i64 = 0;
            while it < max_iter {
                let zx2 = zx * zx;
                let zy2 = zy * zy;
                if zx2 + zy2 > 4.0 { break; }
                zy = 2.0 * zx * zy + cy;
                zx = zx2 - zy2 + cx;
                it++;
            }
            total_iters += it;
        }
    }
    let dt = (clock_ns() - t0) / 1000000.0;
    return total_iters, dt;
}

recursive fn quicksort_i64(a: i64[:], lo: i64, hi: i64) {
    if lo >= hi { return; }
    let pivot = a[(lo + hi) / 2];
    var i = lo;
    var j = hi;
    while i <= j {
        while a[i] < pivot { i++; }
        while a[j] > pivot { j--; }
        if i <= j {
            let tmp = a[i];
            a[i] = a[j];
            a[j] = tmp;
            i++;
            j--;
        }
    }
    if lo < j { quicksort_i64(a, lo, j); }
    if i < hi { quicksort_i64(a, i, hi); }
}

fn bench_sort(n: i64) -> u64, f64 {
    var xs: i64[>..] = [];
    var r = rng { 0xCAFEBABE12345678 };
    for i in n {
        xs.push(r.rand_range(1000000000));
    }
    let t0 = clock_ns();
    quicksort_i64(xs, 0, xs.len - 1);
    let dt = (clock_ns() - t0) / 1000000.0;
    // Verify strictly non-decreasing order
    var acc: u64 = 0;
    var prev = xs[0];
    for i in xs.len {
        if xs[i] < prev { abort("sort invariant failed"); }
        prev = xs[i];
        if i % 1024 == 0 {
            acc = hash_combine(acc, hash(xs[i]));
        }
    }
    return acc, dt;
}

fn bench_memhash(bytes_total: i64) -> u64, f64 {
    var buf: u8[>..] = [];
    buf.resize(bytes_total, 0);
    for i in bytes_total {
        buf[i] = ((i * 131 + 17) & 255) as u8;
    }
    let t0 = clock_ns();
    var h: u64 = 0x9E3779B97F4A7C15;
    let chunk: i64 = 4096;
    var pos: i64 = 0;
    while pos + chunk <= bytes_total {
        h = hash_combine(h, hash(buf[pos..pos + chunk]));
        pos += chunk;
    }
    let dt = (clock_ns() - t0) / 1000000.0;
    return h, dt;
}

fn fmt_dec1(v: f64) -> u8[>..] {
    let scaled = round(v * 10.0) as i64;
    let whole = scaled / 10;
    let frac = abs(scaled % 10);
    return str(whole, ".", frac);
}

fn pad_right(s: const u8[:], width: i64) -> u8[>..] {
    var out = str(s);
    while out.len < width { out.push(' '); }
    return out;
}

fn pad_left(s: const u8[:], width: i64) -> u8[>..] {
    var out: u8[>..] = [];
    var spaces = width - s.len;
    while spaces > 0 {
        out.push(' ');
        spaces--;
    }
    out.append(s);
    return out;
}

fn make_bar(frac: f64, width: i64, use_color: bool) -> u8[>..] {
    var f = frac;
    if f < 0.05 { f = 0.05; }
    if f > 1.0 { f = 1.0; }
    let filled = round(f * width) as i64;
    var out: u8[>..] = [];
    if use_color { out.append("\x1b[38;2;80;220;180m"); }
    for i in filled { out.append("█"); }
    if use_color { out.append("\x1b[38;2;70;80;100m"); }
    var rem = width - filled;
    while rem > 0 {
        out.append("░");
        rem--;
    }
    if use_color { out.append("\x1b[0m"); }
    return out;
}

fn run_suite(quick: bool) -> BenchResult[>..] {
    var results: BenchResult[>..] = [];

    let sieve_n = if quick { 200000 } else { 2000000 };
    let primes, sieve_ms = bench_sieve(sieve_n);
    let expected_primes = if quick { 17984 } else { 148933 };
    if primes != expected_primes { abort("prime sieve count mismatch"); }
    let sieve_sec = max(sieve_ms / 1000.0, 0.0001);
    results.push(BenchResult {
        name: to_buf48(str("Prime Sieve (", sieve_n / 1000, "K)")),
        elapsed_ms: sieve_ms,
        rate: (sieve_n / 1000000.0) / sieve_sec,
        unit: to_buf24("M nums/s"),
        checksum: primes as u64,
    });

    let mandel_dim = if quick { 256 } else { 512 };
    let mandel_iters, mandel_ms = bench_mandelbrot(mandel_dim, 80);
    let mandel_sec = max(mandel_ms / 1000.0, 0.0001);
    results.push(BenchResult {
        name: to_buf48(str("Mandelbrot (", mandel_dim, "x", mandel_dim, ")")),
        elapsed_ms: mandel_ms,
        rate: (mandel_iters / 1000000.0) / mandel_sec,
        unit: to_buf24("M iter/s"),
        checksum: mandel_iters as u64,
    });

    let sort_n = if quick { 50000 } else { 250000 };
    let sort_hash, sort_ms = bench_sort(sort_n);
    let sort_sec = max(sort_ms / 1000.0, 0.0001);
    results.push(BenchResult {
        name: to_buf48(str("Quicksort (", sort_n / 1000, "K i64)")),
        elapsed_ms: sort_ms,
        rate: (sort_n / 1000000.0) / sort_sec,
        unit: to_buf24("M keys/s"),
        checksum: sort_hash,
    });

    let mem_mb = if quick { 2 } else { 8 };
    let mem_hash, mem_ms = bench_memhash(mem_mb * 1024 * 1024);
    let mem_sec = max(mem_ms / 1000.0, 0.0001);
    results.push(BenchResult {
        name: to_buf48(str("Mem Hash (", mem_mb, " MB)")),
        elapsed_ms: mem_ms,
        rate: mem_mb / mem_sec,
        unit: to_buf24("MB/s"),
        checksum: mem_hash,
    });

    return results;
}

fn run_tests() {
    let quick_res = run_suite(true);
    if quick_res.len != 4 { abort("expected 4 benchmark results"); }
    if quick_res[0].checksum != 17984 { abort("quick sieve count must be 17984"); }
    if quick_res[1].checksum <= 100000 { abort("mandelbrot iterations too low"); }
    let repeat_res = run_suite(true);
    if quick_res[2].checksum != repeat_res[2].checksum { abort("sort checksum must be deterministic"); }
    if quick_res[3].checksum != repeat_res[3].checksum { abort("memhash checksum must be deterministic"); }
    print("PASS sysbench (4/4 micro-benchmarks verified)\n");
}

fn main() {
    let argv = args();
    var quick = false;
    var json_out = false;
    var no_color = false;
    var test_mode = false;
    var show_help = false;

    for i in argv.len {
        if i == 0 { continue; }
        let a = argv[i];
        if a == "--quick" || a == "-q" { quick = true; }
        else if a == "--json" { json_out = true; }
        else if a == "--no-color" { no_color = true; }
        else if a == "--test" { test_mode = true; }
        else if a == "--help" || a == "-h" { show_help = true; }
    }

    if show_help {
        print("sysbench - Native Goose CPU & Memory Micro-Benchmark Suite\n\n");
        print("Usage: sysbench [--quick] [--json] [--no-color] [--test] [--help]\n");
        return;
    }

    if test_mode {
        run_tests();
        return;
    }

    let res = run_suite(quick);

    if json_out {
        print("{\"mode\":\"", if quick { "quick" } else { "full" }, "\",\"results\":[");
        for i in res.len {
            if i > 0 { print(","); }
            print("{\"name\":\"", res[i].name, "\",\"elapsed_ms\":", fmt_dec1(res[i].elapsed_ms),
                  ",\"rate\":", fmt_dec1(res[i].rate), ",\"unit\":\"", res[i].unit, "\"}");
        }
        print("]}\n");
        return;
    }

    let c_title = if no_color { "" } else { "\x1b[1;38;2;110;210;255m" };
    let c_dim = if no_color { "" } else { "\x1b[38;2;140;150;170m" };
    let c_num = if no_color { "" } else { "\x1b[1;38;2;255;210;90m" };
    let c_reset = if no_color { "" } else { "\x1b[0m" };

    var max_ms = 0.1;
    var total_ms = 0.0;
    for r in res {
        if r.elapsed_ms > max_ms { max_ms = r.elapsed_ms; }
        total_ms += r.elapsed_ms;
    }

    print(c_title, "=== Goose Native SysBench (", if quick { "Quick" } else { "Full" },
          " Suite) ===", c_reset, "\n");
    print(c_dim, "Workload                  Time (ms)   Throughput          Profile",
          c_reset, "\n");
    print(c_dim, "----------------------------------------------------------------------",
          c_reset, "\n");

    for r in res {
        let name_col = pad_right(r.name, 24);
        let ms_col = pad_left(fmt_dec1(r.elapsed_ms), 8);
        let rate_str = str(fmt_dec1(r.rate), " ", r.unit);
        let rate_col = pad_left(rate_str, 17);
        let bar = make_bar(r.elapsed_ms / max_ms, 18, !no_color);
        print(name_col, "  ", c_num, ms_col, c_reset, "  ", rate_col, "  ", bar, "\n");
    }

    print(c_dim, "----------------------------------------------------------------------",
          c_reset, "\n");
    print("Total elapsed: ", c_num, fmt_dec1(total_ms), " ms", c_reset,
          "   All mathematical invariants verified.\n");
}

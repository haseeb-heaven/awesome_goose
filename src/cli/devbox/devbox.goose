// devbox: Multi-tool Developer CLI powered by Goose & goose-uuid.
//
// Subcommands:
//   devbox uuid [--v4|--v7] [-n COUNT]
//   devbox pass [-l LENGTH] [-n COUNT] [--no-symbols]
//   devbox b64 encode <text> | decode <text>
//   devbox hash <text>
//   devbox stats <file>
//   devbox demo | --test | --help

import std;
import os;
import math;
import base64;
import uuid from "github.com/Macho0x/goose-uuid@v0.4";
import uuid.uuid4;
import uuid.uuid7;

fn hex_u64(v: u64) -> u8[>..] {
    var out: u8[>..] = [];
    let hex = "0123456789abcdef";
    var shift = 60;
    while shift >= 0 {
        let nib = ((v >> shift) & 15) as i64;
        out.push(hex[nib]);
        shift -= 4;
    }
    return out;
}

fn gen_password(length: i64, use_symbols: bool) -> u8[>..], f64 {
    let alpha = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    let syms = "!@#$%^&*-_+=?";
    var charset = str(alpha);
    if use_symbols { charset.append(syms); }

    var rnd: u8[>..] = [];
    rnd.resize(length * 2, 0);
    if !random_bytes(rnd) {
        var r = rng { random_seed() };
        for i in rnd.len { rnd[i] = (r.rand_u64() & 255) as u8; }
    }

    var pw: u8[>..] = [];
    var idx = 0;
    let m = charset.len;
    let limit = 256 - (256 % m);
    while pw.len < length {
        if idx >= rnd.len {
            if !random_bytes(rnd) {
                var r = rng { random_seed() };
                for i in rnd.len { rnd[i] = (r.rand_u64() & 255) as u8; }
            }
            idx = 0;
        }
        let b = rnd[idx] as i64;
        idx++;
        if b < limit {
            pw.push(charset[b % m]);
        }
    }
    let entropy = length * (if use_symbols { 6.22 } else { 5.95 });
    return pw, entropy;
}

struct FileStats {
    bytes: i64,
    lines: i64,
    words: i64,
    longest_line: i64,
    non_ascii: i64,
}

fn analyze_bytes(data: const u8[:]) -> FileStats {
    var st = FileStats { bytes: data.len, lines: 0, words: 0, longest_line: 0, non_ascii: 0 };
    if data.len == 0 { return st; }
    var cur_line: i64 = 0;
    var in_word = false;
    st.lines = 1;
    for i in data.len {
        let b = data[i];
        if b >= 128 { st.non_ascii++; }
        if b == '\n' {
            if cur_line > st.longest_line { st.longest_line = cur_line; }
            cur_line = 0;
            if i + 1 < data.len { st.lines++; }
            in_word = false;
        } else {
            cur_line++;
            let is_ws = b == ' ' || b == '\t' || b == '\r';
            if is_ws {
                in_word = false;
            } else if !in_word {
                st.words++;
                in_word = true;
            }
        }
    }
    if cur_line > st.longest_line { st.longest_line = cur_line; }
    return st;
}

fn print_help() {
    print("devbox - Developer Swiss-Army CLI in Goose\n\n");
    print("Commands:\n");
    print("  uuid [--v4|--v7] [-n COUNT]        Generate RFC 9562 UUIDs\n");
    print("  pass [-l LEN] [-n COUNT] [--no-symbols]  Generate secure passwords\n");
    print("  b64 encode <text> | decode <text>  Base64 encode or decode\n");
    print("  hash <text>                        64-bit Goose hash in hex\n");
    print("  stats <file>                       Analyze file lines/words/bytes\n");
    print("  demo                               Showcase all tools in one view\n");
    print("  --test                             Run self-tests\n");
}

fn check(ok: bool, msg: const u8[:]) {
    if !ok { abort(msg); }
}

fn run_tests() {
    // 1. UUIDv4 & UUIDv7 via goose-uuid
    let u4 = uuid4::new();
    var s4 = str(u4);
    check(s4.len == 36 && s4[14] == '4', "invalid UUIDv4 format");

    let u7, ok7 = uuid7::new();
    check(ok7, "uuid7::new failed");
    var s7 = str(u7);
    check(s7.len == 36 && s7[14] == '7', "invalid UUIDv7 format");

    // 2. Base64 roundtrip
    var enc: u8[>..] = [];
    let msg = "Goose systems language 2026!";
    base64::encode(enc, msg);
    var dec: u8[>..] = [];
    let dec_ok = base64::decode(dec, enc);
    check(dec_ok && dec == msg, "base64 roundtrip mismatch");

    // 3. Password generation
    let pw1, ent1 = gen_password(20, true);
    let pw2, ent2 = gen_password(16, false);
    check(pw1.len == 20 && ent1 > 100.0, "password length/entropy mismatch");
    check(pw2.len == 16 && ent2 > 80.0, "alphanumeric password mismatch");

    // 4. Deterministic 64-bit hash
    let h1 = hex_u64(hash("heaven_goose"));
    let h2 = hex_u64(hash("heaven_goose"));
    check(h1.len == 16 && h1 == h2, "hash must be deterministic 16-hex");

    // 5. File stats analyzer
    let st = analyze_bytes("alpha beta\ngamma\n");
    check(st.bytes == 17 && st.lines == 2 && st.words == 3 && st.longest_line == 10,
          "file stats mismatch");

    print("PASS devbox (UUIDv4, UUIDv7, Base64, Password, Hash, Stats)\n");
}

fn run_demo(use_color: bool) {
    let c_hdr = if use_color { "\x1b[1;38;2;120;210;255m" } else { "" };
    let c_lbl = if use_color { "\x1b[38;2;150;235;165m" } else { "" };
    let c_dim = if use_color { "\x1b[38;2;140;150;170m" } else { "" };
    let rst = if use_color { "\x1b[0m" } else { "" };

    print(c_hdr, "=== devbox — Goose Developer Toolkit ===", rst, "\n\n");

    let u4 = uuid4::new();
    let u7, _ = uuid7::new();
    print(c_lbl, "$ devbox uuid --v4", rst, "  -> ", u4, "\n");
    print(c_lbl, "$ devbox uuid --v7", rst, "  -> ", u7, "\n");

    let pw, ent = gen_password(24, true);
    print(c_lbl, "$ devbox pass -l 24", rst, " -> ", pw, c_dim, " (~", round(ent) as i64,
          " bits entropy)", rst, "\n");

    let sample = "Heaven Goose Toolkit";
    var b64_out: u8[>..] = [];
    base64::encode(b64_out, sample);
    print(c_lbl, "$ devbox b64 encode", rst, " -> ", b64_out, "\n");
    print(c_lbl, "$ devbox hash", rst, "       -> 0x", hex_u64(hash(sample)), "\n");

    let st = analyze_bytes("fn main() {\n    print(\"Hello from Goose!\");\n}\n");
    print(c_lbl, "$ devbox stats", rst, "      -> ", st.lines, " lines, ", st.words, " words, ",
          st.bytes, " bytes (max width ", st.longest_line, ")\n");
}

fn main() {
    let argv = args();
    var no_color = false;
    var filtered: u8[:][>..] = [];
    for i in argv.len {
        if i == 0 { continue; }
        if argv[i] == "--no-color" { no_color = true; }
        else { filtered.push(argv[i]); }
    }

    if filtered.len == 0 || filtered[0] == "--help" || filtered[0] == "-h" {
        print_help();
        return;
    }

    let cmd = filtered[0];
    if cmd == "--test" {
        run_tests();
        return;
    }
    if cmd == "demo" {
        run_demo(!no_color);
        return;
    }

    let c_ok = if no_color { "" } else { "\x1b[1;38;2;120;230;160m" };
    let c_rst = if no_color { "" } else { "\x1b[0m" };

    if cmd == "uuid" {
        var use_v7 = false;
        var count: i64 = 1;
        var i = 1;
        while i < filtered.len {
            if filtered[i] == "--v7" { use_v7 = true; }
            else if filtered[i] == "--v4" { use_v7 = false; }
            else if filtered[i] == "-n" && i + 1 < filtered.len {
                let n, ok = parse_int(filtered[i + 1]);
                if ok && n > 0 && n <= 100 { count = n; }
                i++;
            }
            i++;
        }
        for _ in count {
            if use_v7 {
                let u, ok = uuid7::new();
                if !ok { write_stderr("error: uuid7 clock failed\n"); exit(1); }
                print(c_ok, u, c_rst, "\n");
            } else {
                print(c_ok, uuid4::new(), c_rst, "\n");
            }
        }
        return;
    }

    if cmd == "pass" {
        var length: i64 = 20;
        var count: i64 = 1;
        var syms = true;
        var i = 1;
        while i < filtered.len {
            if filtered[i] == "--no-symbols" { syms = false; }
            else if filtered[i] == "-l" && i + 1 < filtered.len {
                let n, ok = parse_int(filtered[i + 1]);
                if ok && n >= 4 && n <= 256 { length = n; }
                i++;
            } else if filtered[i] == "-n" && i + 1 < filtered.len {
                let n, ok = parse_int(filtered[i + 1]);
                if ok && n > 0 && n <= 50 { count = n; }
                i++;
            }
            i++;
        }
        for _ in count {
            let pw, ent = gen_password(length, syms);
            print(c_ok, pw, c_rst, "  (", round(ent) as i64, " bits)\n");
        }
        return;
    }

    if cmd == "b64" {
        if filtered.len < 3 {
            write_stderr("usage: devbox b64 <encode|decode> <text>\n");
            exit(2);
        }
        let mode = filtered[1];
        let payload = filtered[2];
        var out: u8[>..] = [];
        if mode == "encode" {
            base64::encode(out, payload);
            print(out, "\n");
        } else if mode == "decode" {
            if !base64::decode(out, payload) {
                write_stderr("error: invalid base64 input\n");
                exit(1);
            }
            print(out, "\n");
        } else {
            write_stderr("error: expected encode or decode\n");
            exit(2);
        }
        return;
    }

    if cmd == "hash" {
        if filtered.len < 2 {
            write_stderr("usage: devbox hash <text>\n");
            exit(2);
        }
        print("0x", hex_u64(hash(filtered[1])), "\n");
        return;
    }

    if cmd == "stats" {
        if filtered.len < 2 {
            write_stderr("usage: devbox stats <file>\n");
            exit(2);
        }
        var data: u8[>..] = [];
        if !read_file(filtered[1], data) {
            write_stderr(str("error: cannot read ", filtered[1], "\n"));
            exit(1);
        }
        let st = analyze_bytes(data);
        print("file: ", filtered[1], "\n");
        print("bytes: ", st.bytes, "  lines: ", st.lines, "  words: ", st.words,
              "  max_line: ", st.longest_line, "  non_ascii: ", st.non_ascii, "\n");
        return;
    }

    write_stderr(str("unknown command: ", cmd, "\n"));
    exit(2);
}

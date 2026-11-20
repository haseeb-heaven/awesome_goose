// sysmon: Real-Time Terminal UI System Monitor in Goose + goose-tui.
//
// Features:
//   - Live per-core & aggregate CPU usage, User/Sys breakdown, and Unicode sparkline graph
//   - Activity-Monitor-accurate RAM breakdown (App, Wired, Compressed, Cached, Free) + Swap
//   - Mounted disk/volume storage bars with Free & Used capacity
//   - Interactive scrollable Process table sortable by Memory, CPU Time, or PID
//   - 24-bit TrueColor rendering with Cyber Dark & Nord themes + zero-flicker cell diffing
//   - CLI flags: --once (plain summary), --ansi-dump (rendered screenshot frame), --test

import std;
import os;
import math;
import tui from "github.com/ZHENGSY/goose-tui@v0.1.0";

extern fn probe_hostname(out: u8[:]) -> i64;
extern fn probe_os_name(out: u8[:]) -> i64;
extern fn probe_cpu_model(out: u8[:]) -> i64;
extern fn probe_sys_meta(out: i64[:]) -> i64;
extern fn probe_cpu_ticks(out: i64[:]) -> i64;
extern fn probe_memory(out: i64[:]) -> i64;
extern fn probe_disks(mounts_out: u8[:], stats_out: i64[:], max_disks: i64) -> i64;
extern fn probe_top_procs(names_out: u8[:], stats_out: i64[:], max_procs: i64, sort_mode: i64) -> i64;

let MAX_CORES: i64 = 32;
let MAX_DISKS: i64 = 8;
let MAX_PROCS: i64 = 32;
let MAX_HIST: i64 = 44;

let SORT_MEM: i64 = 0;
let SORT_CPU: i64 = 1;
let SORT_PID: i64 = 2;

struct DiskInfo {
    mount: u8[..32],
    total: i64,
    used: i64,
    avail: i64,
}

struct ProcInfo {
    pid: i64,
    name: u8[..32],
    rss: i64,
    threads: i64,
    cpu_ms: i64,
}

struct SysSnapshot {
    hostname: u8[..64],
    os_name: u8[..64],
    cpu_model: u8[..64],
    logical_cpus: i64,
    physical_cpus: i64,
    uptime_s: i64,
    total_procs: i64,
    load1: f64,
    load5: f64,
    load15: f64,
    core_count: i64,
    prev_ticks: i64[128],
    core_pct: f64[32],
    total_cpu_pct: f64,
    user_cpu_pct: f64,
    sys_cpu_pct: f64,
    has_prev_ticks: bool,
    hist: f64[44],
    hist_len: i64,
    ram_total: i64,
    ram_used: i64,
    ram_app: i64,
    ram_wired: i64,
    ram_compressed: i64,
    ram_cached: i64,
    ram_free: i64,
    swap_total: i64,
    swap_used: i64,
    disk_count: i64,
    disks: DiskInfo[8],
    proc_count: i64,
    procs: ProcInfo[32],
}

struct MonState {
    sort_mode: i64,
    theme_idx: i64,
    paused: bool,
    rate_ms: i64,
    last_poll_ms: i64,
    tbl: tui::TableState,
}

fn check(ok: bool, msg: const u8[:]) {
    if !ok { abort(msg); }
}

fn to_buf32(s: const u8[:]) -> u8[..32] {
    var out: u8[..32] = [];
    out.append(s[..min(s.len, 32)]);
    return out;
}

fn to_buf64(s: const u8[:]) -> u8[..64] {
    var out: u8[..64] = [];
    out.append(s[..min(s.len, 64)]);
    return out;
}

fn read_slot32(buf: const u8[:], idx: i64) -> u8[..32] {
    var out: u8[..32] = [];
    let off = idx * 32;
    for k in 32 {
        let b = buf[off + k];
        if b == 0 { break; }
        out.push(b);
    }
    return out;
}

fn format_two(v: i64) -> u8[>..] {
    let clamped = max(0, v % 100);
    if clamped < 10 { return str("0", clamped); }
    return str(clamped);
}

fn format_fixed1(val: f64) -> u8[>..] {
    let scaled = round(max(0.0, val) * 10.0) as i64;
    let whole = scaled / 10;
    let frac = scaled % 10;
    return str(whole, ".", frac);
}

fn format_bytes(bytes: i64) -> u8[>..] {
    let b = max(0, bytes);
    let kib: i64 = 1024;
    let mib: i64 = 1024 * 1024;
    let gib: i64 = 1024 * 1024 * 1024;
    let tib: i64 = 1024 * 1024 * 1024 * 1024;
    if b >= tib { return str(format_fixed1((b * 1.0) / tib), " TiB"); }
    if b >= gib { return str(format_fixed1((b * 1.0) / gib), " GiB"); }
    if b >= mib { return str(format_fixed1((b * 1.0) / mib), " MiB"); }
    if b >= kib { return str(b / kib, " KiB"); }
    return str(b, " B");
}

fn format_pct(p: f64) -> u8[>..] {
    let clamped = clamp(p, 0.0, 100.0);
    return str(format_fixed1(clamped), "%");
}

fn format_uptime(sec: i64) -> u8[>..] {
    let s = max(0, sec);
    let days = s / 86400;
    let hrs = (s % 86400) / 3600;
    let mins = (s % 3600) / 60;
    let secs = s % 60;
    if days > 0 {
        return str(days, "d ", format_two(hrs), "h ", format_two(mins), "m");
    }
    return str(format_two(hrs), ":", format_two(mins), ":", format_two(secs));
}

fn format_cpu_time(ms: i64) -> u8[>..] {
    let total_ds = max(0, ms) / 100;
    let mins = total_ds / 600;
    let secs = (total_ds / 10) % 60;
    let ds = total_ds % 10;
    if mins >= 60 {
        return str(mins / 60, "h ", format_two(mins % 60), "m");
    }
    return str(format_two(mins), ":", format_two(secs), ".", ds);
}

fn compute_cpu_deltas(prev: const i64[:], cur: const i64[:], core_cnt: i64,
                      out_pct: f64[:]) -> f64, f64, f64 {
    var sum_user: i64 = 0;
    var sum_sys: i64 = 0;
    var sum_idle: i64 = 0;
    var sum_tot: i64 = 0;

    for i in core_cnt {
        let off = i * 4;
        let du = max(0, cur[off + 0] - prev[off + 0]);
        let ds = max(0, cur[off + 1] - prev[off + 1]);
        let di = max(0, cur[off + 2] - prev[off + 2]);
        let dn = max(0, cur[off + 3] - prev[off + 3]);
        let dtot = du + ds + di + dn;
        let dbusy = du + ds + dn;
        out_pct[i] = if dtot > 0 { clamp((dbusy * 100.0) / dtot, 0.0, 100.0) } else { 0.0 };
        sum_user += du + dn;
        sum_sys += ds;
        sum_idle += di;
        sum_tot += dtot;
    }

    if sum_tot <= 0 {
        return 0.0, 0.0, 0.0;
    }
    let u_pct = clamp((sum_user * 100.0) / sum_tot, 0.0, 100.0);
    let s_pct = clamp((sum_sys * 100.0) / sum_tot, 0.0, 100.0);
    let tot_pct = clamp(((sum_tot - sum_idle) * 100.0) / sum_tot, 0.0, 100.0);
    return tot_pct, u_pct, s_pct;
}

fn push_cpu_hist(s: SysSnapshot&, pct: f64) {
    if s.hist_len < MAX_HIST {
        s.hist[s.hist_len] = pct;
        s.hist_len++;
    } else {
        for i in MAX_HIST - 1 {
            s.hist[i] = s.hist[i + 1];
        }
        s.hist[MAX_HIST - 1] = pct;
    }
}

fn sample_system(s: SysSnapshot&, sort_mode: i64) {
    var meta: i64[8] = [0; 8];
    let _ = probe_sys_meta(meta);
    s.logical_cpus = max(1, meta[0]);
    s.physical_cpus = max(1, meta[1]);
    s.uptime_s = meta[2];
    s.total_procs = meta[7];
    s.load1 = meta[4] / 100.0;
    s.load5 = meta[5] / 100.0;
    s.load15 = meta[6] / 100.0;

    // CPU per-core tick delta
    var cur_ticks: i64[128] = [0; 128];
    let nc = clamp(probe_cpu_ticks(cur_ticks), 0, MAX_CORES);
    s.core_count = nc;
    if !s.has_prev_ticks && nc > 0 {
        for i in nc * 4 { s.prev_ticks[i] = cur_ticks[i]; }
        sleep_ms(60);
        let nc2 = clamp(probe_cpu_ticks(cur_ticks), 0, MAX_CORES);
        s.core_count = nc2;
        s.has_prev_ticks = true;
    }
    if s.core_count > 0 && s.has_prev_ticks {
        let tot_p, u_p, sys_p = compute_cpu_deltas(s.prev_ticks, cur_ticks, s.core_count, s.core_pct);
        s.total_cpu_pct = tot_p;
        s.user_cpu_pct = u_p;
        s.sys_cpu_pct = sys_p;
        for i in s.core_count * 4 { s.prev_ticks[i] = cur_ticks[i]; }
        push_cpu_hist(s, tot_p);
    }

    // Memory & Swap
    var mem: i64[9] = [0; 9];
    let _ = probe_memory(mem);
    s.ram_total = mem[0];
    s.ram_used = mem[1];
    s.ram_app = mem[2];
    s.ram_wired = mem[3];
    s.ram_compressed = mem[4];
    s.ram_cached = mem[5];
    s.ram_free = mem[6];
    s.swap_total = mem[7];
    s.swap_used = mem[8];

    // Mounted Disks
    var mnt_buf: u8[256] = [0; 256];
    var d_stats: i64[24] = [0; 24];
    let dc = clamp(probe_disks(mnt_buf, d_stats, MAX_DISKS), 0, MAX_DISKS);
    s.disk_count = dc;
    for i in dc {
        s.disks[i] = DiskInfo {
            mount: read_slot32(mnt_buf, i),
            total: d_stats[i * 3 + 0],
            used: d_stats[i * 3 + 1],
            avail: d_stats[i * 3 + 2],
        };
    }

    // Top Processes
    var pnames: u8[1024] = [0; 1024];
    var pstats: i64[128] = [0; 128];
    let pc = clamp(probe_top_procs(pnames, pstats, MAX_PROCS, sort_mode), 0, MAX_PROCS);
    s.proc_count = pc;
    for i in pc {
        s.procs[i] = ProcInfo {
            pid: pstats[i * 4 + 0],
            name: read_slot32(pnames, i),
            rss: pstats[i * 4 + 1],
            threads: pstats[i * 4 + 2],
            cpu_ms: pstats[i * 4 + 3],
        };
    }
}

fn new_snapshot() -> SysSnapshot {
    var hbuf: u8[64] = [0; 64];
    var obuf: u8[64] = [0; 64];
    var cbuf: u8[64] = [0; 64];
    let hlen = probe_hostname(hbuf);
    let olen = probe_os_name(obuf);
    let clen = probe_cpu_model(cbuf);

    var s = SysSnapshot {
        hostname: to_buf64(hbuf[..hlen]),
        os_name: to_buf64(obuf[..olen]),
        cpu_model: to_buf64(cbuf[..clen]),
        logical_cpus: 1,
        physical_cpus: 1,
        uptime_s: 0,
        total_procs: 0,
        load1: 0.0,
        load5: 0.0,
        load15: 0.0,
        core_count: 0,
        prev_ticks: [0; 128],
        core_pct: [0.0; 32],
        total_cpu_pct: 0.0,
        user_cpu_pct: 0.0,
        sys_cpu_pct: 0.0,
        has_prev_ticks: false,
        hist: [0.0; 44],
        hist_len: 0,
        ram_total: 0,
        ram_used: 0,
        ram_app: 0,
        ram_wired: 0,
        ram_compressed: 0,
        ram_cached: 0,
        ram_free: 0,
        swap_total: 0,
        swap_used: 0,
        disk_count: 0,
        disks: [default<DiskInfo>(); 8],
        proc_count: 0,
        procs: [default<ProcInfo>(); 32],
    };
    sample_system(s, SORT_MEM);
    return s;
}

fn thermal_color(pct: f64, th: tui::Theme) -> u32 {
    if pct >= 80.0 { return th.err; }
    if pct >= 55.0 { return th.warn; }
    return th.ok;
}

fn draw_bar(cv: tui::Canvas&, x: i32, y: i32, w: i32, frac: f64, fill_col: u32, bg: u32,
            dim_col: u32) {
    if w <= 0 { return; }
    let f = clamp(frac, 0.0, 1.0);
    let filled = (round(f * w) as i32);
    let on_st = tui::style(fill_col, bg);
    let off_st = tui::style(dim_col, bg);
    for i in w {
        let ch: u32 = if i < filled { 0x2588 } else { 0x2591 }; // █ vs ░
        tui::put(cv, x + i, y, ch, if i < filled { on_st } else { off_st });
    }
}

fn pad_left(s: const u8[:], width: i64) -> u8[>..] {
    var out: u8[>..] = [];
    var n = width - s.len;
    while n > 0 {
        out.push(' ');
        n--;
    }
    out.append(s);
    return out;
}

fn sort_label(mode: i64) -> const u8[:] {
    if mode == SORT_CPU { return "CPU"; }
    if mode == SORT_PID { return "PID"; }
    return "MEM";
}

fn get_mon_theme(idx: i64) -> tui::Theme {
    if idx % 2 == 1 { return tui::theme_nord(); }
    var t = tui::theme_dark();
    t.bg = tui::rgb(11, 14, 22);
    t.panel_bg = tui::rgb(17, 22, 34);
    t.border = tui::rgb(52, 74, 112);
    t.border_focus = tui::rgb(86, 182, 246);
    t.title = tui::rgb(125, 211, 252);
    t.accent = tui::rgb(56, 189, 248);
    t.ok = tui::rgb(52, 211, 153);
    t.warn = tui::rgb(251, 191, 36);
    t.err = tui::rgb(248, 113, 113);
    return t;
}

fn short_host(h: const u8[:]) -> const u8[:] {
    let dot = find(h, ".local");
    if dot > 0 && dot + 6 == h.len { return h[..dot]; }
    return h;
}

fn draw_sysmon(s: const SysSnapshot&, mon: MonState&, cv: tui::Canvas&) {
    let th = get_mon_theme(mon.theme_idx);
    let bg = th.panel_bg;
    let st_txt = tui::style(th.fg, bg);
    let st_dim = tui::style(th.dim, bg);
    let st_acc = tui::bold(tui::style(th.accent, bg));

    tui::fill_rect(cv, tui::rect(0, 0, cv.w, cv.h), ' ', tui::style(th.fg, th.bg));

    let top_r, rest1 = tui::split_v(tui::rect(0, 0, cv.w, max(1, cv.h - 1)), 3);
    let mid_h = min(10, max(6, rest1.h / 2 - 1));
    let cpu_mem_r, rest2 = tui::split_v(rest1, mid_h);
    let want_disk_h = clamp(s.disk_count + 2, 3, 5) as i32;
    let disk_h = min(want_disk_h, max(3, rest2.h - 5));
    let disk_r, proc_r = tui::split_v(rest2, disk_h);

    // 1. Header Banner
    let hdr_in = tui::panel(cv, top_r, " HEAVEN SYSMON ", th);
    let left_hdr = str(short_host(s.hostname), " · ", s.os_name);
    let right_hdr = str("Up ", format_uptime(s.uptime_s), " · Load ",
                        format_fixed1(s.load1), " ", format_fixed1(s.load5), " ",
                        format_fixed1(s.load15), " · ", s.total_procs, " procs");
    let rw = tui::text_width(right_hdr);
    tui::ellipsis(cv, tui::rect(hdr_in.x + 1, hdr_in.y, max(1, hdr_in.w - rw - 3), 1),
                  hdr_in.x + 1, hdr_in.y, left_hdr, st_acc);
    let _ = tui::draw_text_right(cv, tui::rect(hdr_in.x, hdr_in.y, max(1, hdr_in.w - 1), 1),
                                 hdr_in.y, right_hdr, st_txt);

    // 2. Split CPU & Memory Panels
    let cpu_box, mem_box = tui::split_hw(cpu_mem_r, 1, 2);
    let cpu_title = str(" CPU: ", s.cpu_model, " (", s.physical_cpus, "P/", s.logical_cpus, "L) ");
    let cpu_in = tui::panel(cv, cpu_box, cpu_title[..min(cpu_title.len, max(12, cpu_box.w - 4))], th);

    if cpu_in.h >= 3 && cpu_in.w >= 20 {
        let cpu_col = thermal_color(s.total_cpu_pct, th);
        let right_cpu = str(format_pct(s.total_cpu_pct), "  U:", round(s.user_cpu_pct) as i64,
                            "% S:", round(s.sys_cpu_pct) as i64, "%");
        let _ = tui::draw_text(cv, cpu_in, cpu_in.x + 1, cpu_in.y, "Total", tui::bold(st_txt));
        let bar_w = max(6, cpu_in.w - 9 - tui::text_width(right_cpu));
        draw_bar(cv, cpu_in.x + 7, cpu_in.y, bar_w, s.total_cpu_pct / 100.0, cpu_col, bg, th.border);
        let _ = tui::draw_text_right(cv, tui::rect(cpu_in.x, cpu_in.y, cpu_in.w - 1, 1),
                                     cpu_in.y, right_cpu, tui::bold(tui::style(cpu_col, bg)));

        // Sparkline History row
        let _ = tui::draw_text(cv, cpu_in, cpu_in.x + 1, cpu_in.y + 1, "Graph", st_dim);
        if s.hist_len > 0 && cpu_in.w > 10 {
            let sp_w = max(4, cpu_in.w - 9);
            let h_slice = s.hist[..s.hist_len];
            tui::spark(cv, tui::rect(cpu_in.x + 7, cpu_in.y + 1, sp_w, 1), h_slice, th);
        }

        // Per-core mini bars (2 columns up to 10 cores, or 3 columns for 11..16 cores)
        let core_rows = max(0, cpu_in.h - 3);
        let cols_n: i32 = if s.core_count > (core_rows as i64) * 2 { 3 } else { 2 };
        let col_w = max(10, (cpu_in.w - 2) / cols_n);
        let max_show = min(s.core_count, (core_rows as i64) * cols_n);
        for ci in max_show {
            let r_off = (ci / cols_n) as i32;
            let c_off = (ci % cols_n) as i32;
            let cx = cpu_in.x + 1 + c_off * col_w;
            let cy = cpu_in.y + 3 + r_off;
            let cpct = s.core_pct[ci];
            let cc = thermal_color(cpct, th);
            let lbl = str("C", format_two(ci));
            let pct_s = pad_left(str(round(cpct) as i64, "%"), 4);
            let _ = tui::draw_text(cv, cpu_in, cx, cy, lbl, st_dim);
            let mb_w = max(3, col_w - 10);
            draw_bar(cv, cx + 4, cy, mb_w, cpct / 100.0, cc, bg, th.border);
            let _ = tui::draw_text(cv, cpu_in, cx + 4 + mb_w + 1, cy, pct_s, tui::style(cc, bg));
        }
    }

    // 3. Memory & Swap Panel
    let mem_in = tui::panel(cv, mem_box, " Memory & Swap ", th);
    if mem_in.h >= 5 && mem_in.w >= 24 {
        let ram_pct = if s.ram_total > 0 { (s.ram_used * 100.0) / s.ram_total } else { 0.0 };
        let ram_col = thermal_color(ram_pct, th);
        let ram_info = str(format_bytes(s.ram_used), " / ", format_bytes(s.ram_total));
        let _ = tui::draw_text(cv, mem_in, mem_in.x + 1, mem_in.y, "RAM ", tui::bold(st_txt));
        let rbar_w = max(6, mem_in.w - 8 - tui::text_width(ram_info));
        draw_bar(cv, mem_in.x + 6, mem_in.y, rbar_w, ram_pct / 100.0, ram_col, bg, th.border);
        let _ = tui::draw_text_right(cv, tui::rect(mem_in.x, mem_in.y, mem_in.w - 1, 1),
                                     mem_in.y, ram_info, tui::bold(tui::style(ram_col, bg)));

        let row1 = str("Used: ", format_pct(ram_pct), "   Free: ", format_bytes(s.ram_free));
        let _ = tui::draw_text(cv, mem_in, mem_in.x + 1, mem_in.y + 1, row1, st_dim);

        let row2 = str("App: ", format_bytes(s.ram_app), "  Wired: ", format_bytes(s.ram_wired));
        let _ = tui::draw_text(cv, mem_in, mem_in.x + 1, mem_in.y + 2, row2, st_txt);

        let row3 = str("Comp: ", format_bytes(s.ram_compressed), "  Cached: ", format_bytes(s.ram_cached));
        let _ = tui::draw_text(cv, mem_in, mem_in.x + 1, mem_in.y + 3, row3, st_txt);

        tui::hr(cv, mem_in, mem_in.y + 4, tui::style(th.border, bg));

        if mem_in.h >= 6 {
            let sw_pct = if s.swap_total > 0 { (s.swap_used * 100.0) / s.swap_total } else { 0.0 };
            let sw_col = thermal_color(sw_pct, th);
            let sw_info = if s.swap_total > 0 {
                str(format_bytes(s.swap_used), " / ", format_bytes(s.swap_total))
            } else {
                str("0 B / 0 B (Inactive)")
            };
            let _ = tui::draw_text(cv, mem_in, mem_in.x + 1, mem_in.y + 5, "Swap", tui::bold(st_txt));
            let sbar_w = max(6, mem_in.w - 8 - tui::text_width(sw_info));
            draw_bar(cv, mem_in.x + 6, mem_in.y + 5, sbar_w, sw_pct / 100.0, sw_col, bg, th.border);
            let _ = tui::draw_text_right(cv, tui::rect(mem_in.x, mem_in.y + 5, mem_in.w - 1, 1),
                                         mem_in.y + 5, sw_info, tui::style(sw_col, bg));
        }

        if mem_in.h >= 8 {
            let meta_line = str("Sort: ", sort_label(mon.sort_mode), "   Rate: ",
                                format_fixed1(mon.rate_ms / 1000.0), "s   Theme: ",
                                if mon.theme_idx % 2 == 1 { "Nord" } else { "Cyber Dark" });
            let _ = tui::draw_text(cv, mem_in, mem_in.x + 1, mem_in.y + 7, meta_line, st_acc);
        }
    }

    // 4. Storage & Disks Panel
    let disk_in = tui::panel(cv, disk_r, " Storage & Disks ", th);
    let show_disks = min(s.disk_count, disk_in.h);
    for di in show_disks {
        let d = s.disks[di];
        let dy = disk_in.y + (di as i32);
        let dpct = if d.total > 0 { (d.used * 100.0) / d.total } else { 0.0 };
        let dcol = thermal_color(dpct, th);
        let right_d = str(" ", format_pct(dpct), "  ", format_bytes(d.used), " / ",
                          format_bytes(d.total), "  (Free: ", format_bytes(d.avail), ")");
        let mnt_w = min(18, max(8, disk_in.w / 5));
        tui::ellipsis(cv, tui::rect(disk_in.x + 1, dy, mnt_w, 1), disk_in.x + 1, dy, d.mount,
                      tui::bold(st_txt));
        let dbar_x = disk_in.x + 1 + mnt_w + 1;
        let dbar_w = max(8, disk_in.w - mnt_w - 50);
        draw_bar(cv, dbar_x, dy, dbar_w, dpct / 100.0, dcol, bg, th.border);
        let _ = tui::draw_text_right(cv, tui::rect(disk_in.x, dy, disk_in.w - 1, 1), dy,
                                     right_d, tui::style(dcol, bg));
    }

    // 5. Top Processes Panel (custom colored table using tui::table_cols + list_scroll)
    let proc_title = str(" Top Processes (Sort: ", sort_label(mon.sort_mode), ") ");
    let proc_in = tui::panel(cv, proc_r, proc_title, th);
    if proc_in.h >= 3 && proc_in.w >= 40 {
        let widths: i32[6] = [8, 0, 12, 8, 6, 11];
        let colr = tui::table_cols(proc_in, widths, 6);
        let headers: const u8[:][6] = ["PID", "PROCESS NAME", "MEMORY", "MEM %", "THR", "CPU TIME"];
        let hst = tui::bold(tui::style(th.title, bg));
        for ci in 6 {
            let cr = colr[ci];
            let _ = tui::draw_text(cv, cr, cr.x + 1, proc_in.y, headers[ci], hst);
        }
        tui::hr(cv, proc_in, proc_in.y + 1, tui::style(th.border, bg));

        let body_h = proc_in.h - 2;
        var view = tui::ListState { sel: mon.tbl.sel, top: mon.tbl.top };
        tui::list_scroll(view, body_h, s.proc_count);
        mon.tbl.sel = view.sel;
        mon.tbl.top = view.top;

        var r_idx: i32 = 0;
        while r_idx < body_h {
            let pidx = mon.tbl.top + r_idx;
            if pidx >= s.proc_count { break; }
            let pr = s.procs[pidx];
            let ry = proc_in.y + 2 + r_idx;
            let sel = pidx == mon.tbl.sel;
            if sel {
                tui::fill_rect(cv, tui::rect(proc_in.x, ry, proc_in.w, 1), ' ', tui::th_selected(th));
            }
            let st_row_bg = if sel { th.sel_bg } else { bg };
            let st_row_fg = if sel { th.sel_fg } else { th.fg };
            let st_pid = if sel { tui::th_selected(th) } else { tui::style(th.dim, st_row_bg) };
            let st_name = if sel { tui::bold(tui::th_selected(th)) } else { tui::style(st_row_fg, st_row_bg) };

            let mem_pct = if s.ram_total > 0 { (pr.rss * 100.0) / s.ram_total } else { 0.0 };
            let mem_col = if sel { th.sel_fg } else { thermal_color(mem_pct * 4.0, th) };
            let st_mem = tui::style(mem_col, st_row_bg);
            let st_cpu = if sel { tui::th_selected(th) } else { tui::style(th.accent, st_row_bg) };

            let _ = tui::draw_text(cv, colr[0], colr[0].x + 1, ry, str(pr.pid), st_pid);
            tui::ellipsis(cv, tui::rect(colr[1].x + 1, ry, max(1, colr[1].w - 1), 1),
                          colr[1].x + 1, ry, pr.name, st_name);
            let _ = tui::draw_text(cv, colr[2], colr[2].x + 1, ry, format_bytes(pr.rss), st_mem);
            let _ = tui::draw_text(cv, colr[3], colr[3].x + 1, ry, format_pct(mem_pct), st_mem);
            let _ = tui::draw_text(cv, colr[4], colr[4].x + 1, ry, str(pr.threads), st_pid);
            let _ = tui::draw_text(cv, colr[5], colr[5].x + 1, ry, format_cpu_time(pr.cpu_ms), st_cpu);
            r_idx += 1;
        }
    }

    // 6. Bottom Status Bar
    let bot_r = tui::rect(0, cv.h - 1, cv.w, 1);
    let mode_tag: u8[>..] = if mon.paused {
        str("PAUSED")
    } else {
        str("LIVE ", format_fixed1(mon.rate_ms / 1000.0), "s")
    };
    tui::status(cv, bot_r,
                "Q:Quit  R:Refresh  P:Pause  M/C/I:Sort(MEM/CPU/PID)  T:Theme  +/-:Rate  Up/Dn:Nav",
                mode_tag, th);
}

fn handle_event(s: SysSnapshot&, mon: MonState&, app: tui::App&, ev: tui::Event) {
    if tui::is_ctrl_c(ev) || tui::key_is(ev, 'q') || tui::key_is(ev, 'Q') ||
       tui::key_is_any(ev, tui::Key.Esc) {
        tui::quit(app);
        return;
    }
    if tui::key_is(ev, 'p') || tui::key_is(ev, 'P') || tui::key_is(ev, ' ') {
        mon.paused = !mon.paused;
        return;
    }
    if tui::key_is(ev, 'r') || tui::key_is(ev, 'R') {
        sample_system(s, mon.sort_mode);
        mon.last_poll_ms = app.now_ms;
        return;
    }
    if tui::key_is(ev, 'm') || tui::key_is(ev, 'M') {
        mon.sort_mode = SORT_MEM;
        sample_system(s, mon.sort_mode);
        mon.tbl.sel = 0;
        mon.tbl.top = 0;
        return;
    }
    if tui::key_is(ev, 'c') || tui::key_is(ev, 'C') {
        mon.sort_mode = SORT_CPU;
        sample_system(s, mon.sort_mode);
        mon.tbl.sel = 0;
        mon.tbl.top = 0;
        return;
    }
    if tui::key_is(ev, 'i') || tui::key_is(ev, 'I') {
        mon.sort_mode = SORT_PID;
        sample_system(s, mon.sort_mode);
        mon.tbl.sel = 0;
        mon.tbl.top = 0;
        return;
    }
    if tui::key_is(ev, 't') || tui::key_is(ev, 'T') {
        mon.theme_idx = (mon.theme_idx + 1) % 2;
        return;
    }
    if tui::key_is(ev, '+') || tui::key_is(ev, '=') {
        mon.rate_ms = max(500, mon.rate_ms - 500);
        return;
    }
    if tui::key_is(ev, '-') || tui::key_is(ev, '_') {
        mon.rate_ms = min(3000, mon.rate_ms + 500);
        return;
    }
    let _ = tui::table_key(mon.tbl, ev, s.proc_count);
}

fn print_once(s: const SysSnapshot&) {
    print("HEAVEN SYSMON — ", s.hostname, " (", s.os_name, ")\n");
    print("CPU   : ", s.cpu_model, " (", s.physical_cpus, "P / ", s.logical_cpus, "L)  |  Usage: ",
          format_pct(s.total_cpu_pct), " (User ", format_pct(s.user_cpu_pct),
          ", Sys ", format_pct(s.sys_cpu_pct), ")\n");
    print("Uptime: ", format_uptime(s.uptime_s), "  |  Load: ", format_fixed1(s.load1), ", ",
          format_fixed1(s.load5), ", ", format_fixed1(s.load15), "  |  Procs: ", s.total_procs, "\n");
    print("RAM   : ", format_bytes(s.ram_used), " / ", format_bytes(s.ram_total), "  (App ",
          format_bytes(s.ram_app), ", Wired ", format_bytes(s.ram_wired), ", Compr ",
          format_bytes(s.ram_compressed), ", Cached ", format_bytes(s.ram_cached), ", Free ",
          format_bytes(s.ram_free), ")\n");
    print("Swap  : ", format_bytes(s.swap_used), " / ", format_bytes(s.swap_total), "\n");
    print("Disks :\n");
    for di in s.disk_count {
        let d = s.disks[di];
        let pct = if d.total > 0 { (d.used * 100.0) / d.total } else { 0.0 };
        print("  ", d.mount, "  ", format_bytes(d.used), " / ", format_bytes(d.total),
              " (", format_pct(pct), ", Free ", format_bytes(d.avail), ")\n");
    }
    print("Top Processes:\n");
    for pi in min(s.proc_count, 8) {
        let p = s.procs[pi];
        print("  ", p.pid, "\t", p.name, "\t", format_bytes(p.rss), "\tCPU ", format_cpu_time(p.cpu_ms), "\n");
    }
}

fn dump_ansi_frame() {
    var snap = new_snapshot();
    // Build a realistic short CPU wave history seeded from live load so the sparkline shows variation
    let base_cpu = max(6.0, snap.total_cpu_pct);
    snap.hist_len = 0;
    for i in 36 {
        let wave = sin(i * 0.42) * 5.0 + cos(i * 0.19) * 3.0;
        push_cpu_hist(snap, clamp(base_cpu + wave, 2.0, 96.0));
    }
    push_cpu_hist(snap, snap.total_cpu_pct);

    var mon = MonState {
        sort_mode: SORT_MEM,
        theme_idx: 0,
        paused: false,
        rate_ms: 1000,
        last_poll_ms: 0,
        tbl: tui::table_state(),
    };
    var app = tui::app();
    var cv = tui::canvas(96, 28);
    tui::begin_frame(app, cv);
    draw_sysmon(snap, mon, cv);
    var front: tui::Cell[>..] = [];
    tui::invalidate(front);
    var shown = tui::cursor_hidden();
    var out: u8[>..] = [];
    let _ = tui::present(out, cv, front, tui::cursor_hidden(), shown);
    write_stdout(out);
    flush_stdout();
}

fn run_tests() {
    // Test formatting utilities
    check(format_bytes(512) == "512 B", "format_bytes small failed");
    check(format_bytes(1024 * 1024 * 16) == "16.0 MiB", "format_bytes MiB failed");
    check(format_bytes(2 * 1024 * 1024 * 1024) == "2.0 GiB", "format_bytes GiB failed");
    check(format_uptime(3665) == "01:01:05", "format_uptime HH:MM:SS failed");
    check(format_uptime(90060) == "1d 01h 01m", "format_uptime days failed");
    check(format_cpu_time(123400) == "02:03.4", "format_cpu_time failed");

    // Test CPU tick delta math: 2 cores, core0 = 50% busy, core1 = 25% busy => avg 37.5%
    let p_t: i64[8] = [100, 50, 1000, 0,  200, 0, 2000, 0];
    let c_t: i64[8] = [130, 70, 1050, 0,  215, 10, 2075, 0];
    var out_c: f64[32] = [0.0; 32];
    let tot_p, u_p, s_p = compute_cpu_deltas(p_t, c_t, 2, out_c);
    check(abs(out_c[0] - 50.0) < 0.01 && abs(out_c[1] - 25.0) < 0.01, "per-core delta math failed");
    check(abs(tot_p - 37.5) < 0.01 && abs(u_p - 22.5) < 0.01 && abs(s_p - 15.0) < 0.01,
          "aggregate CPU user/sys delta math failed");

    // Test live OS telemetry probes
    let snap = new_snapshot();
    check(snap.hostname.len > 0 && snap.os_name.len > 0 && snap.cpu_model.len > 0,
          "host/os/cpu metadata probe returned empty string");
    check(snap.core_count >= 1 && snap.logical_cpus >= 1, "expected >= 1 CPU core");
    check(snap.ram_total > 0 && snap.ram_used >= 0 && snap.ram_used <= snap.ram_total,
          "RAM telemetry values out of range");
    check(snap.disk_count >= 1 && snap.disks[0].total > 0, "expected >= 1 mounted disk with total > 0");
    check(snap.proc_count >= 1 && snap.procs[0].pid > 0, "expected >= 1 running process");

    // Test headless TUI rendering and key handling via goose-tui
    var snap_tui = new_snapshot();
    var mon = MonState {
        sort_mode: SORT_MEM,
        theme_idx: 0,
        paused: false,
        rate_ms: 1000,
        last_poll_ms: 0,
        tbl: tui::table_state(),
    };
    var app = tui::app();
    var cv = tui::canvas(96, 28);
    tui::headless(app, cv, "cmt", 6) { c, ev =>
        handle_event(snap_tui, mon, app, ev);
        draw_sysmon(snap_tui, mon, c);
    };
    check(mon.sort_mode == SORT_MEM && mon.theme_idx == 1, "hotkey sort/theme toggle state mismatch");
    let txt = tui::screen_text(cv);
    check(find(txt, "HEAVEN SYSMON") >= 0, "sysmon screen missing header title");
    check(find(txt, "CPU:") >= 0 && find(txt, "Memory & Swap") >= 0, "sysmon screen missing CPU/Memory panels");
    check(find(txt, "Storage & Disks") >= 0 && find(txt, "Top Processes") >= 0, "sysmon screen missing Disks/Processes");

    print("PASS sysmon (native OS probes, CPU/RAM/Disk/Proc telemetry, formatting, headless TUI)\n");
}

fn main() {
    let argv = args();
    for i in argv.len {
        if i == 0 { continue; }
        if argv[i] == "--test" {
            run_tests();
            return;
        }
        if argv[i] == "--once" {
            let s = new_snapshot();
            print_once(s);
            return;
        }
        if argv[i] == "--ansi-dump" {
            dump_ansi_frame();
            return;
        }
    }

    var t = tui::term();
    t.idle_ms = 120;
    if !tui::open(t) {
        write_stderr("sysmon: open requires an interactive terminal (or run with --once / --test / --ansi-dump)\n");
        exit(1);
    }

    var snap = new_snapshot();
    var mon = MonState {
        sort_mode: SORT_MEM,
        theme_idx: 0,
        paused: false,
        rate_ms: 1000,
        last_poll_ms: tui::clock_ms(),
        tbl: tui::table_state(),
    };
    var app = tui::app();
    var cv = tui::canvas(t.w, t.h);

    tui::run(app, t, cv) { c, ev =>
        handle_event(snap, mon, app, ev);
        if !mon.paused && (app.now_ms - mon.last_poll_ms >= mon.rate_ms) {
            sample_system(snap, mon.sort_mode);
            mon.last_poll_ms = app.now_ms;
        }
        draw_sysmon(snap, mon, c);
    };
    tui::close(t);
}

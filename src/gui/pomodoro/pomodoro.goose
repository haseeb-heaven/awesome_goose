// pomodoro: Focus Timer & Stopwatch GUI in Goose (gfx + ui + audio).
//
// Features:
//   - Focus (25:00), Short Break (05:00), Long Break (15:00), Stopwatch modes
//   - Custom anti-aliased progress ring drawn via ui::stroke_circle / stroke_arc
//   - Synthesized completion chime via audio::create_sound / play
//   - Retina HiDPI scaling & responsive full-window layout
//   - CLI flags: --test, --demo, --frames N, --screenshot <path>

import std;
import math;
import os;
import gfx;
import ui;
import audio;

let FONT: const u8[:] = embed_file("../../../assets/Roboto-Regular.ttf");

let MODE_FOCUS: i64 = 0;
let MODE_SHORT: i64 = 1;
let MODE_LONG: i64 = 2;
let MODE_STOPWATCH: i64 = 3;

struct TimerState {
    mode: i64,
    running: bool,
    remaining: f64,
    duration: f64,
    elapsed: f64,
    sessions: i64,
    just_finished: bool,
}

fn mode_duration(mode: i64) -> f64 {
    if mode == MODE_FOCUS { return 25.0 * 60.0; }
    if mode == MODE_SHORT { return 5.0 * 60.0; }
    if mode == MODE_LONG { return 15.0 * 60.0; }
    return 0.0;
}

fn mode_name(mode: i64) -> u8[>..] {
    if mode == MODE_FOCUS { return str("DEEP FOCUS"); }
    if mode == MODE_SHORT { return str("SHORT BREAK"); }
    if mode == MODE_LONG { return str("LONG BREAK"); }
    return str("STOPWATCH");
}

fn new_timer() -> TimerState {
    TimerState {
        mode: MODE_FOCUS,
        running: false,
        remaining: 25.0 * 60.0,
        duration: 25.0 * 60.0,
        elapsed: 0.0,
        sessions: 0,
        just_finished: false,
    }
}

fn set_mode(st: TimerState&, mode: i64) {
    st.mode = mode;
    st.running = false;
    st.just_finished = false;
    st.duration = mode_duration(mode);
    st.remaining = st.duration;
    st.elapsed = 0.0;
}

fn reset_timer(st: TimerState&) {
    st.running = false;
    st.just_finished = false;
    st.remaining = st.duration;
    st.elapsed = 0.0;
}

fn add_minute(st: TimerState&) {
    if st.mode == MODE_STOPWATCH { return; }
    st.remaining += 60.0;
    if st.remaining > st.duration { st.duration = st.remaining; }
}

fn tick_timer(st: TimerState&, dt: f64) {
    st.just_finished = false;
    if !st.running || dt <= 0.0 { return; }
    if st.mode == MODE_STOPWATCH {
        st.elapsed += dt;
        return;
    }
    st.remaining -= dt;
    if st.remaining <= 0.0 {
        st.remaining = 0.0;
        st.running = false;
        st.just_finished = true;
        if st.mode == MODE_FOCUS {
            st.sessions++;
            if st.sessions % 4 == 0 {
                set_mode(st, MODE_LONG);
            } else {
                set_mode(st, MODE_SHORT);
            }
            st.just_finished = true;
        } else {
            set_mode(st, MODE_FOCUS);
            st.just_finished = true;
        }
    }
}

fn fmt_mmss(secs_f: f64) -> u8[>..] {
    var total = ceil(secs_f) as i64;
    if total < 0 { total = 0; }
    let mins = total / 60;
    let secs = total % 60;
    var m_str = str(mins);
    if mins < 10 { m_str = str("0", mins); }
    var s_str = str(secs);
    if secs < 10 { s_str = str("0", secs); }
    return str(m_str, ":", s_str);
}

fn make_btn_style(base: ui::StyleButton, bg: ui::Color, hover_bg: ui::Color,
                  active_bg: ui::Color, fg: ui::Color) -> ui::StyleButton {
    var b = base;
    b.normal = ui::style_item_color(bg);
    b.hover = ui::style_item_color(hover_bg);
    b.active = ui::style_item_color(active_bg);
    b.border_color = ui::rgba(255, 255, 255, 24);
    b.border = 1.0;
    b.rounding = 8.0;
    b.text_normal = fg;
    b.text_hover = fg;
    b.text_active = fg;
    b.text_background = bg;
    return b;
}

fn build_chime() -> f32[>..] {
    let rate = 48000;
    let samples = 24000;
    var pcm: f32[>..] = [];
    for i in samples {
        let t = i / (rate as f64);
        let env = (1.0 - (i / (samples as f64))) * (1.0 - (i / (samples as f64)));
        let s = 0.5 * sin(TAU * 523.25 * t) + 0.35 * sin(TAU * 659.25 * t) +
                0.25 * sin(TAU * 783.99 * t);
        pcm.push((s * 0.25 * env) as f32);
    }
    return pcm;
}

fn stroke_ring_arc(ctx: ui::Context, cx: f32, cy: f32, radius: f32, a_min: f32,
                   a_max: f32, thickness: f32, color: ui::Color) {
    let steps = 64;
    var pts: float2[>..] = [];
    for i in steps + 1 {
        let frac = (i as f32) / steps;
        let ang = a_min + (a_max - a_min) * frac;
        pts.push(float2 { cx + cos(ang) * radius, cy + sin(ang) * radius });
    }
    ui::stroke_polyline(ctx, pts, thickness, color);
}

fn check(ok: bool, msg: const u8[:]) {
    if !ok { abort(msg); }
}

fn run_tests() {
    var t = new_timer();
    check(fmt_mmss(1500.0) == "25:00", "25:00 formatting failed");
    check(fmt_mmss(65.0) == "01:05", "01:05 formatting failed");
    check(fmt_mmss(0.0) == "00:00", "00:00 formatting failed");

    t.running = true;
    tick_timer(t, 1500.0);
    check(t.just_finished && t.sessions == 1 && t.mode == MODE_SHORT,
          "focus completion should increment sessions and enter short break");

    set_mode(t, MODE_FOCUS);
    add_minute(t);
    check(abs(t.remaining - 1560.0) < 1e-6, "add_minute failed");

    set_mode(t, MODE_STOPWATCH);
    t.running = true;
    tick_timer(t, 12.5);
    check(abs(t.elapsed - 12.5) < 1e-6, "stopwatch tick failed");

    let pcm = build_chime();
    check(pcm.len == 24000, "chime buffer length mismatch");
    print("PASS pomodoro (MM:SS format, countdown, sessions, modes, stopwatch, audio)\n");
}

fn main() {
    let argv = args();
    var frames: i64 = -1;
    var demo_mode = false;
    var screenshot_path = str("");

    var i: i64 = 1;
    while i < argv.len {
        let a = argv[i];
        if a == "--test" {
            run_tests();
            return;
        } else if a == "--demo" {
            demo_mode = true;
        } else if a == "--frames" && i + 1 < argv.len {
            let n, ok = parse_int(argv[i + 1]);
            if ok { frames = n; }
            i++;
        } else if a == "--screenshot" && i + 1 < argv.len {
            screenshot_path = str(argv[i + 1]);
            i++;
        }
        i++;
    }

    guard gfx::open("Goose Pomodoro", 420, 520, gfx::WINDOW_RESIZABLE) else {
        write_stderr(str("gfx: ", gfx::error(), "\n"));
        return;
    }
    defer gfx::close();

    var ctx = ui::create_from_memory(FONT, 20.0);
    guard ctx.id != 0 else {
        write_stderr(str("ui: ", ui::error(), "\n"));
        return;
    }
    defer ui::destroy(ctx);

    let init_pixels = gfx::screen_size();
    let base_w: f32 = 420.0;
    var dpi_scale: f32 = init_pixels.x / base_w;
    if dpi_scale < 0.5 { dpi_scale = 1.0; }
    if dpi_scale > 4.0 { dpi_scale = 4.0; }
    if dpi_scale != ui::scale(ctx) {
        ui::set_scale(ctx, dpi_scale);
    }

    var colors = ui::default_color_table();
    colors[ui::COLOR_WINDOW] = ui::rgb(18, 22, 31);
    colors[ui::COLOR_TEXT] = ui::rgb(236, 242, 248);
    colors[ui::COLOR_BORDER] = ui::rgb(42, 50, 68);
    ui::style_from_table(ctx, colors);

    var st = ui::style(ctx);
    st.window.padding = float2 { 16.0, 14.0 };
    st.window.spacing = float2 { 8.0, 10.0 };
    ui::set_style(ctx, st);

    var use_audio = screenshot_path.len == 0 && audio::available();
    var chime = audio::Sound { id: 0 };
    if use_audio {
        if audio::open() {
            chime = audio::create_sound(build_chime());
        } else {
            use_audio = false;
        }
    }
    defer {
        if use_audio {
            audio::release_sound(chime);
            audio::close();
        }
    }

    let white = ui::rgb(248, 250, 252);
    let dim_txt = ui::rgb(152, 168, 190);
    let tab_idle = make_btn_style(st.button, ui::rgb(35, 42, 56), ui::rgb(48, 57, 76),
                                  ui::rgb(28, 33, 44), dim_txt);
    let tab_active = make_btn_style(st.button, ui::rgb(62, 78, 108), ui::rgb(78, 96, 130),
                                    ui::rgb(52, 66, 92), white);
    let start_btn = make_btn_style(st.button, ui::rgb(16, 165, 114), ui::rgb(24, 192, 134),
                                   ui::rgb(12, 135, 92), white);
    let pause_btn = make_btn_style(st.button, ui::rgb(217, 119, 6), ui::rgb(245, 158, 11),
                                   ui::rgb(180, 83, 9), white);
    let sec_btn = make_btn_style(st.button, ui::rgb(48, 56, 74), ui::rgb(64, 74, 96),
                                 ui::rgb(36, 42, 56), white);

    var timer = new_timer();
    if demo_mode {
        timer.sessions = 2;
        timer.remaining = 18.0 * 60.0 + 42.0;
        timer.running = true;
    }

    let window_flags = ui::WINDOW_NO_SCROLLBAR;
    var has_window = false;
    var drawn: i64 = 0;

    while gfx::frame() {
        if gfx::key_pressed("Escape") { break; }
        if gfx::key_pressed("Space") { timer.running = !timer.running; }
        if gfx::key_pressed("R") { reset_timer(timer); }
        ui::input_from_gfx(ctx);

        let dt = gfx::delta_time();
        if !demo_mode {
            tick_timer(timer, min(dt, 0.25));
            if timer.just_finished && use_audio && chime.id != 0 {
                audio::play(chime);
            }
        }

        let pixels = gfx::screen_size();
        let ui_scale = ui::scale(ctx);
        let win_w = pixels.x / ui_scale;
        let win_h = pixels.y / ui_scale;
        let bounds = ui::rect(0.0, 0.0, win_w, win_h);
        if has_window {
            ui::window_set_bounds(ctx, "Pomodoro", bounds);
        }

        let accent = if timer.mode == MODE_FOCUS {
            ui::rgb(244, 94, 94)
        } else if timer.mode == MODE_SHORT {
            ui::rgb(52, 211, 153)
        } else if timer.mode == MODE_LONG {
            ui::rgb(96, 165, 250)
        } else {
            ui::rgb(250, 204, 21)
        };

        if ui::begin(ctx, "Pomodoro", bounds, window_flags) {
            has_window = true;
            let content = ui::window_get_content_region_size(ctx);
            var ring_h = content.y - 196.0;
            if ring_h < 180.0 { ring_h = 180.0; }

            // Mode selector row
            ui::layout_row_dynamic(ctx, 36.0, 4);
            if ui::button_label_styled(ctx, if timer.mode == MODE_FOCUS { tab_active } else { tab_idle }, "Focus") {
                set_mode(timer, MODE_FOCUS);
            }
            if ui::button_label_styled(ctx, if timer.mode == MODE_SHORT { tab_active } else { tab_idle }, "Short") {
                set_mode(timer, MODE_SHORT);
            }
            if ui::button_label_styled(ctx, if timer.mode == MODE_LONG { tab_active } else { tab_idle }, "Long") {
                set_mode(timer, MODE_LONG);
            }
            if ui::button_label_styled(ctx, if timer.mode == MODE_STOPWATCH { tab_active } else { tab_idle }, "Watch") {
                set_mode(timer, MODE_STOPWATCH);
            }

            // Status header
            ui::layout_row_dynamic(ctx, 28.0, 2);
            ui::label_colored(ctx, mode_name(timer.mode), ui::TEXT_LEFT, accent);
            ui::label_colored(ctx, str("Sessions: ", timer.sessions), ui::TEXT_RIGHT, dim_txt);

            // Progress ring canvas
            ui::layout_row_dynamic(ctx, ring_h, 1);
            let wstate, rbox = ui::widget(ctx);
            let _ = wstate;
            let radius = min(rbox.w, rbox.h) * 0.36;
            let cx = rbox.x + rbox.w * 0.5;
            let cy = rbox.y + rbox.h * 0.5;
            let circle_r = ui::rect(cx - radius, cy - radius, radius * 2.0, radius * 2.0);
            ui::fill_circle(ctx, circle_r, ui::rgb(24, 29, 41));
            stroke_ring_arc(ctx, cx, cy, radius, 0.0, TAU, 10.0, ui::rgb(42, 50, 68));

            var frac = 0.0;
            if timer.mode == MODE_STOPWATCH {
                frac = fract(timer.elapsed / 60.0);
            } else if timer.duration > 0.0 {
                frac = (timer.duration - timer.remaining) / timer.duration;
                if frac < 0.0 { frac = 0.0; }
                if frac > 1.0 { frac = 1.0; }
            }
            let start_ang = (-PI * 0.5) as f32;
            let end_ang = start_ang + (TAU * frac) as f32;
            if frac > 0.005 {
                stroke_ring_arc(ctx, cx, cy, radius, start_ang, end_ang, 10.0, accent);
            }

            let time_str = if timer.mode == MODE_STOPWATCH {
                fmt_mmss(timer.elapsed)
            } else {
                fmt_mmss(timer.remaining)
            };
            let txt_rect = ui::rect(cx - 80.0, cy - 18.0, 160.0, 30.0);
            let tw = ui::text_width(ui::font(ctx), time_str);
            let centered_rect = ui::rect(cx - tw * 0.5, cy - 16.0, tw + 8.0, 26.0);
            let _ = txt_rect;
            ui::draw_text(ctx, centered_rect, time_str, ui::font(ctx),
                          ui::rgb(24, 29, 41), white);

            let sub_str = if timer.running { str("RUNNING") } else { str("PAUSED") };
            let sub_w = ui::text_width(ui::font(ctx), sub_str);
            let sub_rect = ui::rect(cx - sub_w * 0.5, cy + 16.0, sub_w + 8.0, 22.0);
            ui::draw_text(ctx, sub_rect, sub_str, ui::font(ctx),
                          ui::rgb(24, 29, 41), accent);

            // Control buttons
            ui::layout_row_dynamic(ctx, 44.0, 2);
            if timer.running {
                if ui::button_label_styled(ctx, pause_btn, "Pause") { timer.running = false; }
            } else {
                if ui::button_label_styled(ctx, start_btn, "Start") { timer.running = true; }
            }
            if ui::button_label_styled(ctx, sec_btn, "Reset") { reset_timer(timer); }

            ui::layout_row_dynamic(ctx, 38.0, 2);
            if ui::button_label_styled(ctx, sec_btn, "+1 Min") { add_minute(timer); }
            if ui::button_label_styled(ctx, sec_btn, "Next Mode") {
                set_mode(timer, (timer.mode + 1) % 4);
            }
        }
        ui::end(ctx);

        gfx::begin_screen(float4 { 0.07, 0.08, 0.12, 1.0 });
        gfx::end_pass();
        ui::render(ctx);

        drawn++;
        if frames > 0 && drawn >= frames { break; }
    }

    if screenshot_path.len > 0 {
        let ok = gfx::screenshot(screenshot_path);
        check(ok, "failed to save pomodoro screenshot");
    }
}

// calculator: Styled Desktop GUI Calculator in Goose (gfx + ui + Retina HiDPI).
//
// Features:
//   - Responsive full-window layout with automatic HiDPI/Retina UI scaling
//   - Color-coded dark slate theme (digits, amber operators, emerald =, crimson C/CE)
//   - Full mouse and keyboard input (0-9, ., +-*/, Enter/=, Backspace, %, C, Esc)
//   - CLI flags: --test, --demo, --frames N, --screenshot <path>

import std;
import math;
import os;
import gfx;
import ui;

let FONT: const u8[:] = embed_file("../../../assets/Roboto-Regular.ttf");

struct CalcState {
    stored: f64,
    current: f64,
    pending_op: i64, // 0: none, 1: +, 2: -, 3: *, 4: /
    fresh_input: bool,
    has_decimal: bool,
    decimal_scale: f64,
    neg: bool,
    has_error: bool,
    digits: u8[..64],
    expr: u8[..128],
}

fn to_buf64(s: const u8[:]) -> u8[..64] {
    var b: u8[..64] = [];
    b.append(s[..min(s.len, 64)]);
    return b;
}

fn to_buf128(s: const u8[:]) -> u8[..128] {
    var b: u8[..128] = [];
    b.append(s[..min(s.len, 128)]);
    return b;
}

fn new_calc() -> CalcState {
    CalcState {
        stored: 0.0,
        current: 0.0,
        pending_op: 0,
        fresh_input: true,
        has_decimal: false,
        decimal_scale: 0.1,
        neg: false,
        has_error: false,
        digits: to_buf64("0"),
        expr: to_buf128(""),
    }
}

fn fmt_num(v: f64) -> u8[>..] {
    if v == 0.0 { return str("0"); }
    if abs(v) < 1e12 && v == trunc(v) {
        return str(round(v) as i64);
    }
    return str(v);
}

fn op_symbol(op: i64) -> u8[>..] {
    if op == 1 { return str("+"); }
    if op == 2 { return str("-"); }
    if op == 3 { return str("*"); }
    if op == 4 { return str("/"); }
    return str("");
}

fn calc_clear(s: CalcState&) {
    s.stored = 0.0;
    s.current = 0.0;
    s.pending_op = 0;
    s.fresh_input = true;
    s.has_decimal = false;
    s.decimal_scale = 0.1;
    s.neg = false;
    s.has_error = false;
    s.digits = to_buf64("0");
    s.expr = to_buf128("");
}

fn calc_ce(s: CalcState&) {
    if s.has_error {
        s.stored = 0.0;
        s.pending_op = 0;
        s.has_error = false;
        s.expr = to_buf128("");
    }
    s.current = 0.0;
    s.fresh_input = true;
    s.has_decimal = false;
    s.decimal_scale = 0.1;
    s.neg = false;
    s.digits = to_buf64("0");
}

fn calc_digit(s: CalcState&, digit_val: f64, digit_ch: const u8[:]) {
    if s.has_error {
        s.stored = 0.0;
        s.pending_op = 0;
        s.has_error = false;
        s.fresh_input = true;
        s.expr = to_buf128("");
    }
    if s.fresh_input {
        if s.pending_op == 0 {
            s.expr = to_buf128("");
        }
        s.current = digit_val;
        s.neg = false;
        s.has_decimal = false;
        s.decimal_scale = 0.1;
        s.digits = to_buf64(digit_ch);
        if digit_val != 0.0 {
            s.fresh_input = false;
        }
    } else {
        if s.digits.len >= 18 { return; }
        if s.has_decimal {
            if s.neg {
                s.current = s.current - digit_val * s.decimal_scale;
            } else {
                s.current = s.current + digit_val * s.decimal_scale;
            }
            s.decimal_scale = s.decimal_scale * 0.1;
        } else {
            if s.neg {
                s.current = s.current * 10.0 - digit_val;
            } else {
                s.current = s.current * 10.0 + digit_val;
            }
        }
        s.digits.append(digit_ch[..min(digit_ch.len, 64 - s.digits.len)]);
    }
}

fn calc_dot(s: CalcState&) {
    if s.has_error {
        s.stored = 0.0;
        s.pending_op = 0;
        s.has_error = false;
        s.fresh_input = true;
        s.expr = to_buf128("");
    }
    if s.fresh_input {
        if s.pending_op == 0 {
            s.expr = to_buf128("");
        }
        s.current = 0.0;
        s.neg = false;
        s.digits = to_buf64("0.");
        s.has_decimal = true;
        s.decimal_scale = 0.1;
        s.fresh_input = false;
    } else if !s.has_decimal {
        if s.digits.len < 64 { s.digits.push('.'); }
        s.has_decimal = true;
        s.decimal_scale = 0.1;
    }
}

fn calc_backspace(s: CalcState&) {
    if s.has_error {
        calc_clear(s);
        return;
    }
    if s.fresh_input { return; }
    if s.digits.len <= 1 {
        s.current = 0.0;
        s.neg = false;
        s.has_decimal = false;
        s.decimal_scale = 0.1;
        s.fresh_input = true;
        s.digits = to_buf64("0");
        return;
    }
    s.digits.resize(s.digits.len - 1);
    if s.digits == "-" { s.digits = to_buf64("0"); }
    var text = if s.neg { str("-", s.digits) } else { str(s.digits) };
    let v, ok = parse_flt(text);
    if ok { s.current = v; }
    // Recompute decimal status
    var dot_pos: i64 = -1;
    for i in s.digits.len {
        if s.digits[i] == '.' { dot_pos = i; break; }
    }
    if dot_pos >= 0 {
        s.has_decimal = true;
        let dec_digits = s.digits.len - 1 - dot_pos;
        s.decimal_scale = 0.1;
        for _ in dec_digits { s.decimal_scale *= 0.1; }
    } else {
        s.has_decimal = false;
        s.decimal_scale = 0.1;
    }
    if s.digits == "0" && !s.has_decimal {
        s.neg = false;
        s.fresh_input = true;
    }
}

fn calc_sign(s: CalcState&) {
    if !s.has_error && s.current != 0.0 {
        s.current = -s.current;
        s.neg = !s.neg;
    }
}

fn calc_percent(s: CalcState&) {
    if s.has_error { return; }
    s.current = s.current / 100.0;
    if s.current == 0.0 {
        s.current = 0.0;
        s.neg = false;
        s.digits = to_buf64("0");
    } else if s.current < 0.0 {
        s.neg = true;
        s.digits = to_buf64(fmt_num(-s.current));
    } else {
        s.neg = false;
        s.digits = to_buf64(fmt_num(s.current));
    }
    s.fresh_input = true;
    s.has_decimal = false;
    s.decimal_scale = 0.1;
}

fn apply_op(op: i64, a: f64, b: f64) -> f64, bool {
    if op == 1 { return a + b, false; }
    if op == 2 { return a - b, false; }
    if op == 3 { return a * b, false; }
    if op == 4 {
        if b == 0.0 { return 0.0, true; }
        return a / b, false;
    }
    return a, false;
}

fn calc_op(s: CalcState&, op: i64) {
    if s.has_error || op == 0 { return; }
    if s.pending_op != 0 && !s.fresh_input {
        let result, err = apply_op(s.pending_op, s.stored, s.current);
        if err {
            s.has_error = true;
            s.pending_op = 0;
            s.expr = to_buf128(str(fmt_num(s.stored), " / 0"));
            return;
        }
        var res = result;
        if res == 0.0 { res = 0.0; }
        s.stored = res;
        s.current = res;
        if res < 0.0 {
            s.neg = true;
            s.digits = to_buf64(fmt_num(-res));
        } else {
            s.neg = false;
            s.digits = to_buf64(fmt_num(res));
        }
    } else if s.pending_op == 0 {
        s.stored = s.current;
    }

    s.pending_op = op;
    s.fresh_input = true;
    s.has_decimal = false;
    s.decimal_scale = 0.1;
    s.expr = to_buf128(str(fmt_num(s.stored), " ", op_symbol(op)));
}

fn calc_eq(s: CalcState&) {
    if s.has_error || s.pending_op == 0 { return; }
    s.expr = to_buf128(str(fmt_num(s.stored), " ", op_symbol(s.pending_op), " ",
                           fmt_num(s.current), " ="));
    let result, err = apply_op(s.pending_op, s.stored, s.current);
    if err {
        s.has_error = true;
    } else {
        var res = result;
        if res == 0.0 { res = 0.0; }
        s.stored = res;
        s.current = res;
        if res < 0.0 {
            s.neg = true;
            s.digits = to_buf64(fmt_num(-res));
        } else {
            s.neg = false;
            s.digits = to_buf64(fmt_num(res));
        }
    }
    s.pending_op = 0;
    s.fresh_input = true;
    s.has_decimal = false;
    s.decimal_scale = 0.1;
}

fn calc_display(s: const CalcState&) -> u8[>..] {
    if s.has_error { return str("Error"); }
    if s.neg { return str("-", s.digits); }
    return str(s.digits);
}

fn make_btn_style(base: ui::StyleButton, bg: ui::Color, hover_bg: ui::Color,
                  active_bg: ui::Color, fg: ui::Color) -> ui::StyleButton {
    var b = base;
    b.normal = ui::style_item_color(bg);
    b.hover = ui::style_item_color(hover_bg);
    b.active = ui::style_item_color(active_bg);
    b.border_color = ui::rgba(255, 255, 255, 22);
    b.border = 1.0;
    b.rounding = 10.0;
    b.text_normal = fg;
    b.text_hover = fg;
    b.text_active = fg;
    b.text_background = bg;
    return b;
}

fn check(ok: bool, msg: const u8[:]) {
    if !ok { abort(msg); }
}

fn run_tests() {
    var c = new_calc();
    // 128 * 4 = 512
    calc_digit(c, 1.0, "1");
    calc_digit(c, 2.0, "2");
    calc_digit(c, 8.0, "8");
    calc_op(c, 3);
    calc_digit(c, 4.0, "4");
    calc_eq(c);
    check(c.current == 512.0 && !c.has_error, "128 * 4 must equal 512");
    check(calc_display(c) == "512", "display must show 512");
    check(c.expr == "128 * 4 =", "expr must show 128 * 4 =");

    // Sign toggle & addition: -512 + 12 = -500
    calc_sign(c);
    check(c.current == -512.0 && calc_display(c) == "-512", "sign toggle failed");
    calc_op(c, 1);
    calc_digit(c, 1.0, "1");
    calc_digit(c, 2.0, "2");
    calc_eq(c);
    check(c.current == -500.0 && calc_display(c) == "-500", "negative addition failed");

    // Percent & decimals: 25.5% = 0.255
    calc_clear(c);
    calc_digit(c, 2.0, "2");
    calc_digit(c, 5.0, "5");
    calc_dot(c);
    calc_digit(c, 5.0, "5");
    calc_backspace(c);
    calc_digit(c, 5.0, "5");
    calc_percent(c);
    check(abs(c.current - 0.255) < 1e-9, "percent conversion failed");

    // Division by zero & CE recovery
    calc_clear(c);
    calc_digit(c, 9.0, "9");
    calc_op(c, 4);
    calc_digit(c, 0.0, "0");
    calc_eq(c);
    check(c.has_error && calc_display(c) == "Error", "divide by zero must set error");
    calc_ce(c);
    check(!c.has_error && c.current == 0.0 && calc_display(c) == "0", "CE must clear error");

    print("PASS calculator (arithmetic, decimals, backspace, percent, div-by-zero, CE)\n");
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

    guard gfx::open("Goose Calculator", 360, 480, gfx::WINDOW_RESIZABLE) else {
        write_stderr(str("gfx: ", gfx::error(), "\n"));
        return;
    }
    defer gfx::close();

    var ctx = ui::create_from_memory(FONT, 22.0);
    guard ctx.id != 0 else {
        write_stderr(str("ui: ", ui::error(), "\n"));
        return;
    }
    defer ui::destroy(ctx);

    let init_pixels = gfx::screen_size();
    let base_w: f32 = 360.0;
    var dpi_scale: f32 = init_pixels.x / base_w;
    if dpi_scale < 0.5 { dpi_scale = 1.0; }
    if dpi_scale > 4.0 { dpi_scale = 4.0; }
    if dpi_scale != ui::scale(ctx) {
        ui::set_scale(ctx, dpi_scale);
    }

    var colors = ui::default_color_table();
    colors[ui::COLOR_WINDOW] = ui::rgb(20, 23, 30);
    colors[ui::COLOR_TEXT] = ui::rgb(240, 244, 250);
    colors[ui::COLOR_BORDER] = ui::rgb(38, 44, 58);
    ui::style_from_table(ctx, colors);

    var root_style = ui::style(ctx);
    root_style.window.spacing = float2 { 8.0, 8.0 };
    root_style.window.padding = float2 { 14.0, 14.0 };
    ui::set_style(ctx, root_style);

    let white = ui::rgb(248, 250, 252);
    let muted_white = ui::rgb(220, 226, 236);
    let num_btn = make_btn_style(root_style.button, ui::rgb(42, 48, 62),
                                 ui::rgb(58, 66, 86), ui::rgb(32, 37, 48), white);
    let util_btn = make_btn_style(root_style.button, ui::rgb(64, 74, 94),
                                  ui::rgb(82, 94, 118), ui::rgb(50, 58, 74), muted_white);
    let clr_btn = make_btn_style(root_style.button, ui::rgb(150, 46, 56),
                                 ui::rgb(185, 58, 70), ui::rgb(120, 36, 44), white);
    let op_btn = make_btn_style(root_style.button, ui::rgb(217, 119, 6),
                                ui::rgb(245, 158, 11), ui::rgb(180, 83, 9), white);
    let eq_btn = make_btn_style(root_style.button, ui::rgb(16, 150, 104),
                                ui::rgb(22, 185, 128), ui::rgb(12, 120, 84), white);

    var calc = new_calc();
    if demo_mode {
        calc_digit(calc, 1.0, "1");
        calc_digit(calc, 2.0, "2");
        calc_digit(calc, 8.0, "8");
        calc_op(calc, 3);
        calc_digit(calc, 4.0, "4");
        calc_eq(calc);
    }

    let window_flags = ui::WINDOW_NO_SCROLLBAR;
    var has_window = false;
    var drawn: i64 = 0;

    while gfx::frame() {
        if gfx::key_pressed("Escape") { break; }
        ui::input_from_gfx(ctx);

        // Keyboard support
        for ev in gfx::events() {
            if ev.kind == gfx::EVENT_TEXT {
                let cp = ev.codepoint;
                if cp >= '0' && cp <= '9' {
                    let dv = (cp - '0') as f64;
                    var ds: u8[>..] = [];
                    ds.push(cp as u8);
                    calc_digit(calc, dv, ds);
                } else if cp == '.' { calc_dot(calc); }
                else if cp == '+' { calc_op(calc, 1); }
                else if cp == '-' { calc_op(calc, 2); }
                else if cp == '*' { calc_op(calc, 3); }
                else if cp == '/' { calc_op(calc, 4); }
                else if cp == '=' { calc_eq(calc); }
                else if cp == '%' { calc_percent(calc); }
                else if cp == 'c' || cp == 'C' { calc_clear(calc); }
            }
        }
        if gfx::key_pressed("Return") { calc_eq(calc); }
        if gfx::key_pressed("Backspace") { calc_backspace(calc); }

        let pixels = gfx::screen_size();
        let ui_scale = ui::scale(ctx);
        let win_w = pixels.x / ui_scale;
        let win_h = pixels.y / ui_scale;
        let bounds = ui::rect(0.0, 0.0, win_w, win_h);
        if has_window {
            ui::window_set_bounds(ctx, "Calculator", bounds);
        }

        var digit_val = -1.0;
        var digit_str = str("");
        var op_pressed: i64 = 0;
        var eq_pressed = false;
        var clear_pressed = false;
        var ce_pressed = false;
        var dot_pressed = false;
        var sign_pressed = false;
        var percent_pressed = false;

        let display_text = calc_display(calc);

        if ui::begin(ctx, "Calculator", bounds, window_flags) {
            has_window = true;
            let content = ui::window_get_content_region_size(ctx);
            var avail_h = content.y - 68.0;
            if avail_h < 220.0 { avail_h = 220.0; }
            let expr_h = avail_h * 0.09;
            let disp_h = avail_h * 0.16;
            let btn_h = (avail_h - expr_h - disp_h) / 5.0;

            // Display panel card
            ui::layout_row_dynamic(ctx, expr_h + disp_h + 12.0, 1);
            let card_state, card_rect = ui::widget(ctx);
            let _ = card_state;
            ui::fill_rect(ctx, card_rect, 10.0, ui::rgb(13, 16, 22));
            ui::stroke_rect(ctx, card_rect, 10.0, 1.0, ui::rgb(46, 54, 72));
            let pad_x: f32 = 12.0;
            let expr_rect = ui::rect(card_rect.x + pad_x, card_rect.y + 8.0,
                                     card_rect.w - pad_x * 2.0, expr_h);
            let disp_rect = ui::rect(card_rect.x + pad_x, card_rect.y + 8.0 + expr_h,
                                     card_rect.w - pad_x * 2.0, disp_h);
            ui::draw_text(ctx, expr_rect, calc.expr, ui::font(ctx),
                          ui::rgb(13, 16, 22), ui::rgb(148, 163, 184));
            ui::draw_text(ctx, disp_rect, display_text, ui::font(ctx),
                          ui::rgb(13, 16, 22),
                          if calc.has_error { ui::rgb(248, 113, 113) } else { white });

            // Row 1: C  +/-  %  /
            ui::layout_row_dynamic(ctx, btn_h, 4);
            if ui::button_label_styled(ctx, clr_btn, "C") { clear_pressed = true; }
            if ui::button_label_styled(ctx, util_btn, "+/-") { sign_pressed = true; }
            if ui::button_label_styled(ctx, util_btn, "%") { percent_pressed = true; }
            if ui::button_label_styled(ctx, op_btn, "/") { op_pressed = 4; }

            // Row 2: 7  8  9  *
            ui::layout_row_dynamic(ctx, btn_h, 4);
            if ui::button_label_styled(ctx, num_btn, "7") { digit_val = 7.0; digit_str = str("7"); }
            if ui::button_label_styled(ctx, num_btn, "8") { digit_val = 8.0; digit_str = str("8"); }
            if ui::button_label_styled(ctx, num_btn, "9") { digit_val = 9.0; digit_str = str("9"); }
            if ui::button_label_styled(ctx, op_btn, "*") { op_pressed = 3; }

            // Row 3: 4  5  6  -
            ui::layout_row_dynamic(ctx, btn_h, 4);
            if ui::button_label_styled(ctx, num_btn, "4") { digit_val = 4.0; digit_str = str("4"); }
            if ui::button_label_styled(ctx, num_btn, "5") { digit_val = 5.0; digit_str = str("5"); }
            if ui::button_label_styled(ctx, num_btn, "6") { digit_val = 6.0; digit_str = str("6"); }
            if ui::button_label_styled(ctx, op_btn, "-") { op_pressed = 2; }

            // Row 4: 1  2  3  +
            ui::layout_row_dynamic(ctx, btn_h, 4);
            if ui::button_label_styled(ctx, num_btn, "1") { digit_val = 1.0; digit_str = str("1"); }
            if ui::button_label_styled(ctx, num_btn, "2") { digit_val = 2.0; digit_str = str("2"); }
            if ui::button_label_styled(ctx, num_btn, "3") { digit_val = 3.0; digit_str = str("3"); }
            if ui::button_label_styled(ctx, op_btn, "+") { op_pressed = 1; }

            // Row 5: 0  .  CE  =
            ui::layout_row_dynamic(ctx, btn_h, 4);
            if ui::button_label_styled(ctx, num_btn, "0") { digit_val = 0.0; digit_str = str("0"); }
            if ui::button_label_styled(ctx, num_btn, ".") { dot_pressed = true; }
            if ui::button_label_styled(ctx, clr_btn, "CE") { ce_pressed = true; }
            if ui::button_label_styled(ctx, eq_btn, "=") { eq_pressed = true; }
        }
        ui::end(ctx);

        if clear_pressed { calc_clear(calc); }
        if ce_pressed { calc_ce(calc); }
        if digit_val >= 0.0 { calc_digit(calc, digit_val, digit_str); }
        if dot_pressed { calc_dot(calc); }
        if sign_pressed { calc_sign(calc); }
        if percent_pressed { calc_percent(calc); }
        if op_pressed != 0 { calc_op(calc, op_pressed); }
        if eq_pressed { calc_eq(calc); }

        gfx::begin_screen(float4 { 0.08, 0.09, 0.12, 1.0 });
        gfx::end_pass();
        ui::render(ctx);

        drawn++;
        if frames > 0 && drawn >= frames { break; }
    }

    if screenshot_path.len > 0 {
        let ok = gfx::screenshot(screenshot_path);
        check(ok, "failed to save calculator screenshot");
    }
}

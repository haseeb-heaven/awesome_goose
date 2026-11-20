// pixel_studio: Desktop Pixel Art & Sprite Studio in Goose (gfx + ui).
//
// Features:
//   - Three-pane creative workstation: Tool Rail, Interactive Pixel Canvas, Live Preview + Palette
//   - Tools: Brush, Eraser, Flood Fill Bucket (non-recursive stack), Eyedropper, Mirror-X Symmetry
//   - 16x16 & 24x24 canvas modes, toggleable grid overlay, 16-level Undo/Redo history
//   - Pure Goose binary PPM (P6) image export
//   - Handcrafted 16x16 Goose mascot sprite preset
//   - CLI flags: --test, --demo, --frames N, --screenshot <path>

import std;
import math;
import os;
import gfx;
import ui;

let FONT: const u8[:] = embed_file("../../../assets/Roboto-Regular.ttf");

let MAX_GRID: i64 = 24;
let MAX_CELLS: i64 = 576;
let MAX_HIST: i64 = 16;

let TOOL_BRUSH: i64 = 0;
let TOOL_ERASER: i64 = 1;
let TOOL_FILL: i64 = 2;
let TOOL_PICKER: i64 = 3;

struct PixelRGBA { r: u8, g: u8, b: u8, a: u8 }

struct Snapshot {
    grid_n: i64,
    pixels: PixelRGBA[576],
}

struct StudioState {
    grid_n: i64,
    pixels: PixelRGBA[576],
    tool: i64,
    brush_size: i64,
    mirror_x: bool,
    show_grid: bool,
    col_r: i64,
    col_g: i64,
    col_b: i64,
    history: Snapshot[16],
    hist_len: i64,
    hist_pos: i64,
    stroke_active: bool,
    status: u8[..96],
}

fn check(ok: bool, msg: const u8[:]) {
    if !ok { abort(msg); }
}

fn to_buf96(s: const u8[:]) -> u8[..96] {
    var b: u8[..96] = [];
    b.append(s[..min(s.len, 96)]);
    return b;
}

fn rgba_eq(a: PixelRGBA, b: PixelRGBA) -> bool {
    a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a
}

fn palette_color(idx: i64) -> PixelRGBA {
    if idx == 0  { return PixelRGBA { r: 20,  g: 24,  b: 34,  a: 255 }; } // Deep Ink
    if idx == 1  { return PixelRGBA { r: 255, g: 255, b: 255, a: 255 }; } // Pure White
    if idx == 2  { return PixelRGBA { r: 165, g: 178, b: 198, a: 255 }; } // Cool Silver
    if idx == 3  { return PixelRGBA { r: 78,  g: 92,  b: 118, a: 255 }; } // Slate
    if idx == 4  { return PixelRGBA { r: 239, g: 68,  b: 68,  a: 255 }; } // Crimson
    if idx == 5  { return PixelRGBA { r: 249, g: 115, b: 22,  a: 255 }; } // Tangerine
    if idx == 6  { return PixelRGBA { r: 250, g: 204, b: 21,  a: 255 }; } // Gold
    if idx == 7  { return PixelRGBA { r: 132, g: 204, b: 22,  a: 255 }; } // Lime
    if idx == 8  { return PixelRGBA { r: 16,  g: 185, b: 129, a: 255 }; } // Emerald
    if idx == 9  { return PixelRGBA { r: 6,   g: 182, b: 212, a: 255 }; } // Cyan
    if idx == 10 { return PixelRGBA { r: 59,  g: 130, b: 246, a: 255 }; } // Azure
    if idx == 11 { return PixelRGBA { r: 139, g: 92,  b: 246, a: 255 }; } // Violet
    if idx == 12 { return PixelRGBA { r: 236, g: 72,  b: 153, a: 255 }; } // Magenta
    if idx == 13 { return PixelRGBA { r: 180, g: 112, b: 64,  a: 255 }; } // Chestnut
    if idx == 14 { return PixelRGBA { r: 254, g: 215, b: 170, a: 255 }; } // Peach
    return PixelRGBA { r: 56, g: 189, b: 248, a: 255 };                  // Sky Glow
}

fn push_snapshot(st: StudioState&) {
    let snap = Snapshot { grid_n: st.grid_n, pixels: st.pixels };
    if st.hist_pos < st.hist_len {
        st.hist_len = st.hist_pos;
    }
    if st.hist_len < MAX_HIST {
        st.history[st.hist_len] = snap;
        st.hist_len++;
        st.hist_pos = st.hist_len;
    } else {
        for i in MAX_HIST - 1 {
            st.history[i] = st.history[i + 1];
        }
        st.history[MAX_HIST - 1] = snap;
        st.hist_len = MAX_HIST;
        st.hist_pos = MAX_HIST;
    }
}

fn undo(st: StudioState&) -> bool {
    if st.hist_pos <= 1 { return false; }
    st.hist_pos--;
    let snap = st.history[st.hist_pos - 1];
    st.grid_n = snap.grid_n;
    st.pixels = snap.pixels;
    st.status = to_buf96("Undo applied.");
    return true;
}

fn redo(st: StudioState&) -> bool {
    if st.hist_pos >= st.hist_len { return false; }
    let snap = st.history[st.hist_pos];
    st.hist_pos++;
    st.grid_n = snap.grid_n;
    st.pixels = snap.pixels;
    st.status = to_buf96("Redo applied.");
    return true;
}

fn clear_canvas(st: StudioState&) {
    for i in MAX_CELLS { st.pixels[i] = PixelRGBA { r: 0, g: 0, b: 0, a: 0 }; }
    push_snapshot(st);
    st.status = to_buf96("Canvas cleared.");
}

fn set_pixel(st: StudioState&, x: i64, y: i64, col: PixelRGBA) {
    if x < 0 || x >= st.grid_n || y < 0 || y >= st.grid_n { return; }
    st.pixels[y * st.grid_n + x] = col;
    if st.mirror_x {
        let mx = st.grid_n - 1 - x;
        st.pixels[y * st.grid_n + mx] = col;
    }
}

fn apply_brush(st: StudioState&, cx: i64, cy: i64, col: PixelRGBA) {
    set_pixel(st, cx, cy, col);
    if st.brush_size >= 2 {
        set_pixel(st, cx + 1, cy, col);
        set_pixel(st, cx, cy + 1, col);
        set_pixel(st, cx + 1, cy + 1, col);
    }
}

fn flood_fill(st: StudioState&, sx: i64, sy: i64, fill_col: PixelRGBA) -> i64 {
    if sx < 0 || sx >= st.grid_n || sy < 0 || sy >= st.grid_n { return 0; }
    let target = st.pixels[sy * st.grid_n + sx];
    if rgba_eq(target, fill_col) { return 0; }

    var qx: i64[..1024] = [];
    var qy: i64[..1024] = [];
    qx.push(sx);
    qy.push(sy);
    var head: i64 = 0;
    var painted: i64 = 0;

    while head < qx.len {
        let x = qx[head];
        let y = qy[head];
        head++;
        if x < 0 || x >= st.grid_n || y < 0 || y >= st.grid_n { continue; }
        let idx = y * st.grid_n + x;
        if !rgba_eq(st.pixels[idx], target) { continue; }
        st.pixels[idx] = fill_col;
        painted++;
        if qx.len + 4 <= 1024 {
            qx.push(x + 1); qy.push(y);
            qx.push(x - 1); qy.push(y);
            qx.push(x);     qy.push(y + 1);
            qx.push(x);     qy.push(y - 1);
        }
    }
    return painted;
}

fn load_goose_sprite(st: StudioState&) {
    st.grid_n = 16;
    for i in MAX_CELLS { st.pixels[i] = PixelRGBA { r: 0, g: 0, b: 0, a: 0 }; }

    // 16x16 pixel art Goose with red adventurer cap & orange beak/feet
    let rows: const u8[:][16] = [
        ".....RRRRRR.....",
        "....RRRRRRRR....",
        "....RRRRRRRRRR..",
        "....KKKKKKKK....",
        "...KWWWWWWWWK...",
        "...KWWWKWWWWK...",
        "...KWWWWWWWWO...",
        "...KWWWWWWOOO...",
        "....KWWWWWWK....",
        "...KWWWWWWWWK...",
        "..KWWSSSSSSWWK..",
        "..KWWSSSSSSWWK..",
        "...KWWWWWWWWK...",
        "....KKKKKKKK....",
        ".....O....O.....",
        "....OO...OO.....",
    ];

    let c_red = PixelRGBA { r: 239, g: 68, b: 68, a: 255 };
    let c_blk = PixelRGBA { r: 22, g: 26, b: 38, a: 255 };
    let c_wht = PixelRGBA { r: 248, g: 250, b: 252, a: 255 };
    let c_shd = PixelRGBA { r: 203, g: 213, b: 225, a: 255 };
    let c_org = PixelRGBA { r: 249, g: 115, b: 22, a: 255 };
    let c_sky = PixelRGBA { r: 30, g: 41, b: 62, a: 255 };

    for y in 16 {
        for x in 16 {
            let ch = rows[y][x];
            var col = c_sky;
            if ch == 'R' { col = c_red; }
            else if ch == 'K' { col = c_blk; }
            else if ch == 'W' { col = c_wht; }
            else if ch == 'S' { col = c_shd; }
            else if ch == 'O' { col = c_org; }
            st.pixels[y * 16 + x] = col;
        }
    }
    push_snapshot(st);
    st.status = to_buf96("Loaded 16x16 Goose Mascot preset.");
}

fn new_studio() -> StudioState {
    var st = StudioState {
        grid_n: 16,
        pixels: [PixelRGBA { r: 0, g: 0, b: 0, a: 0 }; 576],
        tool: TOOL_BRUSH,
        brush_size: 1,
        mirror_x: false,
        show_grid: true,
        col_r: 249,
        col_g: 115,
        col_b: 22,
        history: [default<Snapshot>(); 16],
        hist_len: 0,
        hist_pos: 0,
        stroke_active: false,
        status: to_buf96("Ready — Click & drag to paint."),
    };
    load_goose_sprite(st);
    return st;
}

fn hex_byte(v: i64) -> u8[>..] {
    let hex = "0123456789ABCDEF";
    let clamped = clamp(v, 0, 255);
    var out: u8[>..] = [];
    out.push(hex[clamped / 16]);
    out.push(hex[clamped % 16]);
    return out;
}

fn build_ppm_bytes(st: const StudioState&) -> u8[>..] {
    var out: u8[>..] = [];
    out.append(str("P6\n", st.grid_n, " ", st.grid_n, "\n255\n"));
    for y in st.grid_n {
        for x in st.grid_n {
            let p = st.pixels[y * st.grid_n + x];
            if p.a == 0 {
                out.push(18); out.push(22); out.push(32);
            } else {
                out.push(p.r); out.push(p.g); out.push(p.b);
            }
        }
    }
    return out;
}

fn make_btn_style(base: ui::StyleButton, bg: ui::Color, hover_bg: ui::Color,
                  active_bg: ui::Color, border_c: ui::Color, fg: ui::Color) -> ui::StyleButton {
    var b = base;
    b.normal = ui::style_item_color(bg);
    b.hover = ui::style_item_color(hover_bg);
    b.active = ui::style_item_color(active_bg);
    b.border_color = border_c;
    b.border = 1.0;
    b.rounding = 6.0;
    b.text_normal = fg;
    b.text_hover = fg;
    b.text_active = fg;
    b.text_background = bg;
    return b;
}

fn run_tests() {
    var st = new_studio();
    check(st.grid_n == 16 && st.hist_len >= 1, "studio initialization failed");

    // Test mirror-X brush + undo/redo
    clear_canvas(st);
    st.mirror_x = true;
    apply_brush(st, 2, 3, PixelRGBA { r: 255, g: 0, b: 0, a: 255 });
    push_snapshot(st);
    check(st.pixels[3 * 16 + 2].r == 255 && st.pixels[3 * 16 + 13].r == 255,
          "mirror-X brush symmetry failed");
    check(undo(st) && st.pixels[3 * 16 + 2].a == 0, "undo failed to clear painted stroke");
    check(redo(st) && st.pixels[3 * 16 + 2].r == 255, "redo failed to restore painted stroke");

    // Test non-recursive flood fill
    clear_canvas(st);
    let filled = flood_fill(st, 0, 0, PixelRGBA { r: 10, g: 20, b: 30, a: 255 });
    check(filled == 256, "flood fill on blank 16x16 must paint 256 cells");

    // Test PPM P6 export header & exact byte payload size
    let ppm = build_ppm_bytes(st);
    let expected_header = "P6\n16 16\n255\n";
    check(starts_with(ppm, expected_header) && ppm.len == expected_header.len + 16 * 16 * 3,
          "PPM export size/header invalid");

    print("PASS pixel_studio (brush, mirror-X, flood fill, undo/redo, PPM export)\n");
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

    guard gfx::open("Goose Pixel Studio", 980, 640, gfx::WINDOW_RESIZABLE) else {
        write_stderr(str("gfx: ", gfx::error(), "\n"));
        return;
    }
    defer gfx::close();

    var ctx = ui::create_from_memory(FONT, 17.0);
    guard ctx.id != 0 else {
        write_stderr(str("ui: ", ui::error(), "\n"));
        return;
    }
    defer ui::destroy(ctx);

    let init_pixels = gfx::screen_size();
    let base_w: f32 = 980.0;
    var dpi_scale: f32 = init_pixels.x / base_w;
    if dpi_scale < 0.5 { dpi_scale = 1.0; }
    if dpi_scale > 4.0 { dpi_scale = 4.0; }
    if dpi_scale != ui::scale(ctx) { ui::set_scale(ctx, dpi_scale); }

    var colors = ui::default_color_table();
    colors[ui::COLOR_WINDOW] = ui::rgb(20, 23, 31);
    colors[ui::COLOR_HEADER] = ui::rgb(27, 32, 44);
    colors[ui::COLOR_BORDER] = ui::rgb(48, 56, 74);
    colors[ui::COLOR_TEXT] = ui::rgb(236, 242, 250);
    ui::style_from_table(ctx, colors);

    var root_st = ui::style(ctx);
    root_st.window.fixed_background = ui::style_item_color(ui::rgb(20, 23, 31));
    root_st.window.group_border = 1.0;
    root_st.window.group_border_color = ui::rgb(48, 56, 74);
    root_st.window.padding = float2 { 12.0, 10.0 };
    root_st.window.group_padding = float2 { 10.0, 10.0 };
    root_st.window.spacing = float2 { 8.0, 8.0 };
    ui::set_style(ctx, root_st);

    let white = ui::rgb(248, 250, 252);
    let dim_c = ui::rgb(148, 163, 184);
    let border_c = ui::rgb(52, 62, 82);
    let btn_idle = make_btn_style(root_st.button, ui::rgb(34, 40, 54), ui::rgb(48, 56, 76),
                                  ui::rgb(28, 33, 44), border_c, white);
    let btn_active = make_btn_style(root_st.button, ui::rgb(37, 99, 235), ui::rgb(59, 130, 246),
                                    ui::rgb(29, 78, 216), ui::rgb(96, 165, 250), white);
    let btn_ok = make_btn_style(root_st.button, ui::rgb(16, 150, 104), ui::rgb(20, 175, 120),
                                ui::rgb(12, 120, 84), ui::rgb(52, 211, 153), white);
    let btn_warn = make_btn_style(root_st.button, ui::rgb(155, 48, 56), ui::rgb(185, 58, 68),
                                  ui::rgb(125, 36, 44), ui::rgb(248, 113, 113), white);

    var studio = new_studio();
    if demo_mode {
        studio.status = to_buf96("16x16 Goose Mascot · Ready to paint or export PPM.");
    }

    var has_window = false;
    var drawn: i64 = 0;

    while gfx::frame() {
        if gfx::key_pressed("Escape") { break; }
        ui::input_from_gfx(ctx);

        let px = gfx::screen_size();
        let sc = ui::scale(ctx);
        let bounds = ui::rect(0.0, 0.0, px.x / sc, px.y / sc);
        if has_window { ui::window_set_bounds(ctx, "PixelStudioRoot", bounds); }

        if ui::begin(ctx, "PixelStudioRoot", bounds, ui::WINDOW_NO_SCROLLBAR) {
            has_window = true;
            let content = ui::window_get_content_region_size(ctx);

            // Top Bar
            let top_ratios: f32[8] = [0.22, 0.11, 0.11, 0.11, 0.10, 0.10, 0.10, 0.15];
            ui::layout_row(ctx, ui::DYNAMIC, 34.0, top_ratios);
            ui::label_colored(ctx, "Goose Pixel Studio", ui::TEXT_LEFT, white);
            if ui::button_label_styled(ctx, if studio.grid_n == 16 { btn_active } else { btn_idle }, "16x16") {
                if studio.grid_n != 16 {
                    studio.grid_n = 16;
                    push_snapshot(studio);
                }
            }
            if ui::button_label_styled(ctx, if studio.grid_n == 24 { btn_active } else { btn_idle }, "24x24") {
                if studio.grid_n != 24 {
                    studio.grid_n = 24;
                    push_snapshot(studio);
                }
            }
            if ui::button_label_styled(ctx, if studio.show_grid { btn_active } else { btn_idle }, "Grid") {
                studio.show_grid = !studio.show_grid;
            }
            if ui::button_label_styled(ctx, btn_idle, "Undo") { let _ = undo(studio); }
            if ui::button_label_styled(ctx, btn_idle, "Redo") { let _ = redo(studio); }
            if ui::button_label_styled(ctx, btn_warn, "Clear") { clear_canvas(studio); }
            if ui::button_label_styled(ctx, btn_ok, "Export PPM") {
                let ppm = build_ppm_bytes(studio);
                if write_file_atomic("pixel_studio_export.ppm", ppm) {
                    studio.status = to_buf96("Exported pixel_studio_export.ppm");
                } else {
                    studio.status = to_buf96("Export failed.");
                }
            }

            // Main 3-Pane Body
            var body_h = content.y - 90.0;
            if body_h < 300.0 { body_h = 300.0; }
            let cols_ratio: f32[3] = [0.18, 0.54, 0.28];
            ui::layout_row(ctx, ui::DYNAMIC, body_h, cols_ratio);

            // Left Tool Rail
            if ui::group_begin(ctx, "ToolRail", ui::WINDOW_BORDER) {
                ui::layout_row_dynamic(ctx, 22.0, 1);
                ui::label_colored(ctx, "Tools", ui::TEXT_LEFT, dim_c);

                ui::layout_row_dynamic(ctx, 36.0, 1);
                if ui::button_label_styled(ctx, if studio.tool == TOOL_BRUSH { btn_active } else { btn_idle }, "Brush") {
                    studio.tool = TOOL_BRUSH;
                }
                if ui::button_label_styled(ctx, if studio.tool == TOOL_ERASER { btn_active } else { btn_idle }, "Eraser") {
                    studio.tool = TOOL_ERASER;
                }
                if ui::button_label_styled(ctx, if studio.tool == TOOL_FILL { btn_active } else { btn_idle }, "Fill Bucket") {
                    studio.tool = TOOL_FILL;
                }
                if ui::button_label_styled(ctx, if studio.tool == TOOL_PICKER { btn_active } else { btn_idle }, "Eyedropper") {
                    studio.tool = TOOL_PICKER;
                }

                ui::layout_row_dynamic(ctx, 22.0, 1);
                ui::label_colored(ctx, "Options", ui::TEXT_LEFT, dim_c);
                ui::layout_row_dynamic(ctx, 34.0, 2);
                if ui::button_label_styled(ctx, if studio.brush_size == 1 { btn_active } else { btn_idle }, "1px") {
                    studio.brush_size = 1;
                }
                if ui::button_label_styled(ctx, if studio.brush_size == 2 { btn_active } else { btn_idle }, "2px") {
                    studio.brush_size = 2;
                }

                ui::layout_row_dynamic(ctx, 34.0, 1);
                if ui::button_label_styled(ctx, if studio.mirror_x { btn_active } else { btn_idle },
                                           if studio.mirror_x { "Mirror X: ON" } else { "Mirror X: OFF" }) {
                    studio.mirror_x = !studio.mirror_x;
                }

                ui::layout_row_dynamic(ctx, 22.0, 1);
                ui::label_colored(ctx, "Preset", ui::TEXT_LEFT, dim_c);
                ui::layout_row_dynamic(ctx, 36.0, 1);
                if ui::button_label_styled(ctx, btn_idle, "Goose Sprite") {
                    load_goose_sprite(studio);
                }
                ui::group_end(ctx);
            }

            // Center Pixel Canvas
            if ui::group_begin(ctx, "CanvasPane", ui::WINDOW_BORDER) {
                var c_h = body_h - 24.0;
                if c_h < 200.0 { c_h = 200.0; }
                ui::layout_row_dynamic(ctx, c_h, 1);
                let _, cbox = ui::widget(ctx);
                let side = min(cbox.w - 16.0, cbox.h - 16.0);
                let cell_sz = side / studio.grid_n;
                let grid_px = cell_sz * studio.grid_n;
                let gx0 = cbox.x + (cbox.w - grid_px) * 0.5;
                let gy0 = cbox.y + (cbox.h - grid_px) * 0.5;

                // Backdrop frame
                ui::stroke_rect(ctx, ui::rect(gx0 - 2.0, gy0 - 2.0, grid_px + 4.0, grid_px + 4.0),
                                2.0, 2.0, ui::rgb(68, 82, 108));

                for py in studio.grid_n {
                    for px_i in studio.grid_n {
                        let rx = gx0 + px_i * cell_sz;
                        let ry = gy0 + py * cell_sz;
                        let cell_r = ui::rect(rx, ry, cell_sz, cell_sz);
                        let p = studio.pixels[py * studio.grid_n + px_i];
                        if p.a == 0 {
                            let chk = if (px_i + py) % 2 == 0 {
                                ui::rgb(30, 35, 48)
                            } else {
                                ui::rgb(38, 44, 60)
                            };
                            ui::fill_rect(ctx, cell_r, 0.0, chk);
                        } else {
                            ui::fill_rect(ctx, cell_r, 0.0, ui::rgba(p.r, p.g, p.b, p.a));
                        }
                        if studio.show_grid {
                            ui::stroke_rect(ctx, cell_r, 0.0, 1.0, ui::rgba(255, 255, 255, 16));
                        }
                    }
                }

                // Mouse interaction inside canvas
                let mouse = ui::input_mouse(ctx);
                let mx = mouse.pos.x;
                let my = mouse.pos.y;
                let over_grid = mx >= gx0 && mx < gx0 + grid_px && my >= gy0 && my < gy0 + grid_px;
                if over_grid {
                    let hx = clamp(((mx - gx0) / cell_sz) as! i64, 0, studio.grid_n - 1);
                    let hy = clamp(((my - gy0) / cell_sz) as! i64, 0, studio.grid_n - 1);
                    ui::stroke_rect(ctx, ui::rect(gx0 + hx * cell_sz, gy0 + hy * cell_sz, cell_sz, cell_sz),
                                    0.0, 2.0, ui::rgb(255, 255, 255));

                    let left_down = ui::input_is_mouse_down(ctx, ui::BUTTON_LEFT);
                    let right_down = ui::input_is_mouse_down(ctx, ui::BUTTON_RIGHT);
                    let left_pressed = ui::input_is_mouse_pressed(ctx, ui::BUTTON_LEFT);

                    if left_pressed {
                        if studio.tool == TOOL_FILL {
                            let fill_c = PixelRGBA {
                                r: studio.col_r as u8,
                                g: studio.col_g as u8,
                                b: studio.col_b as u8,
                                a: 255,
                            };
                            let n = flood_fill(studio, hx, hy, fill_c);
                            if n > 0 {
                                push_snapshot(studio);
                                studio.status = to_buf96(str("Flood filled ", n, " cells."));
                            }
                        } else if studio.tool == TOOL_PICKER {
                            let picked = studio.pixels[hy * studio.grid_n + hx];
                            if picked.a > 0 {
                                studio.col_r = picked.r;
                                studio.col_g = picked.g;
                                studio.col_b = picked.b;
                                studio.tool = TOOL_BRUSH;
                                studio.status = to_buf96(str("Picked #", hex_byte(studio.col_r),
                                                             hex_byte(studio.col_g), hex_byte(studio.col_b)));
                            }
                        } else {
                            studio.stroke_active = true;
                        }
                    }

                    if left_down && (studio.tool == TOOL_BRUSH || studio.tool == TOOL_ERASER) {
                        let col = if studio.tool == TOOL_ERASER {
                            PixelRGBA { r: 0, g: 0, b: 0, a: 0 }
                        } else {
                            PixelRGBA { r: studio.col_r as u8, g: studio.col_g as u8, b: studio.col_b as u8, a: 255 }
                        };
                        apply_brush(studio, hx, hy, col);
                    } else if right_down {
                        if !studio.stroke_active { studio.stroke_active = true; }
                        apply_brush(studio, hx, hy, PixelRGBA { r: 0, g: 0, b: 0, a: 0 });
                    }
                }

                if studio.stroke_active && !ui::input_is_mouse_down(ctx, ui::BUTTON_LEFT) &&
                   !ui::input_is_mouse_down(ctx, ui::BUTTON_RIGHT) {
                    studio.stroke_active = false;
                    push_snapshot(studio);
                }

                ui::group_end(ctx);
            }

            // Right Preview + Palette + RGB Sliders
            if ui::group_begin(ctx, "InspectorPane", ui::WINDOW_BORDER) {
                ui::layout_row_dynamic(ctx, 20.0, 1);
                ui::label_colored(ctx, "Live Sprite Preview (1:1)", ui::TEXT_LEFT, dim_c);

                ui::layout_row_dynamic(ctx, 132.0, 1);
                let _, pbox = ui::widget(ctx);
                let p_side = min(pbox.w - 16.0, pbox.h - 8.0);
                let p_cell = p_side / studio.grid_n;
                let px0 = pbox.x + (pbox.w - p_cell * studio.grid_n) * 0.5;
                let py0 = pbox.y + (pbox.h - p_cell * studio.grid_n) * 0.5;
                ui::fill_rect(ctx, ui::rect(px0 - 4.0, py0 - 4.0, p_cell * studio.grid_n + 8.0,
                                            p_cell * studio.grid_n + 8.0), 6.0, ui::rgb(14, 17, 25));
                for y in studio.grid_n {
                    for x in studio.grid_n {
                        let p = studio.pixels[y * studio.grid_n + x];
                        if p.a > 0 {
                            ui::fill_rect(ctx, ui::rect(px0 + x * p_cell, py0 + y * p_cell,
                                                        p_cell + 0.5, p_cell + 0.5),
                                          0.0, ui::rgba(p.r, p.g, p.b, p.a));
                        }
                    }
                }

                // Active Color Swatch + Hex
                let hex_lbl = str("#", hex_byte(studio.col_r), hex_byte(studio.col_g),
                                  hex_byte(studio.col_b));
                ui::layout_row_dynamic(ctx, 26.0, 2);
                ui::label_colored(ctx, "Active Color", ui::TEXT_LEFT, dim_c);
                ui::label_colored(ctx, hex_lbl, ui::TEXT_RIGHT, white);

                ui::layout_row_dynamic(ctx, 26.0, 1);
                let _, sw_rect = ui::widget(ctx);
                ui::fill_rect(ctx, sw_rect, 6.0, ui::rgb(studio.col_r, studio.col_g, studio.col_b));
                ui::stroke_rect(ctx, sw_rect, 6.0, 1.0, border_c);

                // 16-Color Palette Grid (4x4)
                ui::layout_row_dynamic(ctx, 20.0, 1);
                ui::label_colored(ctx, "Palette", ui::TEXT_LEFT, dim_c);
                for row in 4 {
                    ui::layout_row_dynamic(ctx, 26.0, 4);
                    for col_i in 4 {
                        let pc = palette_color(row * 4 + col_i);
                        if ui::button_color(ctx, ui::rgb(pc.r, pc.g, pc.b)) {
                            studio.col_r = pc.r;
                            studio.col_g = pc.g;
                            studio.col_b = pc.b;
                            if studio.tool == TOOL_ERASER { studio.tool = TOOL_BRUSH; }
                        }
                    }
                }

                // RGB Sliders
                ui::layout_row_dynamic(ctx, 24.0, 1);
                let _ = ui::property_int(ctx, "#Red:", 0, studio.col_r, 255, 1, 1.0);
                let _ = ui::property_int(ctx, "#Green:", 0, studio.col_g, 255, 1, 1.0);
                let _ = ui::property_int(ctx, "#Blue:", 0, studio.col_b, 255, 1, 1.0);

                ui::group_end(ctx);
            }

            // Bottom Status Bar
            ui::layout_row_dynamic(ctx, 22.0, 1);
            ui::label_colored(ctx, str(studio.status, "  |  Left Click: Paint  ·  Right Click: Erase"),
                              ui::TEXT_LEFT, dim_c);
        }
        ui::end(ctx);

        gfx::begin_screen(float4 { 0.07, 0.08, 0.11, 1.0 });
        gfx::end_pass();
        ui::render(ctx);

        drawn++;
        if frames > 0 && drawn >= frames { break; }
    }

    if screenshot_path.len > 0 {
        let ok = gfx::screenshot(screenshot_path);
        check(ok, "failed to save pixel_studio screenshot");
    }
}

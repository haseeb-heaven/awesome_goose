// neon_breakout: 2D GPU Arcade Breakout in Goose (gfx + ui + audio).
//
// Features:
//   - Batched dynamic 2D GPU quad pipeline (custom GLSL shaders compiled to MSL/SPIR-V/HLSL)
//   - 6x10 Neon Brick grid (including armored 2-hit top rows), paddle, ball trail, sparks
//   - Retina-scaled transparent HUD overlay (Score, Combo, Level, Lives)
//   - Procedural Web/SDL3 PCM sound effects via audio module
//   - CLI flags: --test, --demo, --frames N, --screenshot <path>

import std;
import vec;
import math;
import os;
import gfx;
import ui;
import audio;

let FONT: const u8[:] = embed_file("../../../assets/Roboto-Regular.ttf");

let WORLD_W: f32 = 800.0;
let WORLD_H: f32 = 600.0;
let COLS: i64 = 10;
let ROWS: i64 = 6;
let BRICK_COUNT: i64 = 60;
let MAX_VERTS: i64 = 8192;
let MAX_SPARKS: i64 = 96;
let TRAIL_LEN: i64 = 10;

struct Vertex2D { pos: float2, color: u8[4] }
struct OrthoUniform { screen: float4 }

struct Brick {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    hp: i64,
    color: u8[4],
}

struct Spark {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    life: f32,
    max_life: f32,
    color: u8[4],
}

struct BreakoutGame {
    bricks: Brick[60],
    sparks: Spark[96],
    trail: float2[10],
    paddle_x: f32,
    paddle_w: f32,
    paddle_h: f32,
    ball_x: f32,
    ball_y: f32,
    ball_vx: f32,
    ball_vy: f32,
    ball_r: f32,
    launched: bool,
    paused: bool,
    game_over: bool,
    score: i64,
    combo: i64,
    lives: i64,
    level: i64,
    remaining_bricks: i64,
    prng: rng,
    hit_paddle: bool,
    hit_brick: bool,
    hit_wall: bool,
}

fn check(ok: bool, msg: const u8[:]) {
    if !ok { abort(msg); }
}

fn row_color(r: i64) -> u8[4] {
    if r == 0 { return [255, 78, 125, 255]; }
    if r == 1 { return [255, 145, 58, 255]; }
    if r == 2 { return [250, 212, 62, 255]; }
    if r == 3 { return [54, 226, 178, 255]; }
    if r == 4 { return [62, 180, 255, 255]; }
    return [165, 112, 255, 255];
}

fn reset_bricks(g: BreakoutGame&) {
    let margin_x: f32 = 40.0;
    let gap: f32 = 8.0;
    let total_w = WORLD_W - margin_x * 2.0 - gap * (COLS - 1);
    let bw = total_w / COLS;
    let bh: f32 = 24.0;
    let start_y: f32 = 84.0;
    g.remaining_bricks = 0;

    for r in ROWS {
        let col = row_color(r);
        let hp: i64 = if r < 2 { 2 } else { 1 };
        for c in COLS {
            let idx = r * COLS + c;
            g.bricks[idx] = Brick {
                x: margin_x + c * (bw + gap),
                y: start_y + r * (bh + gap),
                w: bw,
                h: bh,
                hp: hp,
                color: col,
            };
            g.remaining_bricks++;
        }
    }
}

fn reset_ball(g: BreakoutGame&) {
    g.launched = false;
    g.ball_x = g.paddle_x;
    g.ball_y = WORLD_H - 58.0;
    let spd = 330.0 + ((g.level - 1) as f32) * 35.0;
    g.ball_vx = spd * 0.62;
    g.ball_vy = -spd * 0.78;
    for i in TRAIL_LEN {
        g.trail[i] = float2 { g.ball_x, g.ball_y };
    }
}

fn new_game(seed: u64) -> BreakoutGame {
    var g = BreakoutGame {
        bricks: [default<Brick>(); 60],
        sparks: [default<Spark>(); 96],
        trail: [float2 { 400.0, 542.0 }; 10],
        paddle_x: 400.0,
        paddle_w: 118.0,
        paddle_h: 14.0,
        ball_x: 400.0,
        ball_y: 542.0,
        ball_vx: 220.0,
        ball_vy: -280.0,
        ball_r: 8.0,
        launched: false,
        paused: false,
        game_over: false,
        score: 0,
        combo: 0,
        lives: 3,
        level: 1,
        remaining_bricks: BRICK_COUNT,
        prng: rng { seed },
        hit_paddle: false,
        hit_brick: false,
        hit_wall: false,
    };
    reset_bricks(g);
    reset_ball(g);
    return g;
}

fn emit_sparks(g: BreakoutGame&, x: f32, y: f32, col: u8[4], count: i64) {
    var spawned: i64 = 0;
    for i in MAX_SPARKS {
        if spawned >= count { break; }
        if g.sparks[i].life <= 0.0 {
            let ang = (g.prng.rand_flt() * TAU) as f32;
            let spd = 80.0 + (g.prng.rand_flt() * 200.0) as f32;
            g.sparks[i] = Spark {
                x: x,
                y: y,
                vx: cos(ang) * spd,
                vy: sin(ang) * spd,
                life: 0.42,
                max_life: 0.42,
                color: col,
            };
            spawned++;
        }
    }
}

fn step_game(g: BreakoutGame&, dt: f32, move_dir: f32, demo_ai: bool) {
    g.hit_paddle = false;
    g.hit_brick = false;
    g.hit_wall = false;
    if g.paused || g.game_over { return; }

    // Update sparks
    for i in MAX_SPARKS {
        if g.sparks[i].life > 0.0 {
            g.sparks[i].x += g.sparks[i].vx * dt;
            g.sparks[i].y += g.sparks[i].vy * dt;
            g.sparks[i].vy += 260.0 * dt;
            g.sparks[i].life -= dt;
        }
    }

    // Move paddle
    if demo_ai {
        let diff = g.ball_x - g.paddle_x;
        let max_step = 540.0 * dt;
        if abs(diff) > max_step {
            g.paddle_x += (if diff > 0.0 { max_step } else { -max_step });
        } else {
            g.paddle_x = g.ball_x;
        }
    } else {
        g.paddle_x += move_dir * 560.0 * dt;
    }
    let half_p = g.paddle_w * 0.5;
    if g.paddle_x < half_p + 14.0 { g.paddle_x = half_p + 14.0; }
    if g.paddle_x > WORLD_W - half_p - 14.0 { g.paddle_x = WORLD_W - half_p - 14.0; }

    if !g.launched {
        g.ball_x = g.paddle_x;
        g.ball_y = WORLD_H - 58.0;
        return;
    }

    // Shift trail
    var t = TRAIL_LEN - 1;
    while t > 0 {
        g.trail[t] = g.trail[t - 1];
        t--;
    }
    g.trail[0] = float2 { g.ball_x, g.ball_y };

    // Integrate ball
    g.ball_x += g.ball_vx * dt;
    g.ball_y += g.ball_vy * dt;

    // Wall collisions
    if g.ball_x - g.ball_r < 12.0 {
        g.ball_x = 12.0 + g.ball_r;
        g.ball_vx = abs(g.ball_vx);
        g.hit_wall = true;
    } else if g.ball_x + g.ball_r > WORLD_W - 12.0 {
        g.ball_x = WORLD_W - 12.0 - g.ball_r;
        g.ball_vx = -abs(g.ball_vx);
        g.hit_wall = true;
    }
    if g.ball_y - g.ball_r < 54.0 {
        g.ball_y = 54.0 + g.ball_r;
        g.ball_vy = abs(g.ball_vy);
        g.hit_wall = true;
    }

    // Paddle collision
    let py = WORLD_H - 42.0;
    if g.ball_vy > 0.0 && g.ball_y + g.ball_r >= py && g.ball_y - g.ball_r <= py + g.paddle_h {
        if g.ball_x >= g.paddle_x - half_p - g.ball_r &&
           g.ball_x <= g.paddle_x + half_p + g.ball_r {
            let rel = clamp((g.ball_x - g.paddle_x) / half_p, -0.95, 0.95);
            let spd = hypot(g.ball_vx, g.ball_vy);
            let ang = rel * 1.05;
            g.ball_vx = sin(ang) * spd;
            g.ball_vy = -cos(ang) * spd;
            g.ball_y = py - g.ball_r;
            g.combo = 0;
            g.hit_paddle = true;
            emit_sparks(g, g.ball_x, py, [100, 235, 255, 255], 6);
        }
    }

    // Brick collisions
    for i in BRICK_COUNT {
        if g.bricks[i].hp <= 0 { continue; }
        let b = g.bricks[i];
        let cx = clamp(g.ball_x, b.x, b.x + b.w);
        let cy = clamp(g.ball_y, b.y, b.y + b.h);
        let dx = g.ball_x - cx;
        let dy = g.ball_y - cy;
        if dx * dx + dy * dy <= g.ball_r * g.ball_r {
            if abs(dx) > abs(dy) {
                g.ball_vx = -g.ball_vx;
            } else {
                g.ball_vy = -g.ball_vy;
            }
            g.bricks[i].hp -= 1;
            g.combo++;
            g.score += 50 * g.combo;
            g.hit_brick = true;
            emit_sparks(g, b.x + b.w * 0.5, b.y + b.h * 0.5, b.color, 12);
            if g.bricks[i].hp <= 0 {
                g.remaining_bricks -= 1;
            }
            break;
        }
    }

    if g.remaining_bricks <= 0 {
        g.level++;
        g.score += 500;
        reset_bricks(g);
        reset_ball(g);
        if demo_ai { g.launched = true; }
        return;
    }

    // Missed ball
    if g.ball_y - g.ball_r > WORLD_H {
        g.lives -= 1;
        g.combo = 0;
        if g.lives <= 0 {
            g.game_over = true;
        } else {
            reset_ball(g);
            if demo_ai { g.launched = true; }
        }
    }
}

fn push_quad(verts: Vertex2D[>..]&, x: f32, y: f32, w: f32, h: f32, col: u8[4]) {
    if verts.len + 6 > MAX_VERTS { return; }
    let x1 = x + w;
    let y1 = y + h;
    verts.push(Vertex2D { pos: float2 { x, y }, color: col });
    verts.push(Vertex2D { pos: float2 { x1, y }, color: col });
    verts.push(Vertex2D { pos: float2 { x1, y1 }, color: col });
    verts.push(Vertex2D { pos: float2 { x, y }, color: col });
    verts.push(Vertex2D { pos: float2 { x1, y1 }, color: col });
    verts.push(Vertex2D { pos: float2 { x, y1 }, color: col });
}

fn render_geometry(g: const BreakoutGame&, verts: Vertex2D[>..]&) {
    verts.clear();

    // Subtle arena border & cyber background grid
    let grid_col: u8[4] = [26, 36, 58, 120];
    var gx: f32 = 40.0;
    while gx < WORLD_W {
        push_quad(verts, gx, 54.0, 1.0, WORLD_H - 54.0, grid_col);
        gx += 40.0;
    }
    var gy: f32 = 94.0;
    while gy < WORLD_H {
        push_quad(verts, 12.0, gy, WORLD_W - 24.0, 1.0, grid_col);
        gy += 40.0;
    }

    // Arena walls
    let wall_col: u8[4] = [70, 180, 255, 210];
    push_quad(verts, 8.0, 50.0, 4.0, WORLD_H - 50.0, wall_col);
    push_quad(verts, WORLD_W - 12.0, 50.0, 4.0, WORLD_H - 50.0, wall_col);
    push_quad(verts, 8.0, 50.0, WORLD_W - 16.0, 4.0, wall_col);

    // Bricks
    for i in BRICK_COUNT {
        let b = g.bricks[i];
        if b.hp <= 0 { continue; }
        push_quad(verts, b.x, b.y, b.w, b.h, b.color);
        let rim: u8[4] = [255, 255, 255, if b.hp > 1 { 150 } else { 70 }];
        push_quad(verts, b.x + 2.0, b.y + 2.0, b.w - 4.0, 4.0, rim);
        if b.hp > 1 {
            push_quad(verts, b.x + 10.0, b.y + b.h * 0.5 - 2.0, b.w - 20.0, 4.0,
                      [255, 255, 255, 200]);
        }
    }

    // Sparks
    for i in MAX_SPARKS {
        let s = g.sparks[i];
        if s.life > 0.0 {
            let a = (clamp(s.life / s.max_life, 0.0, 1.0) * 255.0) as u8;
            let sz = 3.0 + 4.0 * (s.life / s.max_life);
            let scol: u8[4] = [s.color[0], s.color[1], s.color[2], a];
            push_quad(verts, s.x - sz * 0.5, s.y - sz * 0.5, sz, sz, scol);
        }
    }

    // Ball motion trail
    for i in TRAIL_LEN {
        let p = g.trail[i];
        let frac = 1.0 - (i as f32) / TRAIL_LEN;
        let r = g.ball_r * (0.4 + 0.5 * frac);
        let a = (frac * 120.0) as u8;
        let tcol: u8[4] = [90, 225, 255, a];
        push_quad(verts, p.x - r, p.y - r, r * 2.0, r * 2.0, tcol);
    }

    // Ball
    push_quad(verts, g.ball_x - g.ball_r - 2.0, g.ball_y - g.ball_r - 2.0,
              (g.ball_r + 2.0) * 2.0, (g.ball_r + 2.0) * 2.0, [90, 225, 255, 90]);
    push_quad(verts, g.ball_x - g.ball_r, g.ball_y - g.ball_r,
              g.ball_r * 2.0, g.ball_r * 2.0, [245, 252, 255, 255]);

    // Paddle
    let px = g.paddle_x - g.paddle_w * 0.5;
    let py = WORLD_H - 42.0;
    push_quad(verts, px - 4.0, py - 3.0, g.paddle_w + 8.0, g.paddle_h + 6.0, [50, 200, 255, 65]);
    push_quad(verts, px, py, g.paddle_w, g.paddle_h, [70, 210, 255, 255]);
    push_quad(verts, px + 6.0, py + 2.0, g.paddle_w - 12.0, 4.0, [230, 250, 255, 220]);
}

fn build_tone(freq: f64, dur_s: f64) -> f32[>..] {
    let rate = 48000;
    let n = (dur_s * rate) as i64;
    var pcm: f32[>..] = [];
    for i in n {
        let t = i / (rate as f64);
        let env = 1.0 - (i / (n as f64));
        pcm.push((sin(TAU * freq * t) * 0.2 * env) as f32);
    }
    return pcm;
}

fn run_tests() {
    var g = new_game(123);
    check(g.remaining_bricks == 60, "initial brick count must be 60");
    g.launched = true;

    // Force a brick hit and check score/combo increment
    g.ball_x = g.bricks[55].x + g.bricks[55].w * 0.5;
    g.ball_y = g.bricks[55].y + g.bricks[55].h + g.ball_r - 1.0;
    g.ball_vx = 0.0;
    g.ball_vy = -100.0;
    step_game(g, 0.016, 0.0, false);
    check(g.hit_brick && g.score == 50 && g.remaining_bricks == 59,
          "brick hit must decrement brick count and award 50 pts");

    // Force paddle bounce
    g.ball_x = g.paddle_x + 20.0;
    g.ball_y = WORLD_H - 42.0 - g.ball_r + 1.0;
    g.ball_vy = 200.0;
    step_game(g, 0.016, 0.0, false);
    check(g.hit_paddle && g.ball_vy < 0.0, "paddle bounce must reverse vertical velocity");

    // Test vertex batching
    var verts: Vertex2D[>..] = [];
    render_geometry(g, verts);
    check(verts.len > 300 && verts.len <= MAX_VERTS, "vertex batch size invalid");

    print("PASS neon_breakout (60 bricks, collision, paddle physics, sparks, GPU batching)\n");
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

    guard gfx::open("Goose Neon Breakout", 800, 600, gfx::WINDOW_RESIZABLE) else {
        write_stderr(str("gfx: ", gfx::error(), "\n"));
        return;
    }
    defer gfx::close();

    var ctx = ui::create_from_memory(FONT, 18.0);
    guard ctx.id != 0 else {
        write_stderr(str("ui: ", ui::error(), "\n"));
        return;
    }
    defer ui::destroy(ctx);

    let init_pixels = gfx::screen_size();
    let base_w: f32 = 800.0;
    var dpi_scale: f32 = init_pixels.x / base_w;
    if dpi_scale < 0.5 { dpi_scale = 1.0; }
    if dpi_scale > 4.0 { dpi_scale = 4.0; }
    if dpi_scale != ui::scale(ctx) {
        ui::set_scale(ctx, dpi_scale);
    }

    var hud_style = ui::style(ctx);
    hud_style.window.fixed_background = ui::style_item_hide();
    hud_style.window.padding = float2 { 16.0, 10.0 };
    ui::set_style(ctx, hud_style);

    let vs = embed_shader("vert", """
        layout(location = 0) in vec2 a_pos;
        layout(location = 1) in vec4 a_color;
        layout(set = 1, binding = 0) uniform Ortho {
            vec4 screen;
        };
        layout(location = 0) out vec4 v_color;
        void main() {
            float nx = (a_pos.x / screen.x) * 2.0 - 1.0;
            float ny = 1.0 - (a_pos.y / screen.y) * 2.0;
            v_color = a_color;
            gl_Position = vec4(nx, ny, 0.0, 1.0);
        }
    """);
    let fs = embed_shader("frag", """
        layout(location = 0) in vec4 v_color;
        layout(location = 0) out vec4 out_color;
        void main() {
            out_color = v_color;
        }
    """);

    var desc = gfx::PipelineDesc { blend: gfx::BLEND_ALPHA };
    desc.formats[1] = gfx::VERTEX_UBYTE4_NORM;
    let pipe = gfx::pipeline(vs, fs, desc);
    defer gfx::release(pipe);

    let one: Vertex2D[1] = [default<Vertex2D>()];
    let empty: u8[>..] = [];
    let vb = gfx::buffer(gfx::BUFFER_VERTEX, MAX_VERTS * bytes_of(one).len, empty);
    defer gfx::release(vb);

    var use_audio = screenshot_path.len == 0 && audio::available();
    var sfx_paddle = audio::Sound { id: 0 };
    var sfx_brick = audio::Sound { id: 0 };
    if use_audio {
        if audio::open() {
            sfx_paddle = audio::create_sound(build_tone(440.0, 0.06));
            sfx_brick = audio::create_sound(build_tone(660.0, 0.07));
        } else {
            use_audio = false;
        }
    }
    defer {
        if use_audio {
            audio::release_sound(sfx_paddle);
            audio::release_sound(sfx_brick);
            audio::close();
        }
    }

    var game = new_game(if demo_mode { 777 } else { random_seed() });
    if demo_mode {
        game.launched = true;
        // Pre-clear a lively pocket and aim toward bricks so demo frame captures impact sparks
        for r in 4..6 {
            for c in 3..7 {
                game.bricks[r * COLS + c].hp = 0;
                game.remaining_bricks -= 1;
            }
        }
        game.score = 650;
        game.combo = 3;
        game.ball_x = 395.0;
        game.ball_y = 265.0;
        game.ball_vx = 185.0;
        game.ball_vy = -295.0;
    }

    var verts: Vertex2D[>..] = [];
    var drawn: i64 = 0;
    var has_hud = false;

    while gfx::frame() {
        if gfx::key_pressed("Escape") { break; }
        if gfx::key_pressed("Space") {
            if game.game_over {
                game = new_game(random_seed());
                game.launched = true;
            } else if !game.launched {
                game.launched = true;
            } else {
                game.paused = !game.paused;
            }
        }
        if gfx::key_pressed("R") { game = new_game(random_seed()); }

        var move_dir: f32 = 0.0;
        if gfx::key_down("Left") || gfx::key_down("A") { move_dir -= 1.0; }
        if gfx::key_down("Right") || gfx::key_down("D") { move_dir += 1.0; }

        let dt = if demo_mode { 1.0 / 60.0 } else { min(gfx::delta_time(), 0.04) };
        step_game(game, dt as f32, move_dir, demo_mode);

        if use_audio {
            if game.hit_paddle && sfx_paddle.id != 0 { audio::play(sfx_paddle, 0.5); }
            if game.hit_brick && sfx_brick.id != 0 {
                let pitch = min(1.0 + (game.combo as f32) * 0.08, 2.0);
                audio::play(sfx_brick, 0.6, 0.0, pitch);
            }
        }

        render_geometry(game, verts);
        if verts.len > 0 { gfx::update_buffer(vb, bytes_of(verts)); }

        ui::input_from_gfx(ctx);
        let px = gfx::screen_size();
        let sc = ui::scale(ctx);
        let hud_bounds = ui::rect(0.0, 0.0, px.x / sc, px.y / sc);
        if has_hud { ui::window_set_bounds(ctx, "BreakoutHUD", hud_bounds); }
        if ui::begin(ctx, "BreakoutHUD", hud_bounds, ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) {
            has_hud = true;
            ui::layout_row_dynamic(ctx, 28.0, 4);
            ui::label_colored(ctx, str("SCORE: ", game.score), ui::TEXT_LEFT, ui::rgb(120, 235, 255));
            ui::label_colored(ctx, str("COMBO: x", max(game.combo, 1)), ui::TEXT_CENTERED, ui::rgb(250, 204, 21));
            ui::label_colored(ctx, str("LEVEL: ", game.level), ui::TEXT_CENTERED, ui::rgb(167, 139, 250));
            ui::label_colored(ctx, str("LIVES: ", game.lives), ui::TEXT_RIGHT, ui::rgb(248, 113, 113));

            if game.game_over || !game.launched || game.paused {
                ui::layout_row_dynamic(ctx, 200.0, 1);
                ui::spacer(ctx);
                ui::layout_row_dynamic(ctx, 34.0, 1);
                let msg = if game.game_over {
                    str("GAME OVER - Press SPACE or R to Restart")
                } else if game.paused {
                    str("PAUSED - Press SPACE to Resume")
                } else {
                    str("SPACE: Launch  |  A/D or Arrows: Move  |  Esc: Quit")
                };
                ui::label_colored(ctx, msg, ui::TEXT_CENTERED, ui::rgb(240, 248, 255));
            }
        }
        ui::end(ctx);

        gfx::begin_screen(float4 { 0.04, 0.05, 0.09, 1.0 });
        if verts.len > 0 {
            gfx::bind(pipe);
            gfx::bind_vertex_buffer(vb);
            gfx::uniforms(gfx::VERTEX, 0, OrthoUniform { screen: float4 { WORLD_W, WORLD_H, 0.0, 0.0 } });
            gfx::draw(verts.len);
        }
        gfx::end_pass();
        ui::render(ctx);

        drawn++;
        if frames > 0 && drawn >= frames { break; }
    }

    if screenshot_path.len > 0 {
        let ok = gfx::screenshot(screenshot_path);
        check(ok, "failed to save neon_breakout screenshot");
    }
}

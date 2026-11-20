// voxel_runner: 3D Endless Cyber-Highway Runner in Goose (gfx + ui + audio).
//
// Features:
//   - Custom 3D GLSL vertex/fragment shaders with directional lighting & distance fog
//   - Single-draw batched 3D mesh buffer: glowing highway, skyline towers, obstacles,
//     spinning golden energy cubes, and banking/jumping cyber-craft
//   - Retina HUD overlay + procedural pickup/jump sound effects
//   - CLI flags: --test, --demo, --frames N, --screenshot <path>

import std;
import vec;
import math;
import os;
import gfx;
import ui;
import audio;

let FONT: const u8[:] = embed_file("../../../assets/Roboto-Regular.ttf");

let MAX_VERTS: i64 = 16384;
let MAX_INDICES: i64 = 24576;
let MAX_OBS: i64 = 28;
let LANE_W: f32 = 2.4;

struct Vertex3D { pos: float3, normal: float3, color: u8[4] }
struct SceneUniform { view_proj: gfx::mat4, fog_color: float4 }

// kind: 0 = tall monolith (dodge lane), 1 = low barrier (jump over), 2 = golden pickup
struct RoadObject {
    active: bool,
    lane: i64,
    z: f32,
    kind: i64,
    scored: bool,
}

struct RunnerGame {
    objs: RoadObject[28],
    lane: i64,
    player_x: f32,
    player_y: f32,
    vy: f32,
    on_ground: bool,
    speed: f32,
    distance: f32,
    bonus_score: i64,
    score: i64,
    best: i64,
    time_s: f32,
    next_spawn_z: f32,
    game_over: bool,
    paused: bool,
    prng: rng,
    picked_up: bool,
    jumped: bool,
}

fn check(ok: bool, msg: const u8[:]) {
    if !ok { abort(msg); }
}

fn lane_to_x(lane: i64) -> f32 {
    (lane - 1) * LANE_W
}

fn new_runner(seed: u64, best: i64) -> RunnerGame {
    var g = RunnerGame {
        objs: [default<RoadObject>(); 28],
        lane: 1,
        player_x: 0.0,
        player_y: 0.0,
        vy: 0.0,
        on_ground: true,
        speed: 19.0,
        distance: 0.0,
        bonus_score: 0,
        score: 0,
        best: best,
        time_s: 0.0,
        next_spawn_z: -24.0,
        game_over: false,
        paused: false,
        prng: rng { seed },
        picked_up: false,
        jumped: false,
    };
    // Seed initial road obstacles & pickups cleanly ahead
    var z: f32 = -22.0;
    for i in 12 {
        let l = (i * 2 + 1) % 3;
        let k = if i % 3 == 1 { 2 } else if i % 3 == 2 { 1 } else { 0 };
        g.objs[i] = RoadObject { active: true, lane: l, z: z, kind: k, scored: false };
        z -= 14.0;
    }
    return g;
}

fn trigger_jump(g: RunnerGame&) {
    if g.on_ground && !g.game_over {
        g.vy = 11.2;
        g.on_ground = false;
        g.jumped = true;
    }
}

fn demo_autopilot(g: RunnerGame&) {
    var danger_lane: bool[3] = [false, false, false];
    var need_jump = false;
    for i in MAX_OBS {
        let o = g.objs[i];
        if !o.active { continue; }
        if o.z < 1.5 && o.z > -18.0 {
            if o.kind == 0 {
                danger_lane[o.lane] = true;
            } else if o.kind == 1 && o.lane == g.lane && o.z > -6.5 && o.z < 0.8 {
                need_jump = true;
            }
        }
    }
    if need_jump { trigger_jump(g); }
    if danger_lane[g.lane] {
        if !danger_lane[1] { g.lane = 1; }
        else if !danger_lane[0] { g.lane = 0; }
        else if !danger_lane[2] { g.lane = 2; }
    } else {
        for i in MAX_OBS {
            let o = g.objs[i];
            if o.active && o.kind == 2 && o.z < -2.0 && o.z > -16.0 && !danger_lane[o.lane] {
                g.lane = o.lane;
                break;
            }
        }
    }
}

fn step_runner(g: RunnerGame&, dt: f32, demo_ai: bool) {
    g.picked_up = false;
    g.jumped = false;
    if g.paused || g.game_over { return; }

    if demo_ai { demo_autopilot(g); }

    g.time_s += dt;
    g.speed = min(19.0 + g.distance * 0.025, 42.0);
    let dz = g.speed * dt;
    g.distance += dz;
    g.score = (g.distance as i64) + g.bonus_score;
    if g.score > g.best { g.best = g.score; }

    // Smooth lane transition
    let target_x = lane_to_x(g.lane);
    g.player_x += (target_x - g.player_x) * min(dt * 14.0, 1.0);

    // Vertical jump gravity
    if !g.on_ground {
        g.vy -= 28.0 * dt;
        g.player_y += g.vy * dt;
        if g.player_y <= 0.0 {
            g.player_y = 0.0;
            g.vy = 0.0;
            g.on_ground = true;
        }
    }

    // Advance road objects & recycle
    var furthest_z: f32 = -30.0;
    for i in MAX_OBS {
        if g.objs[i].active && g.objs[i].z < furthest_z {
            furthest_z = g.objs[i].z;
        }
    }

    for i in MAX_OBS {
        if !g.objs[i].active { continue; }
        g.objs[i].z += dz;

        let o = g.objs[i];
        let ox = lane_to_x(o.lane);
        if !demo_ai && abs(o.z) < 0.95 && abs(g.player_x - ox) < 0.85 {
            if o.kind == 2 {
                if !o.scored {
                    g.objs[i].active = false;
                    g.bonus_score += 100;
                    g.score = (g.distance as i64) + g.bonus_score;
                    if g.score > g.best { g.best = g.score; }
                    g.picked_up = true;
                }
            } else if o.kind == 1 {
                if g.player_y < 0.72 { g.game_over = true; }
            } else {
                if g.player_y < 1.85 { g.game_over = true; }
            }
        } else if demo_ai && o.kind == 2 && abs(o.z) < 0.95 && abs(g.player_x - ox) < 0.95 && !o.scored {
            g.objs[i].active = false;
            g.bonus_score += 100;
            g.score = (g.distance as i64) + g.bonus_score;
            if g.score > g.best { g.best = g.score; }
            g.picked_up = true;
        } else if demo_ai && abs(o.z) < 0.95 && abs(g.player_x - ox) < 0.85 {
            if (o.kind == 1 && g.player_y < 0.72) || (o.kind == 0 && g.player_y < 1.85) {
                g.game_over = true;
            }
        }

        if g.objs[i].z > 8.0 {
            let new_z = furthest_z - (13.0 + (g.prng.rand_flt() * 5.0) as f32);
            furthest_z = new_z;
            let roll = g.prng.rand_range(10);
            let nk: i64 = if roll < 3 { 2 } else if roll < 6 { 1 } else { 0 };
            g.objs[i] = RoadObject {
                active: true,
                lane: g.prng.rand_range(3),
                z: new_z,
                kind: nk,
                scored: false,
            };
        }
    }
}

fn push_box(verts: Vertex3D[>..]&, indices: u16[>..]&,
            cx: f32, cy: f32, cz: f32, hx: f32, hy: f32, hz: f32, col: u8[4]) {
    if verts.len + 24 > MAX_VERTS || indices.len + 36 > MAX_INDICES { return; }

    let axes: float3[3] = [
        float3 { 1.0, 0.0, 0.0 },
        float3 { 0.0, 1.0, 0.0 },
        float3 { 0.0, 0.0, 1.0 },
    ];
    let center = float3 { cx, cy, cz };
    let half = float3 { hx, hy, hz };
    let corners: float2[4] = [
        float2 { -1.0, -1.0 },
        float2 {  1.0, -1.0 },
        float2 {  1.0,  1.0 },
        float2 { -1.0,  1.0 },
    ];

    for f in 6 {
        let sign: f32 = if f % 2 == 0 { 1.0 } else { -1.0 };
        let n = axes[f / 2] * float3 { sign, sign, sign };
        let u = axes[(f / 2 + 1) % 3] * float3 { sign, sign, sign };
        let v = cross(n, u);
        let base = verts.len as u16;
        for c in corners {
            let unit_p = n + u * float3 { c.x, c.x, c.x } + v * float3 { c.y, c.y, c.y };
            let world_p = center + float3 { unit_p.x * half.x, unit_p.y * half.y, unit_p.z * half.z };
            verts.push(Vertex3D { pos: world_p, normal: n, color: col });
        }
        indices.append([base, base + 1, base + 2, base, base + 2, base + 3]);
    }
}

fn build_scene_mesh(g: const RunnerGame&, verts: Vertex3D[>..]&, indices: u16[>..]&) {
    verts.clear();
    indices.clear();

    // Highway deck + neon lane dividers + side rails
    push_box(verts, indices, 0.0, -0.2, -55.0, 4.2, 0.2, 65.0, [24, 30, 46, 255]);
    push_box(verts, indices, -4.3, 0.12, -55.0, 0.14, 0.18, 65.0, [60, 215, 255, 255]);
    push_box(verts, indices,  4.3, 0.12, -55.0, 0.14, 0.18, 65.0, [255, 80, 175, 255]);

    // Scrolling dashed lane stripes
    let scroll = fract(g.distance / 6.0) * 6.0;
    for k in 20 {
        let rz = 6.0 - k * 6.0 + scroll;
        push_box(verts, indices, -1.2, 0.01, rz, 0.06, 0.02, 1.4, [75, 110, 175, 255]);
        push_box(verts, indices,  1.2, 0.01, rz, 0.06, 0.02, 1.4, [75, 110, 175, 255]);
    }

    // Synthwave skyline towers flanking the highway
    let tower_scroll = fract(g.distance / 14.0) * 14.0;
    for k in 10 {
        let tz = -4.0 - k * 14.0 + tower_scroll;
        let h_left = 4.0 + ((k * 3) % 5) * 1.6;
        let h_right = 5.0 + ((k * 7) % 5) * 1.4;
        push_box(verts, indices, -10.5, h_left * 0.5 - 0.5, tz, 1.8, h_left * 0.5, 1.8,
                 [36, 46, 86, 255]);
        push_box(verts, indices,  10.5, h_right * 0.5 - 0.5, tz - 5.0, 1.8, h_right * 0.5, 1.8,
                 [54, 38, 92, 255]);
        // Glowing roof strip
        push_box(verts, indices, -10.5, h_left - 0.45, tz, 1.85, 0.12, 1.85, [70, 210, 255, 255]);
        push_box(verts, indices,  10.5, h_right - 0.45, tz - 5.0, 1.85, 0.12, 1.85,
                 [255, 95, 185, 255]);
    }

    // Road obstacles and golden pickups
    for i in MAX_OBS {
        let o = g.objs[i];
        if !o.active { continue; }
        let ox = lane_to_x(o.lane);
        if o.kind == 0 {
            // Tall neon crimson monolith
            push_box(verts, indices, ox, 1.05, o.z, 0.82, 1.05, 0.82, [235, 68, 96, 255]);
            push_box(verts, indices, ox, 2.12, o.z, 0.86, 0.08, 0.86, [255, 175, 190, 255]);
        } else if o.kind == 1 {
            // Low jumpable amber barrier
            push_box(verts, indices, ox, 0.36, o.z, 0.92, 0.36, 0.35, [245, 158, 11, 255]);
            push_box(verts, indices, ox, 0.74, o.z, 0.95, 0.06, 0.38, [255, 235, 140, 255]);
        } else {
            // Bobbing golden energy cube
            let bob = 0.68 + sin(g.time_s * 5.0 + i) * 0.18;
            push_box(verts, indices, ox, bob, o.z, 0.34, 0.34, 0.34, [250, 215, 55, 255]);
        }
    }

    // Player hover craft at z = 0
    let px = g.player_x;
    let py = g.player_y + 0.42 + sin(g.time_s * 7.0) * 0.05;
    // Main chassis
    push_box(verts, indices, px, py, 0.0, 0.52, 0.24, 0.85, [64, 215, 255, 255]);
    // Cockpit canopy
    push_box(verts, indices, px, py + 0.26, -0.10, 0.30, 0.14, 0.40, [220, 245, 255, 255]);
    // Side wings
    push_box(verts, indices, px - 0.68, py - 0.04, 0.20, 0.24, 0.08, 0.48, [45, 150, 235, 255]);
    push_box(verts, indices, px + 0.68, py - 0.04, 0.20, 0.24, 0.08, 0.48, [45, 150, 235, 255]);
    // Rear thruster glow
    push_box(verts, indices, px, py, 0.96, 0.24, 0.12, 0.16, [255, 120, 75, 255]);
}

fn build_tone(freq0: f64, freq1: f64, dur_s: f64) -> f32[>..] {
    let rate = 48000;
    let n = (dur_s * rate) as i64;
    var pcm: f32[>..] = [];
    for i in n {
        let f_frac = i / (n as f64);
        let freq = freq0 + (freq1 - freq0) * f_frac;
        let t = i / (rate as f64);
        let env = 1.0 - f_frac;
        pcm.push((sin(TAU * freq * t) * 0.22 * env) as f32);
    }
    return pcm;
}

fn run_tests() {
    var g = new_runner(42, 0);
    g.lane = 0;
    for _ in 30 { step_runner(g, 1.0 / 60.0, false); }
    check(abs(g.player_x - lane_to_x(0)) < 0.15, "lane steering must move player_x toward left lane");

    trigger_jump(g);
    check(!g.on_ground && g.jumped, "jump must lift player off ground");
    step_runner(g, 0.08, false);
    check(g.player_y > 0.3, "jump must raise player_y");

    // Pickup scoring check
    var g2 = new_runner(7, 0);
    for i in MAX_OBS { g2.objs[i].active = false; }
    g2.objs[0] = RoadObject { active: true, lane: 1, z: -0.2, kind: 2, scored: false };
    step_runner(g2, 0.016, false);
    check(g2.picked_up && g2.bonus_score == 100, "golden pickup must award +100 bonus");

    // Mesh batch sanity
    var verts: Vertex3D[>..] = [];
    var indices: u16[>..] = [];
    build_scene_mesh(g, verts, indices);
    check(verts.len > 200 && indices.len > 300, "3D mesh batch too small");

    print("PASS voxel_runner (3D lanes, jump gravity, pickup scoring, mesh generation)\n");
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

    guard gfx::open("Goose Voxel Runner 3D", 960, 600, gfx::WINDOW_RESIZABLE) else {
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
    let base_w: f32 = 960.0;
    var dpi_scale: f32 = init_pixels.x / base_w;
    if dpi_scale < 0.5 { dpi_scale = 1.0; }
    if dpi_scale > 4.0 { dpi_scale = 4.0; }
    if dpi_scale != ui::scale(ctx) {
        ui::set_scale(ctx, dpi_scale);
    }

    var hud_style = ui::style(ctx);
    hud_style.window.fixed_background = ui::style_item_hide();
    hud_style.window.padding = float2 { 16.0, 12.0 };
    ui::set_style(ctx, hud_style);

    let vs = embed_shader("vert", """
        layout(location = 0) in vec3 a_pos;
        layout(location = 1) in vec3 a_normal;
        layout(location = 2) in vec4 a_color;
        layout(set = 1, binding = 0) uniform Scene {
            mat4 view_proj;
            vec4 fog_color;
        };
        layout(location = 0) out vec3 v_normal;
        layout(location = 1) out vec4 v_color;
        layout(location = 2) out float v_dist;
        void main() {
            v_normal = a_normal;
            v_color = a_color;
            vec4 clip = view_proj * vec4(a_pos, 1.0);
            v_dist = clip.w;
            gl_Position = clip;
        }
    """);
    let fs = embed_shader("frag", """
        layout(location = 0) in vec3 v_normal;
        layout(location = 1) in vec4 v_color;
        layout(location = 2) in float v_dist;
        layout(set = 3, binding = 0) uniform SceneFrag {
            mat4 view_proj;
            vec4 fog_color;
        };
        layout(location = 0) out vec4 result;
        void main() {
            vec3 n = normalize(v_normal);
            vec3 sun = normalize(vec3(0.45, 0.85, 0.35));
            float diff = max(dot(n, sun), 0.0);
            float hemi = 0.32 + 0.14 * n.y;
            vec3 lit = v_color.rgb * (hemi + 0.68 * diff);
            float fog = clamp((v_dist - 24.0) / 68.0, 0.0, 1.0);
            result = vec4(mix(lit, fog_color.rgb, fog), 1.0);
        }
    """);

    var desc = gfx::PipelineDesc { cull: gfx::CULL_BACK, depth_test: true, depth_write: true };
    desc.formats[2] = gfx::VERTEX_UBYTE4_NORM;
    let pipe = gfx::pipeline(vs, fs, desc);
    defer gfx::release(pipe);

    let one_v: Vertex3D[1] = [default<Vertex3D>()];
    let one_i: u16[1] = [0];
    let empty: u8[>..] = [];
    let vb = gfx::buffer(gfx::BUFFER_VERTEX, MAX_VERTS * bytes_of(one_v).len, empty);
    let ib = gfx::buffer(gfx::BUFFER_INDEX, MAX_INDICES * bytes_of(one_i).len, empty);
    defer {
        gfx::release(vb);
        gfx::release(ib);
    }

    var use_audio = screenshot_path.len == 0 && audio::available();
    var sfx_pickup = audio::Sound { id: 0 };
    var sfx_jump = audio::Sound { id: 0 };
    if use_audio {
        if audio::open() {
            sfx_pickup = audio::create_sound(build_tone(620.0, 980.0, 0.11));
            sfx_jump = audio::create_sound(build_tone(260.0, 520.0, 0.10));
        } else {
            use_audio = false;
        }
    }
    defer {
        if use_audio {
            audio::release_sound(sfx_pickup);
            audio::release_sound(sfx_jump);
            audio::close();
        }
    }

    var game = new_runner(if demo_mode { 2026 } else { random_seed() }, 0);
    var verts: Vertex3D[>..] = [];
    var indices: u16[>..] = [];
    var drawn: i64 = 0;
    var has_hud = false;

    while gfx::frame() {
        if gfx::key_pressed("Escape") { break; }
        if gfx::key_pressed("Left") || gfx::key_pressed("A") {
            if game.lane > 0 { game.lane -= 1; }
        }
        if gfx::key_pressed("Right") || gfx::key_pressed("D") {
            if game.lane < 2 { game.lane += 1; }
        }
        if gfx::key_pressed("Space") || gfx::key_pressed("Up") || gfx::key_pressed("W") {
            if game.game_over {
                game = new_runner(random_seed(), game.best);
            } else {
                trigger_jump(game);
            }
        }
        if gfx::key_pressed("R") {
            game = new_runner(random_seed(), game.best);
        }

        let dt = if demo_mode { 1.0 / 60.0 } else { min(gfx::delta_time(), 0.04) };
        step_runner(game, dt as f32, demo_mode);

        if use_audio {
            if game.picked_up && sfx_pickup.id != 0 { audio::play(sfx_pickup, 0.5); }
            if game.jumped && sfx_jump.id != 0 { audio::play(sfx_jump, 0.35); }
        }

        build_scene_mesh(game, verts, indices);
        if verts.len > 0 && indices.len > 0 {
            gfx::update_buffer(vb, bytes_of(verts));
            gfx::update_buffer(ib, bytes_of(indices));
        }

        let sz = gfx::screen_size();
        let aspect = sz.x / max(sz.y as f32, 1.0);
        let eye = float3 { game.player_x * 0.42, 3.6 + game.player_y * 0.4, 6.8 };
        let target = float3 { game.player_x * 0.25, 1.0 + game.player_y * 0.3, -18.0 };
        let vp = gfx::mul(gfx::perspective(0.88, aspect, 0.2, 140.0),
                          gfx::look_at(eye, target, float3 { 0.0, 1.0, 0.0 }));
        let fog = float4 { 0.05, 0.06, 0.12, 1.0 };
        let uni = SceneUniform { view_proj: vp, fog_color: fog };

        ui::input_from_gfx(ctx);
        let sc = ui::scale(ctx);
        let hud_bounds = ui::rect(0.0, 0.0, sz.x / sc, sz.y / sc);
        if has_hud { ui::window_set_bounds(ctx, "RunnerHUD", hud_bounds); }
        if ui::begin(ctx, "RunnerHUD", hud_bounds, ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) {
            has_hud = true;
            ui::layout_row_dynamic(ctx, 28.0, 4);
            ui::label_colored(ctx, str("SCORE: ", game.score), ui::TEXT_LEFT, ui::rgb(110, 235, 255));
            ui::label_colored(ctx, str("DIST: ", game.distance as i64, "m"), ui::TEXT_CENTERED,
                              ui::rgb(190, 215, 255));
            ui::label_colored(ctx, str("SPEED: ", game.speed as i64, " m/s"), ui::TEXT_CENTERED,
                              ui::rgb(250, 204, 21));
            ui::label_colored(ctx, str("BEST: ", game.best), ui::TEXT_RIGHT, ui::rgb(130, 240, 170));

            if game.game_over {
                ui::layout_row_dynamic(ctx, 210.0, 1);
                ui::spacer(ctx);
                ui::layout_row_dynamic(ctx, 36.0, 1);
                ui::label_colored(ctx, "CRASHED! Press SPACE or R to Restart",
                                  ui::TEXT_CENTERED, ui::rgb(255, 110, 120));
            }
        }
        ui::end(ctx);

        gfx::begin_screen(fog);
        if indices.len > 0 {
            gfx::bind(pipe);
            gfx::bind_vertex_buffer(vb);
            gfx::bind_index_buffer(ib, 2);
            gfx::uniforms(gfx::VERTEX, 0, uni);
            gfx::uniforms(gfx::FRAGMENT, 0, uni);
            gfx::draw_indexed(indices.len);
        }
        gfx::end_pass();
        ui::render(ctx);

        drawn++;
        if frames > 0 && drawn >= frames { break; }
    }

    if screenshot_path.len > 0 {
        let ok = gfx::screenshot(screenshot_path);
        check(ok, "failed to save voxel_runner screenshot");
    }
}

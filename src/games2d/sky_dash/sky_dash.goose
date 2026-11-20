// sky_dash: 2D Side-Scrolling Endless Rooftop Runner in Goose (gfx + ui + audio).
//
// Features:
//   - Twilight gradient sky, segmented synthwave sun, stars, 3 parallax city layers
//   - Variable jump + double jump (Space/W/Up) and crouch/slide (Down/S)
//   - Rooftop laser barriers, hovering drones, gap leaps, coin arcs, cyan Shield pickup
//   - Flowing neon scarf trail + particle bursts + procedural audio SFX
//   - CLI flags: --test, --demo, --frames N, --screenshot <path>

import std;
import vec;
import math;
import os;
import gfx;
import ui;
import audio;

let FONT: const u8[:] = embed_file("../../../assets/Roboto-Regular.ttf");

let WORLD_W: f32 = 960.0;
let WORLD_H: f32 = 540.0;
let MAX_VERTS: i64 = 12288;
let MAX_ROOFS: i64 = 10;
let MAX_ENTS: i64 = 40;
let MAX_PARTS: i64 = 96;
let SCARF_LEN: i64 = 6;

let ENT_NONE: i64 = 0;
let ENT_LASER: i64 = 1;
let ENT_DRONE: i64 = 2;
let ENT_COIN: i64 = 3;
let ENT_SHIELD: i64 = 4;

struct Vertex2D { pos: float2, color: u8[4] }
struct OrthoUniform { screen: float4 }

struct RoofSeg {
    x: f32,
    w: f32,
    y: f32,
    accent_hue: i64,
}

struct SkyEntity {
    kind: i64,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    phase: f32,
}

struct Particle {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    life: f32,
    max_life: f32,
    color: u8[4],
}

struct DashGame {
    roofs: RoofSeg[10],
    ents: SkyEntity[40],
    parts: Particle[96],
    scarf: float2[6],
    player_x: f32,
    player_y: f32,     // feet Y
    vy: f32,
    on_ground: bool,
    jumps_left: i64,
    slide_t: f32,
    invuln_t: f32,
    has_shield: bool,
    speed: f32,
    distance: f32,
    coins: i64,
    score: i64,
    best: i64,
    run_phase: f32,
    time_s: f32,
    game_over: bool,
    paused: bool,
    prng: rng,
    sfx_jump: bool,
    sfx_coin: bool,
    sfx_shield: bool,
}

fn check(ok: bool, msg: const u8[:]) {
    if !ok { abort(msg); }
}

fn spawn_parts(g: DashGame&, x: f32, y: f32, col: u8[4], count: i64) {
    var spawned: i64 = 0;
    for i in MAX_PARTS {
        if spawned >= count { break; }
        if g.parts[i].life <= 0.0 {
            let ang = (g.prng.rand_flt() * TAU) as f32;
            let spd = 60.0 + (g.prng.rand_flt() * 190.0) as f32;
            g.parts[i] = Particle {
                x: x,
                y: y,
                vx: cos(ang) * spd - 40.0,
                vy: sin(ang) * spd,
                life: 0.45,
                max_life: 0.45,
                color: col,
            };
            spawned++;
        }
    }
}

fn find_free_ent(ents: const SkyEntity[:]) -> i64 {
    for i in ents.len {
        if ents[i].kind == ENT_NONE { return i; }
    }
    return -1;
}

fn populate_roof_entities(g: DashGame&, rx: f32, rw: f32, ry: f32, seg_idx: i64) {
    // Place coins and either a laser or drone on longer roofs
    var slot: i64 = -1;

    // Coin arc near start of roof
    for c in 3 {
        slot = find_free_ent(g.ents);
        if slot >= 0 {
            g.ents[slot] = SkyEntity {
                kind: ENT_COIN,
                x: rx + 65.0 + c * 38.0,
                y: ry - 48.0 - (if c == 1 { 26.0 } else { 0.0 }),
                w: 18.0,
                h: 18.0,
                phase: c * 0.7,
            };
        }
    }

    if rw > 280.0 && seg_idx > 0 {
        slot = find_free_ent(g.ents);
        if slot >= 0 {
            let roll = g.prng.rand_range(10);
            if roll < 5 {
                // Laser barrier on rooftop (jump over)
                g.ents[slot] = SkyEntity {
                    kind: ENT_LASER,
                    x: rx + rw * 0.58,
                    y: ry - 46.0,
                    w: 18.0,
                    h: 46.0,
                    phase: 0.0,
                };
            } else {
                // Hovering drone (slide under or double-jump over)
                g.ents[slot] = SkyEntity {
                    kind: ENT_DRONE,
                    x: rx + rw * 0.60,
                    y: ry - 64.0,
                    w: 38.0,
                    h: 24.0,
                    phase: seg_idx * 1.1,
                };
            }
        }
    }

    if seg_idx % 4 == 2 {
        slot = find_free_ent(g.ents);
        if slot >= 0 {
            g.ents[slot] = SkyEntity {
                kind: ENT_SHIELD,
                x: rx + rw - 65.0,
                y: ry - 95.0,
                w: 22.0,
                h: 22.0,
                phase: 0.5,
            };
        }
    }
}

fn new_dash(seed: u64, best: i64) -> DashGame {
    var g = DashGame {
        roofs: [default<RoofSeg>(); 10],
        ents: [default<SkyEntity>(); 40],
        parts: [default<Particle>(); 96],
        scarf: [float2 { 190.0, 360.0 }; 6],
        player_x: 190.0,
        player_y: 390.0,
        vy: 0.0,
        on_ground: true,
        jumps_left: 2,
        slide_t: 0.0,
        invuln_t: 0.0,
        has_shield: false,
        speed: 340.0,
        distance: 0.0,
        coins: 0,
        score: 0,
        best: best,
        run_phase: 0.0,
        time_s: 0.0,
        game_over: false,
        paused: false,
        prng: rng { seed },
        sfx_jump: false,
        sfx_coin: false,
        sfx_shield: false,
    };

    var cur_x: f32 = 0.0;
    for i in MAX_ROOFS {
        let rw: f32 = if i == 0 { 520.0 } else { 290.0 + (g.prng.rand_flt() * 190.0) as f32 };
        let ry: f32 = if i == 0 { 390.0 } else { 355.0 + (g.prng.rand_flt() * 75.0) as f32 };
        g.roofs[i] = RoofSeg { x: cur_x, w: rw, y: ry, accent_hue: i % 3 };
        populate_roof_entities(g, cur_x, rw, ry, i);
        let gap: f32 = if i == 0 { 82.0 } else { 80.0 + (g.prng.rand_flt() * 48.0) as f32 };
        cur_x += rw + gap;
    }
    return g;
}

fn trigger_jump(g: DashGame&) {
    if g.game_over || g.jumps_left <= 0 { return; }
    let first = g.on_ground;
    g.vy = if first { -585.0 } else { -540.0 };
    g.on_ground = false;
    g.slide_t = 0.0;
    g.jumps_left -= 1;
    g.sfx_jump = true;
    spawn_parts(g, g.player_x, g.player_y,
                if first { [180, 220, 255, 255] } else { [80, 240, 255, 255] }, 10);
}

fn trigger_slide(g: DashGame&) {
    if g.game_over { return; }
    if g.on_ground {
        g.slide_t = 0.42;
    } else if g.vy < 320.0 {
        // Fast-fall slam onto rooftop
        g.vy = 520.0;
        g.slide_t = 0.30;
    }
}

fn find_roof_under(g: const DashGame&, px: f32) -> f32, bool {
    for i in MAX_ROOFS {
        let r = g.roofs[i];
        if px + 12.0 >= r.x && px - 12.0 <= r.x + r.w {
            return r.y, true;
        }
    }
    return 0.0, false;
}

fn demo_autopilot(g: DashGame&) {
    // Check gap right ahead of player
    let _, ground_ahead = find_roof_under(g, g.player_x + 48.0);
    if !ground_ahead && g.on_ground {
        trigger_jump(g);
        return;
    }
    // Check upcoming obstacles
    for i in MAX_ENTS {
        let e = g.ents[i];
        if e.kind == ENT_LASER && e.x > g.player_x && e.x < g.player_x + 125.0 {
            if g.on_ground || (g.vy > 20.0 && g.jumps_left > 0) {
                trigger_jump(g);
                return;
            }
        } else if e.kind == ENT_DRONE && e.x > g.player_x && e.x < g.player_x + 135.0 {
            if g.on_ground && g.slide_t <= 0.05 {
                trigger_slide(g);
                return;
            }
        }
    }
}

fn player_height(g: const DashGame&) -> f32 {
    if g.slide_t > 0.0 { return 24.0; }
    return 46.0;
}

fn step_dash(g: DashGame&, dt: f32, demo_ai: bool) {
    g.sfx_jump = false;
    g.sfx_coin = false;
    g.sfx_shield = false;
    if g.paused || g.game_over { return; }

    if demo_ai { demo_autopilot(g); }

    g.time_s += dt;
    g.speed = min(340.0 + g.distance * 0.025, 620.0);
    let dx = g.speed * dt;
    g.distance += dx * 0.08;
    g.score = (g.distance as i64) * 5 + g.coins * 25;
    if g.score > g.best { g.best = g.score; }

    if g.slide_t > 0.0 { g.slide_t = max(g.slide_t - dt, 0.0); }
    if g.invuln_t > 0.0 { g.invuln_t = max(g.invuln_t - dt, 0.0); }
    if g.on_ground { g.run_phase += dt * (g.speed * 0.045); }

    // Update particles
    for i in MAX_PARTS {
        if g.parts[i].life > 0.0 {
            g.parts[i].x += (g.parts[i].vx - g.speed * 0.35) * dt;
            g.parts[i].y += g.parts[i].vy * dt;
            g.parts[i].vy += 420.0 * dt;
            g.parts[i].life -= dt;
        }
    }

    // Shift and track flowing scarf
    let head_y = g.player_y - player_height(g) + 10.0;
    var si = SCARF_LEN - 1;
    while si > 0 {
        g.scarf[si] = float2 {
            g.scarf[si - 1].x - dx * 0.14,
            g.scarf[si - 1].y + sin(g.time_s * 16.0 + si) * 0.7,
        };
        si--;
    }
    g.scarf[0] = float2 { g.player_x - 6.0, head_y };

    // Scroll rooftops and recycle off-screen segments
    var max_right: f32 = 0.0;
    for i in MAX_ROOFS {
        g.roofs[i].x -= dx;
        let r_end = g.roofs[i].x + g.roofs[i].w;
        if r_end > max_right { max_right = r_end; }
    }
    for i in MAX_ROOFS {
        if g.roofs[i].x + g.roofs[i].w < -60.0 {
            let rw = 280.0 + (g.prng.rand_flt() * 210.0) as f32;
            let ry = 350.0 + (g.prng.rand_flt() * 80.0) as f32;
            let gap = 82.0 + (g.prng.rand_flt() * 54.0) as f32;
            let new_x = max_right + gap;
            max_right = new_x + rw;
            g.roofs[i] = RoofSeg { x: new_x, w: rw, y: ry, accent_hue: (i + 1) % 3 };
            populate_roof_entities(g, new_x, rw, ry, i + 1);
        }
    }

    // Player vertical physics & rooftop landing
    let prev_y = g.player_y;
    g.vy += 1550.0 * dt;
    g.player_y += g.vy * dt;

    let roof_y, over_roof = find_roof_under(g, g.player_x);
    if over_roof && g.vy >= 0.0 && prev_y <= roof_y + 10.0 && g.player_y >= roof_y {
        g.player_y = roof_y;
        g.vy = 0.0;
        g.on_ground = true;
        g.jumps_left = 2;
    } else if !over_roof || g.player_y < roof_y - 2.0 {
        g.on_ground = false;
    }

    if g.player_y > WORLD_H + 60.0 {
        if demo_ai {
            // Keep demo endlessly alive if edge-case gap occurs
            g.player_y = 280.0;
            g.vy = -120.0;
            g.jumps_left = 2;
        } else {
            g.game_over = true;
        }
        return;
    }

    // Scroll & collide entities
    let ph = player_height(g);
    let px0 = g.player_x - 13.0;
    let py0 = g.player_y - ph;
    let px1 = g.player_x + 13.0;
    let py1 = g.player_y;

    for i in MAX_ENTS {
        if g.ents[i].kind == ENT_NONE { continue; }
        g.ents[i].x -= dx;
        if g.ents[i].x + g.ents[i].w < -60.0 {
            g.ents[i].kind = ENT_NONE;
            continue;
        }
        let e = g.ents[i];
        let ey = e.y + (if e.kind == ENT_DRONE { sin(g.time_s * 5.0 + e.phase) * 4.0 } else { 0.0 });
        if px1 > e.x && px0 < e.x + e.w && py1 > ey && py0 < ey + e.h {
            if e.kind == ENT_COIN {
                g.ents[i].kind = ENT_NONE;
                g.coins++;
                g.sfx_coin = true;
                spawn_parts(g, e.x + 9.0, ey + 9.0, [255, 220, 70, 255], 8);
            } else if e.kind == ENT_SHIELD {
                g.ents[i].kind = ENT_NONE;
                g.has_shield = true;
                g.sfx_shield = true;
                spawn_parts(g, e.x + 11.0, ey + 11.0, [80, 235, 255, 255], 12);
            } else if g.invuln_t <= 0.0 {
                if g.has_shield {
                    g.has_shield = false;
                    g.invuln_t = 1.0;
                    g.ents[i].kind = ENT_NONE;
                    spawn_parts(g, g.player_x, g.player_y - ph * 0.5, [80, 235, 255, 255], 18);
                } else if !demo_ai {
                    g.game_over = true;
                }
            }
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

fn roof_neon_col(idx: i64) -> u8[4] {
    if idx == 0 { return [60, 225, 255, 255]; }
    if idx == 1 { return [255, 90, 185, 255]; }
    return [135, 115, 255, 255];
}

fn render_dash(g: const DashGame&, verts: Vertex2D[>..]&) {
    verts.clear();

    // 1. Twilight gradient sky bands
    let sky_cols: u8[4][6] = [
        [14, 12, 34, 255],
        [24, 18, 52, 255],
        [44, 24, 72, 255],
        [76, 32, 92, 255],
        [118, 44, 102, 255],
        [156, 66, 98, 255],
    ];
    let band_h = WORLD_H / 6.0;
    for b in 6 {
        push_quad(verts, 0.0, b * band_h, WORLD_W, band_h + 1.0, sky_cols[b]);
    }

    // 2. Twinkling stars
    for s in 28 {
        let sx = ((s * 173 + 41) % 940) + 10.0;
        let sy = ((s * 97 + 19) % 210) + 16.0;
        let alpha = (110 + ((sin(g.time_s * 3.0 + s) + 1.0) * 65.0) as i64) as u8;
        let st_c: u8[4] = [235, 242, 255, alpha];
        push_quad(verts, sx, sy, 2.5, 2.5, st_c);
    }

    // 3. Segmented retro sun disc
    let sun_cx: f32 = 710.0;
    let sun_cy: f32 = 220.0;
    let sun_r: f32 = 86.0;
    var sy_off: f32 = -sun_r;
    var slice_idx: i64 = 0;
    while sy_off < sun_r {
        if sy_off < 12.0 || slice_idx % 3 != 0 {
            let half_w = sqrt(max(sun_r * sun_r - sy_off * sy_off, 0.0));
            let t = (sy_off + sun_r) / (sun_r * 2.0);
            let r_c = 255 as u8;
            let g_c = (210 - (t * 135.0) as i64) as u8;
            let b_c = (95 + (t * 65.0) as i64) as u8;
            let s_col: u8[4] = [r_c, g_c, b_c, 225];
            push_quad(verts, sun_cx - half_w, sun_cy + sy_off, half_w * 2.0, 5.5, s_col);
        }
        sy_off += 7.0;
        slice_idx++;
    }

    // 4. Far parallax skyline
    let far_off = fract((g.distance * 0.35) / 110.0) * 110.0;
    for k in 11 {
        let bx = k * 110.0 - far_off - 40.0;
        let bh = 130.0 + ((k * 53) % 120);
        push_quad(verts, bx, WORLD_H - bh - 60.0, 92.0, bh + 60.0, [24, 20, 48, 255]);
    }

    // 5. Mid parallax towers with glowing windows
    let mid_off = fract((g.distance * 0.75) / 130.0) * 130.0;
    for k in 10 {
        let bx = k * 130.0 - mid_off - 30.0;
        let bh = 110.0 + ((k * 71) % 115);
        let by = WORLD_H - bh;
        push_quad(verts, bx, by, 102.0, bh, [30, 26, 60, 255]);
        push_quad(verts, bx, by, 102.0, 3.0, [85, 65, 145, 220]);
        for wy in 4 {
            for wx in 3 {
                if (wx + wy + k) % 2 == 0 {
                    push_quad(verts, bx + 14.0 + wx * 28.0, by + 16.0 + wy * 20.0, 12.0, 10.0,
                              [255, 200, 110, 130]);
                }
            }
        }
    }

    // 6. Foreground Rooftops
    for i in MAX_ROOFS {
        let r = g.roofs[i];
        let body_h = WORLD_H - r.y + 40.0;
        push_quad(verts, r.x, r.y, r.w, body_h, [18, 22, 36, 255]);
        push_quad(verts, r.x, r.y + 6.0, r.w, body_h - 6.0, [22, 27, 44, 255]);
        let trim = roof_neon_col(r.accent_hue);
        push_quad(verts, r.x, r.y, r.w, 5.0, trim);
        // Subtle rooftop window band
        var wx = r.x + 20.0;
        while wx + 22.0 < r.x + r.w {
            push_quad(verts, wx, r.y + 22.0, 18.0, 14.0, [52, 74, 118, 175]);
            wx += 38.0;
        }
    }

    // 7. Entities (Coins, Shields, Lasers, Drones)
    for i in MAX_ENTS {
        let e = g.ents[i];
        if e.kind == ENT_NONE { continue; }
        if e.kind == ENT_COIN {
            let bob = sin(g.time_s * 6.0 + e.phase) * 4.0;
            push_quad(verts, e.x - 2.0, e.y + bob - 2.0, e.w + 4.0, e.h + 4.0, [255, 215, 60, 75]);
            push_quad(verts, e.x, e.y + bob, e.w, e.h, [255, 215, 60, 255]);
            push_quad(verts, e.x + 5.0, e.y + bob + 4.0, e.w - 10.0, e.h - 8.0, [255, 248, 180, 255]);
        } else if e.kind == ENT_SHIELD {
            let bob = sin(g.time_s * 5.0 + e.phase) * 5.0;
            push_quad(verts, e.x - 4.0, e.y + bob - 4.0, e.w + 8.0, e.h + 8.0, [60, 230, 255, 75]);
            push_quad(verts, e.x, e.y + bob, e.w, e.h, [70, 235, 255, 255]);
            push_quad(verts, e.x + 5.0, e.y + bob + 5.0, e.w - 10.0, e.h - 10.0, [230, 252, 255, 255]);
        } else if e.kind == ENT_LASER {
            push_quad(verts, e.x - 4.0, e.y, e.w + 8.0, e.h, [255, 60, 100, 75]);
            push_quad(verts, e.x, e.y, e.w, e.h, [255, 70, 115, 255]);
            push_quad(verts, e.x + 5.0, e.y + 4.0, e.w - 10.0, e.h - 8.0, [255, 220, 230, 230]);
            push_quad(verts, e.x - 4.0, e.y + e.h - 7.0, e.w + 8.0, 7.0, [90, 100, 125, 255]);
        } else if e.kind == ENT_DRONE {
            let dy = e.y + sin(g.time_s * 5.0 + e.phase) * 4.0;
            push_quad(verts, e.x, dy, e.w, e.h, [46, 52, 74, 255]);
            push_quad(verts, e.x + 4.0, dy + 6.0, e.w - 8.0, 8.0, [255, 75, 95, 255]);
            push_quad(verts, e.x + 2.0, dy - 4.0, 10.0, 4.0, [110, 220, 255, 210]);
            push_quad(verts, e.x + e.w - 12.0, dy - 4.0, 10.0, 4.0, [110, 220, 255, 210]);
        }
    }

    // 8. Neon scarf trail behind runner
    for s in SCARF_LEN {
        let p = g.scarf[s];
        let frac = 1.0 - (s as f32) / SCARF_LEN;
        let sz = 5.0 + 4.0 * frac;
        let a = (frac * 220.0) as u8;
        let sc: u8[4] = [255, 78, 158, a];
        push_quad(verts, p.x - sz * 0.5, p.y - sz * 0.5, sz, sz, sc);
    }

    // 9. Runner hero
    let ph = player_height(g);
    let px = g.player_x;
    let py = g.player_y;
    let blink_hide = g.invuln_t > 0.0 && ((g.time_s * 18.0) as i64) % 2 == 0;
    if !blink_hide {
        if g.has_shield {
            push_quad(verts, px - 22.0, py - ph - 6.0, 44.0, ph + 12.0, [70, 235, 255, 65]);
        }
        if g.slide_t > 0.0 {
            // Sliding cyber-runner silhouette
            push_quad(verts, px - 18.0, py - 22.0, 36.0, 16.0, [56, 189, 248, 255]);
            push_quad(verts, px + 4.0, py - 24.0, 14.0, 14.0, [245, 248, 255, 255]);
            push_quad(verts, px + 11.0, py - 20.0, 8.0, 5.0, [80, 250, 255, 255]);
        } else {
            let stride = if g.on_ground { sin(g.run_phase) * 8.0 } else { 6.0 };
            // Legs
            push_quad(verts, px - 8.0 + stride, py - 16.0, 7.0, 16.0, [34, 48, 86, 255]);
            push_quad(verts, px + 1.0 - stride, py - 16.0, 7.0, 16.0, [58, 84, 142, 255]);
            // Torso jacket
            push_quad(verts, px - 10.0, py - 34.0, 20.0, 20.0, [56, 189, 248, 255]);
            // Head + glowing visor
            push_quad(verts, px - 8.0, py - 46.0, 17.0, 14.0, [245, 248, 255, 255]);
            push_quad(verts, px + 1.0, py - 42.0, 9.0, 5.0, [75, 245, 255, 255]);
        }
    }

    // 10. Particles
    for i in MAX_PARTS {
        let p = g.parts[i];
        if p.life > 0.0 {
            let a = (clamp(p.life / p.max_life, 0.0, 1.0) * 255.0) as u8;
            let sz = 3.0 + 4.0 * (p.life / p.max_life);
            let pc: u8[4] = [p.color[0], p.color[1], p.color[2], a];
            push_quad(verts, p.x - sz * 0.5, p.y - sz * 0.5, sz, sz, pc);
        }
    }
}

fn build_tone(f0: f64, f1: f64, dur: f64) -> f32[>..] {
    let rate = 48000;
    let n = (dur * rate) as i64;
    var pcm: f32[>..] = [];
    for i in n {
        let frac = i / (n as f64);
        let freq = f0 + (f1 - f0) * frac;
        let t = i / (rate as f64);
        pcm.push((sin(TAU * freq * t) * 0.22 * (1.0 - frac)) as f32);
    }
    return pcm;
}

fn run_tests() {
    var g = new_dash(101, 0);
    check(g.on_ground && g.jumps_left == 2, "runner must start on ground with 2 jumps");

    // Double jump test
    trigger_jump(g);
    check(!g.on_ground && g.jumps_left == 1 && g.sfx_jump, "first jump state mismatch");
    step_dash(g, 0.08, false);
    check(g.player_y < 390.0, "runner must rise after jump");
    trigger_jump(g);
    check(g.jumps_left == 0, "double jump must consume second jump");

    // Slide hitbox reduction test
    var g2 = new_dash(202, 0);
    trigger_slide(g2);
    check(g2.slide_t > 0.0 && player_height(g2) < 30.0, "slide must shrink player height");

    // Coin + Shield collision test
    var g3 = new_dash(303, 0);
    for i in MAX_ENTS { g3.ents[i].kind = ENT_NONE; }
    g3.ents[0] = SkyEntity { kind: ENT_COIN, x: g3.player_x, y: g3.player_y - 25.0, w: 18.0, h: 18.0, phase: 0.0 };
    g3.ents[1] = SkyEntity { kind: ENT_SHIELD, x: g3.player_x, y: g3.player_y - 25.0, w: 22.0, h: 22.0, phase: 0.0 };
    step_dash(g3, 0.016, false);
    check(g3.coins == 1 && g3.has_shield, "coin and shield pickup failed");

    // Shield absorbs laser impact instead of ending game
    g3.ents[2] = SkyEntity { kind: ENT_LASER, x: g3.player_x, y: g3.player_y - 46.0, w: 18.0, h: 46.0, phase: 0.0 };
    step_dash(g3, 0.016, false);
    check(!g3.game_over && !g3.has_shield && g3.invuln_t > 0.5, "shield must absorb laser hit");

    var verts: Vertex2D[>..] = [];
    render_dash(g, verts);
    check(verts.len > 400 && verts.len <= MAX_VERTS, "sky_dash vertex batch invalid");

    print("PASS sky_dash (rooftop physics, double-jump, slide, coin/shield, GPU batching)\n");
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

    guard gfx::open("Goose Sky Dash", 960, 540, gfx::WINDOW_RESIZABLE) else {
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
    if dpi_scale != ui::scale(ctx) { ui::set_scale(ctx, dpi_scale); }

    var hud_style = ui::style(ctx);
    hud_style.window.fixed_background = ui::style_item_hide();
    hud_style.window.padding = float2 { 16.0, 12.0 };
    ui::set_style(ctx, hud_style);

    let vs = embed_shader("vert", """
        layout(location = 0) in vec2 a_pos;
        layout(location = 1) in vec4 a_color;
        layout(set = 1, binding = 0) uniform Ortho { vec4 screen; };
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
        void main() { out_color = v_color; }
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
    var sfx_j = audio::Sound { id: 0 };
    var sfx_c = audio::Sound { id: 0 };
    var sfx_s = audio::Sound { id: 0 };
    if use_audio {
        if audio::open() {
            sfx_j = audio::create_sound(build_tone(290.0, 580.0, 0.09));
            sfx_c = audio::create_sound(build_tone(780.0, 1180.0, 0.08));
            sfx_s = audio::create_sound(build_tone(420.0, 840.0, 0.14));
        } else {
            use_audio = false;
        }
    }
    defer {
        if use_audio {
            audio::release_sound(sfx_j);
            audio::release_sound(sfx_c);
            audio::release_sound(sfx_s);
            audio::close();
        }
    }

    var game = new_dash(if demo_mode { 909 } else { random_seed() }, 0);
    var verts: Vertex2D[>..] = [];
    var drawn: i64 = 0;
    var has_hud = false;

    while gfx::frame() {
        if gfx::key_pressed("Escape") { break; }
        if gfx::key_pressed("Space") || gfx::key_pressed("Up") || gfx::key_pressed("W") {
            if game.game_over { game = new_dash(random_seed(), game.best); }
            else { trigger_jump(game); }
        }
        if gfx::key_pressed("Down") || gfx::key_pressed("S") {
            trigger_slide(game);
        }
        if gfx::key_pressed("P") && !game.game_over { game.paused = !game.paused; }
        if gfx::key_pressed("R") { game = new_dash(random_seed(), game.best); }

        let dt = if demo_mode { 1.0 / 60.0 } else { min(gfx::delta_time(), 0.04) };
        step_dash(game, dt as f32, demo_mode);

        if use_audio {
            if game.sfx_jump && sfx_j.id != 0 { audio::play(sfx_j, 0.45); }
            if game.sfx_coin && sfx_c.id != 0 { audio::play(sfx_c, 0.50); }
            if game.sfx_shield && sfx_s.id != 0 { audio::play(sfx_s, 0.55); }
        }

        render_dash(game, verts);
        if verts.len > 0 { gfx::update_buffer(vb, bytes_of(verts)); }

        ui::input_from_gfx(ctx);
        let px = gfx::screen_size();
        let sc = ui::scale(ctx);
        let hud_bounds = ui::rect(0.0, 0.0, px.x / sc, px.y / sc);
        if has_hud { ui::window_set_bounds(ctx, "DashHUD", hud_bounds); }
        if ui::begin(ctx, "DashHUD", hud_bounds, ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) {
            has_hud = true;
            ui::layout_row_dynamic(ctx, 28.0, 4);
            ui::label_colored(ctx, str("SCORE: ", game.score), ui::TEXT_LEFT, ui::rgb(110, 235, 255));
            ui::label_colored(ctx, str("COINS: ", game.coins), ui::TEXT_CENTERED, ui::rgb(255, 215, 70));
            let status_txt: u8[>..] = if game.has_shield {
                str("SHIELD: ON")
            } else {
                str("DIST: ", game.distance as i64, "m")
            };
            ui::label_colored(ctx, status_txt,
                              ui::TEXT_CENTERED, if game.has_shield { ui::rgb(80, 240, 255) } else { ui::rgb(220, 230, 250) });
            ui::label_colored(ctx, str("BEST: ", game.best), ui::TEXT_RIGHT, ui::rgb(130, 240, 175));

            if game.game_over || game.paused {
                ui::layout_row_dynamic(ctx, 180.0, 1);
                ui::spacer(ctx);
                ui::layout_row_dynamic(ctx, 34.0, 1);
                let msg = if game.game_over {
                    str("WIPEOUT! Press SPACE or R to Run Again")
                } else {
                    str("PAUSED — Press P to Resume")
                };
                ui::label_colored(ctx, msg, ui::TEXT_CENTERED, ui::rgb(255, 130, 145));
            }
        }
        ui::end(ctx);

        gfx::begin_screen(float4 { 0.05, 0.05, 0.13, 1.0 });
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
        check(ok, "failed to save sky_dash screenshot");
    }
}

// super_goose: 2D Mario-Style Side-Scrolling Platformer in Goose (gfx + ui + audio).
//
// Features:
//   - Four full side-scrolling worlds (1-1 Sunny Meadow, 1-2 Twilight Highlands,
//     1-3 Sunset Sky Bridges, 1-4 Crimson Fortress) + stage-select hotkeys (1-4)
//   - Mario-inspired physics: acceleration, friction, coyote time, jump buffer, separate X/Y AABB
//   - Head-bonk Question Blocks ('?' coins & 'M' Golden Feather power-up to grow Super Goose!)
//   - Patrolling foes you can stomp from above (+200 + bounce), warp pipes, Victory Castle & flagpole
//   - Pixel-art multi-quad Super Goose hero, parallax clouds & hills, Retina HUD, chiptune SFX
//   - CLI flags: --test, --demo, --frames N, --screenshot <path>

import std;
import vec;
import math;
import os;
import gfx;
import ui;
import audio;

let FONT: const u8[:] = embed_file("../../../assets/Roboto-Regular.ttf");

let VIEW_W: f32 = 960.0;
let VIEW_H: f32 = 540.0;
let TILE: f32 = 36.0;
let MAP_W: i64 = 112;
let MAP_H: i64 = 15;
let MAX_WORLDS: i64 = 4;
let MAX_TILES: i64 = 1680;
let MAX_VERTS: i64 = 16384;
let MAX_ENEMIES: i64 = 16;
let MAX_POPUPS: i64 = 12;
let MAX_PARTS: i64 = 64;

struct Vertex2D { pos: float2, color: u8[4] }
struct OrthoUniform { screen: float4 }

struct Enemy {
    alive: bool,
    squish_t: f32,
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    w: f32,
    h: f32,
}

struct Feather {
    active: bool,
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
}

struct CoinPopup {
    life: f32,
    x: f32,
    y: f32,
}

struct Particle {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    life: f32,
    color: u8[4],
}

struct PlatformGame {
    tiles: u8[1680],
    bump: f32[1680],
    enemies: Enemy[16],
    popups: CoinPopup[12],
    parts: Particle[64],
    feather: Feather,
    world_num: i64,
    px: f32,
    py: f32,
    vx: f32,
    vy: f32,
    facing: f32,
    on_ground: bool,
    coyote_t: f32,
    jump_buf_t: f32,
    big: bool,
    invuln_t: f32,
    cam_x: f32,
    score: i64,
    coins: i64,
    lives: i64,
    time_left: f32,
    time_s: f32,
    walk_phase: f32,
    won_level: bool,
    won_game: bool,
    win_timer: f32,
    game_over: bool,
    paused: bool,
    prng: rng,
    sfx_jump: bool,
    sfx_coin: bool,
    sfx_stomp: bool,
    sfx_power: bool,
    sfx_clear: bool,
}

fn check(ok: bool, msg: const u8[:]) {
    if !ok { abort(msg); }
}

fn tile_at(g: const PlatformGame&, tx: i64, ty: i64) -> u8 {
    if tx < 0 || tx >= MAP_W { return 'S'; }
    if ty < 0 { return '.'; }
    if ty >= MAP_H { return '.'; }
    return g.tiles[ty * MAP_W + tx];
}

fn is_solid_tile(ch: u8) -> bool {
    ch == 'G' || ch == 'D' || ch == 'B' || ch == '?' || ch == 'M' || ch == 'U' ||
    ch == '[' || ch == ']' || ch == '{' || ch == '}' || ch == 'S'
}

fn set_tile(g: PlatformGame&, tx: i64, ty: i64, ch: u8) {
    if tx < 0 || tx >= MAP_W || ty < 0 || ty >= MAP_H { return; }
    g.tiles[ty * MAP_W + tx] = ch;
}

fn fill_ground(g: PlatformGame&, x0: i64, x1: i64) {
    var x = x0;
    while x <= x1 {
        set_tile(g, x, 13, 'G');
        set_tile(g, x, 14, 'D');
        x++;
    }
}

fn add_pipe(g: PlatformGame&, tx: i64, top_y: i64) {
    set_tile(g, tx, top_y, '[');
    set_tile(g, tx + 1, top_y, ']');
    var y = top_y + 1;
    while y < 13 {
        set_tile(g, tx, y, '{');
        set_tile(g, tx + 1, y, '}');
        y++;
    }
}

fn load_level(g: PlatformGame&, level_num: i64) {
    g.world_num = level_num;
    for i in MAX_TILES {
        g.tiles[i] = '.';
        g.bump[i] = 0.0;
    }
    for i in MAX_ENEMIES { g.enemies[i] = default<Enemy>(); }
    for i in MAX_POPUPS { g.popups[i] = default<CoinPopup>(); }
    for i in MAX_PARTS { g.parts[i] = default<Particle>(); }
    g.feather = default<Feather>();

    if level_num == 1 {
        // World 1-1 Sunny Meadow
        fill_ground(g, 0, 32);
        fill_ground(g, 35, 62);
        fill_ground(g, 65, 111);

        // Opening brick & question block cluster (visible immediately!)
        set_tile(g, 11, 9, '?');
        set_tile(g, 15, 9, 'B');
        set_tile(g, 16, 9, 'M');
        set_tile(g, 17, 9, 'B');
        set_tile(g, 18, 9, '?');
        set_tile(g, 19, 9, 'B');
        set_tile(g, 17, 5, '?');

        // Pipes & floating coins
        add_pipe(g, 24, 11);
        set_tile(g, 24, 8, 'C'); set_tile(g, 25, 8, 'C');
        add_pipe(g, 30, 10);

        // Coin arc over first pit (x=33..34)
        set_tile(g, 33, 8, 'C'); set_tile(g, 34, 8, 'C');

        // Mid-stage elevated platform & bricks
        set_tile(g, 42, 9, 'B'); set_tile(g, 43, 9, '?'); set_tile(g, 44, 9, 'B');
        set_tile(g, 47, 6, 'B'); set_tile(g, 48, 6, 'B'); set_tile(g, 49, 6, 'B');
        set_tile(g, 48, 5, 'C'); set_tile(g, 49, 5, 'C');

        add_pipe(g, 54, 10);
        set_tile(g, 63, 9, 'C'); set_tile(g, 64, 9, 'C');

        // Brick bridge & bonus
        set_tile(g, 70, 9, '?'); set_tile(g, 71, 9, 'B'); set_tile(g, 72, 9, '?');
        set_tile(g, 76, 6, 'C'); set_tile(g, 77, 6, 'C'); set_tile(g, 78, 6, 'C');

        // Classic staircase up to flagpole
        for step in 5 {
            var y = 12;
            while y >= 12 - step {
                set_tile(g, 88 + step, y, 'S');
                y--;
            }
        }

        // Flagpole at x=98
        for y in 4..13 { set_tile(g, 98, y, 'F'); }
        set_tile(g, 98, 12, 'S');

        // Patrolling foes
        let exs: f32[8] = [16.0, 21.0, 38.0, 46.0, 58.0, 68.0, 74.0, 82.0];
        for i in 8 {
            g.enemies[i] = Enemy {
                alive: true,
                squish_t: 0.0,
                x: exs[i] * TILE,
                y: 12.0 * TILE,
                vx: -72.0,
                vy: 0.0,
                w: 30.0,
                h: 28.0,
            };
        }
    } else if level_num == 2 {
        // World 1-2 Twilight Highlands
        fill_ground(g, 0, 22);
        fill_ground(g, 25, 48);
        fill_ground(g, 51, 76);
        fill_ground(g, 79, 111);

        set_tile(g, 10, 9, 'B'); set_tile(g, 11, 9, 'M'); set_tile(g, 12, 9, 'B');
        add_pipe(g, 16, 10);
        set_tile(g, 23, 8, 'C'); set_tile(g, 24, 8, 'C');
        set_tile(g, 30, 9, 'B'); set_tile(g, 31, 9, '?'); set_tile(g, 32, 9, '?'); set_tile(g, 33, 9, 'B');
        add_pipe(g, 38, 10);
        set_tile(g, 49, 8, 'C'); set_tile(g, 50, 8, 'C');
        set_tile(g, 56, 9, 'B'); set_tile(g, 57, 9, '?'); set_tile(g, 58, 9, 'B');
        set_tile(g, 64, 6, 'C'); set_tile(g, 65, 6, 'C'); set_tile(g, 66, 6, 'C');
        add_pipe(g, 70, 10);

        for step in 6 {
            var y = 12;
            while y >= 12 - step {
                set_tile(g, 88 + step, y, 'S');
                y--;
            }
        }
        for y in 4..13 { set_tile(g, 99, y, 'F'); }
        set_tile(g, 99, 12, 'S');

        let exs: f32[8] = [13.0, 28.0, 35.0, 44.0, 55.0, 62.0, 68.0, 82.0];
        for i in 8 {
            g.enemies[i] = Enemy {
                alive: true,
                squish_t: 0.0,
                x: exs[i] * TILE,
                y: 12.0 * TILE,
                vx: -86.0,
                vy: 0.0,
                w: 30.0,
                h: 28.0,
            };
        }
    } else if level_num == 3 {
        // World 1-3 Sunset Sky Bridges
        fill_ground(g, 0, 18);
        fill_ground(g, 21, 33);
        fill_ground(g, 36, 49);
        fill_ground(g, 52, 65);
        fill_ground(g, 68, 81);
        fill_ground(g, 84, 111);

        // Opening power-up & coin blocks
        set_tile(g, 10, 9, 'B'); set_tile(g, 11, 9, 'M'); set_tile(g, 12, 9, '?'); set_tile(g, 13, 9, 'B');
        set_tile(g, 19, 8, 'C'); set_tile(g, 20, 8, 'C');

        // Elevated bridge + low warp pipe
        for bx in 24..28 { set_tile(g, bx, 10, 'S'); }
        set_tile(g, 25, 8, 'C'); set_tile(g, 26, 8, 'C');
        add_pipe(g, 29, 11);
        set_tile(g, 34, 8, 'C'); set_tile(g, 35, 8, 'C');

        // Multi-tier sky bridges
        set_tile(g, 38, 10, 'B'); set_tile(g, 39, 10, '?'); set_tile(g, 40, 10, 'B');
        for bx in 43..48 { set_tile(g, bx, 7, 'S'); }
        set_tile(g, 44, 6, 'C'); set_tile(g, 45, 6, 'C'); set_tile(g, 46, 6, 'C');
        set_tile(g, 50, 8, 'C'); set_tile(g, 51, 8, 'C');

        // Mid bricks & 3-tile pipe at x=60
        set_tile(g, 55, 9, 'B'); set_tile(g, 56, 9, '?'); set_tile(g, 57, 9, 'B');
        add_pipe(g, 60, 10);
        set_tile(g, 66, 8, 'C'); set_tile(g, 67, 8, 'C');

        // High coin span before final staircase
        for bx in 72..78 { set_tile(g, bx, 9, 'B'); }
        set_tile(g, 74, 9, '?'); set_tile(g, 75, 9, '?');
        set_tile(g, 74, 7, 'C'); set_tile(g, 75, 7, 'C');
        set_tile(g, 82, 8, 'C'); set_tile(g, 83, 8, 'C');

        for step in 6 {
            var y = 12;
            while y >= 12 - step {
                set_tile(g, 87 + step, y, 'S');
                y--;
            }
        }
        for y in 4..13 { set_tile(g, 99, y, 'F'); }
        set_tile(g, 99, 12, 'S');

        let exs: f32[9] = [14.0, 24.0, 32.0, 41.0, 47.0, 56.0, 69.0, 75.0, 85.0];
        for i in 9 {
            g.enemies[i] = Enemy {
                alive: true,
                squish_t: 0.0,
                x: exs[i] * TILE,
                y: 12.0 * TILE,
                vx: -92.0,
                vy: 0.0,
                w: 30.0,
                h: 28.0,
            };
        }
    } else {
        // World 1-4 Crimson Fortress (lava moats, stone bridges, 3-tile pipes)
        fill_ground(g, 0, 17);
        fill_ground(g, 20, 35);
        fill_ground(g, 38, 53);
        fill_ground(g, 56, 73);
        fill_ground(g, 76, 111);

        set_tile(g, 10, 9, 'S'); set_tile(g, 11, 9, 'M'); set_tile(g, 12, 9, '?'); set_tile(g, 13, 9, 'S');
        set_tile(g, 18, 8, 'C'); set_tile(g, 19, 8, 'C');

        add_pipe(g, 24, 10);
        set_tile(g, 29, 9, 'S'); set_tile(g, 30, 9, '?'); set_tile(g, 31, 9, '?'); set_tile(g, 32, 9, 'S');
        set_tile(g, 36, 8, 'C'); set_tile(g, 37, 8, 'C');

        set_tile(g, 41, 9, 'S'); set_tile(g, 42, 9, '?'); set_tile(g, 43, 9, 'S');
        add_pipe(g, 48, 10);

        // Fortress stone bridge spanning lava moat at x=54..55
        for bx in 53..59 { set_tile(g, bx, 9, 'S'); }
        set_tile(g, 55, 7, 'C'); set_tile(g, 56, 7, 'C');
        set_tile(g, 61, 9, 'B'); set_tile(g, 62, 9, '?'); set_tile(g, 63, 9, 'B');
        add_pipe(g, 66, 10);
        set_tile(g, 70, 9, 'S'); set_tile(g, 71, 9, '?'); set_tile(g, 72, 9, 'S');
        set_tile(g, 74, 8, 'C'); set_tile(g, 75, 8, 'C');

        for step in 6 {
            var y = 12;
            while y >= 12 - step {
                set_tile(g, 87 + step, y, 'S');
                y--;
            }
        }
        for y in 4..13 { set_tile(g, 99, y, 'F'); }
        set_tile(g, 99, 12, 'S');

        let exs: f32[10] = [13.0, 21.0, 31.0, 42.0, 44.0, 58.0, 63.0, 71.0, 79.0, 84.0];
        for i in 10 {
            g.enemies[i] = Enemy {
                alive: true,
                squish_t: 0.0,
                x: exs[i] * TILE,
                y: 12.0 * TILE,
                vx: -98.0,
                vy: 0.0,
                w: 30.0,
                h: 28.0,
            };
        }
    }

    g.px = 3.0 * TILE;
    g.py = 13.0 * TILE - (if g.big { 42.0 } else { 32.0 });
    g.vx = 0.0;
    g.vy = 0.0;
    g.facing = 1.0;
    g.on_ground = true;
    g.coyote_t = 0.1;
    g.jump_buf_t = 0.0;
    g.cam_x = 0.0;
    g.time_left = 180.0;
    g.won_level = false;
    g.won_game = false;
    g.win_timer = 0.0;
}

fn new_platform(seed: u64) -> PlatformGame {
    var g = PlatformGame {
        tiles: ['.'; 1680],
        bump: [0.0; 1680],
        enemies: [default<Enemy>(); 16],
        popups: [default<CoinPopup>(); 12],
        parts: [default<Particle>(); 64],
        feather: default<Feather>(),
        world_num: 1,
        px: 108.0,
        py: 400.0,
        vx: 0.0,
        vy: 0.0,
        facing: 1.0,
        on_ground: true,
        coyote_t: 0.1,
        jump_buf_t: 0.0,
        big: false,
        invuln_t: 0.0,
        cam_x: 0.0,
        score: 0,
        coins: 0,
        lives: 3,
        time_left: 180.0,
        time_s: 0.0,
        walk_phase: 0.0,
        won_level: false,
        won_game: false,
        win_timer: 0.0,
        game_over: false,
        paused: false,
        prng: rng { seed },
        sfx_jump: false,
        sfx_coin: false,
        sfx_stomp: false,
        sfx_power: false,
        sfx_clear: false,
    };
    load_level(g, 1);
    return g;
}

fn player_w() -> f32 { 26.0 }
fn player_h(g: const PlatformGame&) -> f32 { if g.big { 42.0 } else { 32.0 } }

fn spawn_parts(g: PlatformGame&, x: f32, y: f32, col: u8[4], count: i64) {
    var s: i64 = 0;
    for i in MAX_PARTS {
        if s >= count { break; }
        if g.parts[i].life <= 0.0 {
            let ang = (g.prng.rand_flt() * TAU) as f32;
            let spd = 60.0 + (g.prng.rand_flt() * 170.0) as f32;
            g.parts[i] = Particle {
                x: x,
                y: y,
                vx: cos(ang) * spd,
                vy: sin(ang) * spd - 90.0,
                life: 0.45,
                color: col,
            };
            s++;
        }
    }
}

fn spawn_popup(g: PlatformGame&, x: f32, y: f32) {
    for i in MAX_POPUPS {
        if g.popups[i].life <= 0.0 {
            g.popups[i] = CoinPopup { life: 0.55, x: x, y: y };
            return;
        }
    }
}

fn bonk_block(g: PlatformGame&, tx: i64, ty: i64) {
    if tx < 0 || tx >= MAP_W || ty < 0 || ty >= MAP_H { return; }
    let idx = ty * MAP_W + tx;
    let ch = g.tiles[idx];
    if ch == '?' {
        g.tiles[idx] = 'U';
        g.bump[idx] = 1.0;
        g.coins++;
        g.score += 100;
        g.sfx_coin = true;
        spawn_popup(g, tx * TILE + 10.0, ty * TILE - 12.0);
        spawn_parts(g, tx * TILE + 18.0, ty * TILE, [255, 220, 70, 255], 8);
    } else if ch == 'M' {
        g.tiles[idx] = 'U';
        g.bump[idx] = 1.0;
        g.feather = Feather {
            active: true,
            x: tx * TILE + 6.0,
            y: ty * TILE - 28.0,
            vx: 95.0,
            vy: -140.0,
        };
        g.sfx_power = true;
        spawn_parts(g, tx * TILE + 18.0, ty * TILE, [255, 235, 130, 255], 10);
    } else if ch == 'B' {
        g.bump[idx] = 0.7;
        spawn_parts(g, tx * TILE + 18.0, ty * TILE + 18.0, [215, 110, 65, 255], 6);
    }
}

fn collide_rect_tiles(g: const PlatformGame&, rx: f32, ry: f32, rw: f32, rh: f32) -> bool {
    let x0 = floor(rx / TILE) as i64;
    let x1 = floor((rx + rw - 0.01) / TILE) as i64;
    let y0 = floor(ry / TILE) as i64;
    let y1 = floor((ry + rh - 0.01) / TILE) as i64;
    var ty = y0;
    while ty <= y1 {
        var tx = x0;
        while tx <= x1 {
            if is_solid_tile(tile_at(g, tx, ty)) { return true; }
            tx++;
        }
        ty++;
    }
    return false;
}

fn demo_controller(g: const PlatformGame&) -> f32, bool {
    var move_dir: f32 = 1.0;
    var want_jump = false;

    let foot_ty = floor((g.py + player_h(g) + 4.0) / TILE) as i64;
    let front_tx = floor((g.px + player_w() + 14.0) / TILE) as i64;
    let body_ty = floor((g.py + player_h(g) * 0.5) / TILE) as i64;

    // Jump over solid pipes/walls or pits ahead
    if is_solid_tile(tile_at(g, front_tx, body_ty)) ||
       !is_solid_tile(tile_at(g, front_tx, foot_ty)) {
        want_jump = true;
    }

    // Jump under '?' or 'M' blocks to showcase bonking
    let cur_tx = floor((g.px + player_w() * 0.5) / TILE) as i64;
    let above_ch = tile_at(g, cur_tx, body_ty - 2);
    if above_ch == '?' || above_ch == 'M' {
        want_jump = true;
    }

    // Jump over incoming patrolling enemy if close
    for i in MAX_ENEMIES {
        let e = g.enemies[i];
        if e.alive && e.x > g.px && e.x < g.px + 75.0 && abs(e.y - g.py) < 42.0 {
            want_jump = true;
        }
    }

    return move_dir, want_jump;
}

fn step_platform(g: PlatformGame&, dt: f32, move_in: f32, jump_pressed: bool,
                 jump_held: bool, demo_ai: bool) {
    g.sfx_jump = false;
    g.sfx_coin = false;
    g.sfx_stomp = false;
    g.sfx_power = false;
    g.sfx_clear = false;
    if g.paused || g.game_over { return; }

    g.time_s += dt;
    if g.won_level {
        g.win_timer -= dt;
        if g.win_timer <= 0.0 {
            if !g.won_game {
                load_level(g, g.world_num + 1);
            } else if demo_ai {
                load_level(g, 1);
            }
        }
        return;
    }

    var move_x = move_in;
    var j_press = jump_pressed;
    var j_hold = jump_held;
    if demo_ai {
        let dm, dj = demo_controller(g);
        move_x = dm;
        j_press = dj && g.on_ground;
        j_hold = dj || g.vy < 0.0;
    }

    g.time_left = max(g.time_left - dt, 0.0);
    if g.invuln_t > 0.0 { g.invuln_t = max(g.invuln_t - dt, 0.0); }

    // Decay block bumps, popups, particles
    for i in MAX_TILES {
        if g.bump[i] > 0.0 { g.bump[i] = max(g.bump[i] - dt * 5.5, 0.0); }
    }
    for i in MAX_POPUPS {
        if g.popups[i].life > 0.0 {
            g.popups[i].y -= 75.0 * dt;
            g.popups[i].life -= dt;
        }
    }
    for i in MAX_PARTS {
        if g.parts[i].life > 0.0 {
            g.parts[i].x += g.parts[i].vx * dt;
            g.parts[i].y += g.parts[i].vy * dt;
            g.parts[i].vy += 520.0 * dt;
            g.parts[i].life -= dt;
        }
    }

    // Horizontal velocity with Mario-style inertia
    if move_x != 0.0 {
        g.facing = move_x;
        let accel: f32 = if g.on_ground { 1450.0 } else { 950.0 };
        g.vx += move_x * accel * dt;
        g.vx = clamp(g.vx, -255.0, 255.0);
    } else {
        let fric: f32 = if g.on_ground { 1600.0 } else { 220.0 };
        if abs(g.vx) <= fric * dt { g.vx = 0.0; }
        else { g.vx -= (if g.vx > 0.0 { fric } else { -fric }) * dt; }
    }
    if g.on_ground && abs(g.vx) > 15.0 { g.walk_phase += dt * abs(g.vx) * 0.06; }

    // Coyote time & jump buffer
    if g.on_ground { g.coyote_t = 0.10; } else { g.coyote_t = max(g.coyote_t - dt, 0.0); }
    if j_press { g.jump_buf_t = 0.10; } else { g.jump_buf_t = max(g.jump_buf_t - dt, 0.0); }

    if g.jump_buf_t > 0.0 && g.coyote_t > 0.0 {
        g.vy = -660.0;
        g.on_ground = false;
        g.coyote_t = 0.0;
        g.jump_buf_t = 0.0;
        g.sfx_jump = true;
        spawn_parts(g, g.px + 13.0, g.py + player_h(g), [220, 235, 250, 255], 5);
    }
    if !j_hold && g.vy < -220.0 {
        g.vy = -220.0;
    }

    g.vy = min(g.vy + 1380.0 * dt, 680.0);

    let pw = player_w();
    let ph = player_h(g);

    // Resolve X
    g.px += g.vx * dt;
    if g.px < 0.0 { g.px = 0.0; g.vx = 0.0; }
    if collide_rect_tiles(g, g.px, g.py, pw, ph) {
        if g.vx > 0.0 {
            let tx = floor((g.px + pw - 0.01) / TILE) as i64;
            g.px = tx * TILE - pw;
        } else if g.vx < 0.0 {
            let tx = floor(g.px / TILE) as i64;
            g.px = (tx + 1) * TILE;
        }
        g.vx = 0.0;
    }

    // Resolve Y
    g.py += g.vy * dt;
    g.on_ground = false;
    if collide_rect_tiles(g, g.px, g.py, pw, ph) {
        if g.vy > 0.0 {
            let ty = floor((g.py + ph - 0.01) / TILE) as i64;
            g.py = ty * TILE - ph;
            g.vy = 0.0;
            g.on_ground = true;
        } else if g.vy < 0.0 {
            let ty = floor(g.py / TILE) as i64;
            let mid_tx = floor((g.px + pw * 0.5) / TILE) as i64;
            bonk_block(g, mid_tx, ty);
            g.py = (ty + 1) * TILE;
            g.vy = 0.0;
        }
    }

    // Collect floating coins & check flagpole
    let x0 = floor(g.px / TILE) as i64;
    let x1 = floor((g.px + pw) / TILE) as i64;
    let y0 = floor(g.py / TILE) as i64;
    let y1 = floor((g.py + ph) / TILE) as i64;
    var ty = y0;
    while ty <= y1 {
        var tx = x0;
        while tx <= x1 {
            let ch = tile_at(g, tx, ty);
            if ch == 'C' {
                set_tile(g, tx, ty, '.');
                g.coins++;
                g.score += 100;
                g.sfx_coin = true;
                spawn_parts(g, tx * TILE + 18.0, ty * TILE + 18.0, [255, 220, 70, 255], 6);
            } else if ch == 'F' && !g.won_level {
                g.won_level = true;
                if g.world_num >= MAX_WORLDS {
                    g.won_game = true;
                    g.win_timer = 2.5;
                    g.score += 2500 + (g.time_left as i64) * 5;
                } else {
                    g.win_timer = 1.8;
                    g.score += 1000 + (g.time_left as i64) * 5;
                }
                g.sfx_clear = true;
                spawn_parts(g, tx * TILE + 18.0, g.py, [100, 255, 160, 255], 20);
            }
            tx++;
        }
        ty++;
    }

    // Golden Feather power-up physics
    if g.feather.active {
        g.feather.vy = min(g.feather.vy + 780.0 * dt, 360.0);
        g.feather.x += g.feather.vx * dt;
        if collide_rect_tiles(g, g.feather.x, g.feather.y, 24.0, 24.0) {
            g.feather.vx = -g.feather.vx;
            g.feather.x += g.feather.vx * dt * 2.0;
        }
        g.feather.y += g.feather.vy * dt;
        if collide_rect_tiles(g, g.feather.x, g.feather.y, 24.0, 24.0) {
            let fty = floor((g.feather.y + 24.0) / TILE) as i64;
            g.feather.y = fty * TILE - 24.0;
            g.feather.vy = 0.0;
        }
        if g.px + pw > g.feather.x && g.px < g.feather.x + 24.0 &&
           g.py + ph > g.feather.y && g.py < g.feather.y + 24.0 {
            g.feather.active = false;
            if !g.big {
                g.big = true;
                g.py -= 10.0;
            }
            g.score += 500;
            g.sfx_power = true;
            spawn_parts(g, g.px + 13.0, g.py + 15.0, [255, 215, 70, 255], 16);
        }
    }

    // Patrolling Enemies
    for i in MAX_ENEMIES {
        if g.enemies[i].squish_t > 0.0 {
            g.enemies[i].squish_t -= dt;
        }
        if !g.enemies[i].alive { continue; }
        var e = g.enemies[i];
        e.vy = min(e.vy + 980.0 * dt, 480.0);
        e.x += e.vx * dt;
        if collide_rect_tiles(g, e.x, e.y, e.w, e.h) {
            e.vx = -e.vx;
            e.x += e.vx * dt * 2.0;
        }
        e.y += e.vy * dt;
        if collide_rect_tiles(g, e.x, e.y, e.w, e.h) {
            let ety = floor((e.y + e.h) / TILE) as i64;
            e.y = ety * TILE - e.h;
            e.vy = 0.0;
        }
        // Reverse before falling off cliff
        let ahead_x = if e.vx < 0.0 { e.x - 4.0 } else { e.x + e.w + 4.0 };
        let ground_tx = floor(ahead_x / TILE) as i64;
        let ground_ty = floor((e.y + e.h + 4.0) / TILE) as i64;
        if !is_solid_tile(tile_at(g, ground_tx, ground_ty)) {
            e.vx = -e.vx;
        }
        g.enemies[i] = e;

        // Player vs Enemy
        let cur_ph = player_h(g);
        if g.px + pw > e.x && g.px < e.x + e.w && g.py + cur_ph > e.y && g.py < e.y + e.h {
            if g.vy > 0.0 && g.py + cur_ph <= e.y + e.h * 0.65 {
                // Stomp!
                g.enemies[i].alive = false;
                g.enemies[i].squish_t = 0.35;
                g.vy = -380.0;
                g.score += 200;
                g.sfx_stomp = true;
                spawn_parts(g, e.x + 15.0, e.y + 10.0, [255, 195, 120, 255], 10);
            } else if g.invuln_t <= 0.0 && !demo_ai {
                if g.big {
                    g.big = false;
                    g.invuln_t = 1.4;
                } else {
                    g.lives -= 1;
                    if g.lives <= 0 { g.game_over = true; }
                    else { load_level(g, g.world_num); }
                    return;
                }
            }
        }
    }

    // Pit fall
    if g.py > VIEW_H + 40.0 {
        if demo_ai {
            g.py = 8.0 * TILE;
            g.vy = 0.0;
        } else {
            g.big = false;
            g.lives -= 1;
            if g.lives <= 0 { g.game_over = true; }
            else { load_level(g, g.world_num); }
            return;
        }
    }

    // Camera follow
    let target_cam = g.px - VIEW_W * 0.35;
    let max_cam = MAP_W * TILE - VIEW_W;
    g.cam_x = clamp(target_cam, 0.0, max_cam);
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

fn render_platform(g: const PlatformGame&, verts: Vertex2D[>..]&) {
    verts.clear();

    // 1. Sky gradient across all 4 worlds
    if g.world_num == 1 {
        push_quad(verts, 0.0, 0.0, VIEW_W, 200.0, [68, 146, 236, 255]);
        push_quad(verts, 0.0, 200.0, VIEW_W, 180.0, [108, 182, 248, 255]);
        push_quad(verts, 0.0, 380.0, VIEW_W, 160.0, [148, 212, 254, 255]);
    } else if g.world_num == 2 {
        push_quad(verts, 0.0, 0.0, VIEW_W, 200.0, [24, 22, 54, 255]);
        push_quad(verts, 0.0, 200.0, VIEW_W, 180.0, [48, 36, 86, 255]);
        push_quad(verts, 0.0, 380.0, VIEW_W, 160.0, [86, 48, 98, 255]);
    } else if g.world_num == 3 {
        push_quad(verts, 0.0, 0.0, VIEW_W, 200.0, [156, 62, 86, 255]);
        push_quad(verts, 0.0, 200.0, VIEW_W, 180.0, [218, 114, 72, 255]);
        push_quad(verts, 0.0, 380.0, VIEW_W, 160.0, [248, 176, 94, 255]);
    } else {
        push_quad(verts, 0.0, 0.0, VIEW_W, 200.0, [36, 12, 22, 255]);
        push_quad(verts, 0.0, 200.0, VIEW_W, 180.0, [74, 20, 28, 255]);
        push_quad(verts, 0.0, 380.0, VIEW_W, 160.0, [118, 32, 26, 255]);
    }

    // 2. Parallax clouds & rolling hills
    let cloud_c: u8[4] = if g.world_num == 1 {
        [248, 252, 255, 235]
    } else if g.world_num == 2 {
        [125, 110, 165, 160]
    } else if g.world_num == 3 {
        [255, 224, 186, 200]
    } else {
        [110, 72, 82, 145]
    };
    for c in 8 {
        let cx = c * 320.0 - g.cam_x * 0.3 + 60.0;
        let cy = 78.0 + (c % 3) * 34.0;
        if cx > -140.0 && cx < VIEW_W + 40.0 {
            push_quad(verts, cx, cy, 88.0, 26.0, cloud_c);
            push_quad(verts, cx + 16.0, cy - 14.0, 52.0, 16.0, cloud_c);
        }
    }

    let hill_c: u8[4] = if g.world_num == 1 {
        [72, 168, 92, 255]
    } else if g.world_num == 2 {
        [42, 72, 78, 255]
    } else if g.world_num == 3 {
        [114, 96, 62, 255]
    } else {
        [48, 26, 36, 255]
    };
    let hill_hi: u8[4] = if g.world_num == 1 {
        [96, 196, 112, 255]
    } else if g.world_num == 2 {
        [58, 96, 102, 255]
    } else if g.world_num == 3 {
        [142, 120, 76, 255]
    } else {
        [72, 36, 48, 255]
    };
    for h in 9 {
        let hx = h * 260.0 - g.cam_x * 0.5 - 20.0;
        if hx > -220.0 && hx < VIEW_W + 40.0 {
            let hh = 80.0 + (h % 2) * 34.0;
            push_quad(verts, hx, 13.0 * TILE - hh, 160.0, hh, hill_c);
            push_quad(verts, hx + 26.0, 13.0 * TILE - hh - 22.0, 108.0, 26.0, hill_hi);
        }
    }

    // Animated magma floor in World 1-4 (drawn behind tiles so solid floor hides it)
    if g.world_num == 4 {
        let glow = (sin(g.time_s * 4.5) * 18.0) as i64;
        let lava_r = clamp(235 + glow, 200, 255) as u8;
        let lava_g = clamp(72 + glow, 40, 130) as u8;
        push_quad(verts, 0.0, 13.75 * TILE, VIEW_W, 1.25 * TILE, [lava_r, lava_g, 20, 255]);
        push_quad(verts, 0.0, 13.75 * TILE, VIEW_W, 6.0, [255, 205, 65, 255]);
    }

    // End-stage Victory Castle behind Flagpole
    let flag_tx: f32 = if g.world_num == 1 { 98.0 } else { 99.0 };
    let castle_x = (flag_tx + 3.0) * TILE - g.cam_x;
    if castle_x < VIEW_W + 40.0 && castle_x > -200.0 {
        let cy = 9.0 * TILE;
        let cw: f32 = 144.0;
        let ch: f32 = 4.0 * TILE;
        push_quad(verts, castle_x, cy, cw, ch, [132, 138, 156, 255]);
        push_quad(verts, castle_x + 28.0, cy - 32.0, 88.0, 32.0, [148, 154, 174, 255]);
        // Battlements
        for b in 5 {
            push_quad(verts, castle_x + b * 30.0 + 4.0, cy - 12.0, 18.0, 12.0, [168, 174, 194, 255]);
        }
        // Arched fortress gate
        push_quad(verts, castle_x + 52.0, cy + ch - 62.0, 40.0, 62.0, [28, 22, 34, 255]);
        push_quad(verts, castle_x + 58.0, cy + ch - 70.0, 28.0, 10.0, [28, 22, 34, 255]);
    }

    // 3. Visible tilemap
    let tx0 = max(0, (floor(g.cam_x / TILE) as i64) - 1);
    let tx1 = min(MAP_W - 1, (floor((g.cam_x + VIEW_W) / TILE) as i64) + 1);
    for ty in MAP_H {
        var tx = tx0;
        while tx <= tx1 {
            let idx = ty * MAP_W + tx;
            let ch = g.tiles[idx];
            if ch != '.' {
                let sx = tx * TILE - g.cam_x;
                let bump_y = -sin(g.bump[idx] * PI) * 10.0;
                let sy = ty * TILE + bump_y;
                if ch == 'G' {
                    if g.world_num == 4 {
                        push_quad(verts, sx, sy, TILE, TILE, [58, 56, 68, 255]);
                        push_quad(verts, sx, sy, TILE, 10.0, [92, 96, 114, 255]);
                        push_quad(verts, sx, sy, TILE, 4.0, [136, 142, 166, 255]);
                    } else if g.world_num == 3 {
                        push_quad(verts, sx, sy, TILE, TILE, [136, 82, 46, 255]);
                        push_quad(verts, sx, sy, TILE, 10.0, [196, 154, 48, 255]);
                        push_quad(verts, sx, sy, TILE, 4.0, [238, 198, 86, 255]);
                    } else if g.world_num == 2 {
                        push_quad(verts, sx, sy, TILE, TILE, [94, 62, 48, 255]);
                        push_quad(verts, sx, sy, TILE, 10.0, [46, 152, 92, 255]);
                        push_quad(verts, sx, sy, TILE, 4.0, [86, 196, 134, 255]);
                    } else {
                        push_quad(verts, sx, sy, TILE, TILE, [138, 86, 48, 255]);
                        push_quad(verts, sx, sy, TILE, 10.0, [56, 186, 72, 255]);
                        push_quad(verts, sx, sy, TILE, 4.0, [110, 224, 114, 255]);
                    }
                } else if ch == 'D' {
                    if g.world_num == 4 {
                        push_quad(verts, sx, sy, TILE, TILE, [44, 42, 54, 255]);
                        push_quad(verts, sx + 6.0, sy + 8.0, 8.0, 8.0, [32, 30, 40, 255]);
                    } else {
                        push_quad(verts, sx, sy, TILE, TILE, [114, 68, 38, 255]);
                        push_quad(verts, sx + 6.0, sy + 8.0, 8.0, 8.0, [94, 54, 28, 255]);
                    }
                } else if ch == 'B' {
                    push_quad(verts, sx, sy, TILE, TILE, [196, 92, 52, 255]);
                    push_quad(verts, sx, sy + 16.0, TILE, 3.0, [95, 42, 24, 255]);
                    push_quad(verts, sx + 16.0, sy, 3.0, 16.0, [95, 42, 24, 255]);
                    push_quad(verts, sx + 30.0, sy + 19.0, 3.0, 17.0, [95, 42, 24, 255]);
                } else if ch == '?' || ch == 'M' {
                    push_quad(verts, sx, sy, TILE, TILE, [245, 180, 28, 255]);
                    push_quad(verts, sx + 2.0, sy + 2.0, TILE - 4.0, 3.0, [255, 232, 120, 255]);
                    push_quad(verts, sx, sy + TILE - 3.0, TILE, 3.0, [175, 110, 12, 255]);
                    // Question glyph
                    push_quad(verts, sx + 12.0, sy + 8.0, 12.0, 4.0, [110, 56, 10, 255]);
                    push_quad(verts, sx + 20.0, sy + 12.0, 4.0, 6.0, [110, 56, 10, 255]);
                    push_quad(verts, sx + 15.0, sy + 16.0, 6.0, 4.0, [110, 56, 10, 255]);
                    push_quad(verts, sx + 15.0, sy + 24.0, 5.0, 4.0, [110, 56, 10, 255]);
                } else if ch == 'U' {
                    push_quad(verts, sx, sy, TILE, TILE, [120, 86, 62, 255]);
                    push_quad(verts, sx + 3.0, sy + 3.0, TILE - 6.0, TILE - 6.0, [96, 68, 48, 255]);
                } else if ch == '[' || ch == ']' {
                    push_quad(verts, sx, sy, TILE, TILE, [36, 172, 56, 255]);
                    push_quad(verts, sx, sy, TILE, 4.0, [120, 236, 124, 255]);
                    if ch == '[' {
                        push_quad(verts, sx + 8.0, sy + 4.0, 8.0, TILE - 4.0, [96, 224, 104, 255]);
                    }
                    push_quad(verts, sx, sy + TILE - 4.0, TILE, 4.0, [20, 112, 34, 255]);
                } else if ch == '{' || ch == '}' {
                    let inset: f32 = if ch == '{' { 4.0 } else { 0.0 };
                    let pw: f32 = TILE - 4.0;
                    push_quad(verts, sx + inset, sy, pw, TILE, [30, 152, 48, 255]);
                    if ch == '{' {
                        push_quad(verts, sx + 10.0, sy, 8.0, TILE, [86, 212, 94, 255]);
                    }
                } else if ch == 'S' {
                    push_quad(verts, sx, sy, TILE, TILE, [118, 128, 148, 255]);
                    push_quad(verts, sx + 2.0, sy + 2.0, TILE - 4.0, 4.0, [168, 180, 202, 255]);
                } else if ch == 'C' {
                    let bob = sin(g.time_s * 6.0 + tx) * 3.0;
                    push_quad(verts, sx + 9.0, sy + 6.0 + bob, 18.0, 24.0, [255, 212, 44, 255]);
                    push_quad(verts, sx + 14.0, sy + 10.0 + bob, 8.0, 16.0, [255, 246, 168, 255]);
                } else if ch == 'F' {
                    push_quad(verts, sx + 15.0, sy, 6.0, TILE, [225, 232, 242, 255]);
                    if ty == 4 {
                        push_quad(verts, sx + 14.0, sy - 6.0, 8.0, 8.0, [255, 215, 50, 255]);
                        push_quad(verts, sx - 16.0, sy + 4.0, 32.0, 20.0, [36, 200, 96, 255]);
                    }
                }
            }
            tx++;
        }
    }

    // 4. Golden Feather power-up
    if g.feather.active {
        let fx = g.feather.x - g.cam_x;
        let fy = g.feather.y;
        push_quad(verts, fx, fy + 4.0, 24.0, 14.0, [255, 215, 45, 255]);
        push_quad(verts, fx + 4.0, fy, 16.0, 22.0, [255, 242, 130, 255]);
    }

    // 5. Patrolling foes
    for i in MAX_ENEMIES {
        let e = g.enemies[i];
        if !e.alive && e.squish_t <= 0.0 { continue; }
        let ex = e.x - g.cam_x;
        if ex < -50.0 || ex > VIEW_W + 50.0 { continue; }
        if !e.alive {
            push_quad(verts, ex, e.y + e.h - 8.0, e.w, 8.0, [160, 84, 52, 255]);
            continue;
        }
        // Mushroom cap + stalk + angry eyes
        push_quad(verts, ex, e.y, e.w, 16.0, [176, 86, 52, 255]);
        push_quad(verts, ex + 4.0, e.y + 16.0, e.w - 8.0, 12.0, [238, 206, 172, 255]);
        push_quad(verts, ex + 6.0, e.y + 6.0, 5.0, 6.0, [255, 255, 255, 255]);
        push_quad(verts, ex + e.w - 11.0, e.y + 6.0, 5.0, 6.0, [255, 255, 255, 255]);
        push_quad(verts, ex + 7.0, e.y + 8.0, 3.0, 4.0, [20, 20, 28, 255]);
        push_quad(verts, ex + e.w - 10.0, e.y + 8.0, 3.0, 4.0, [20, 20, 28, 255]);
    }

    // 6. Super Goose Hero!
    let blink = g.invuln_t > 0.0 && ((g.time_s * 18.0) as i64) % 2 == 0;
    if !blink {
        let hx = g.px - g.cam_x;
        let hy = g.py;
        let pw = player_w();
        let ph = player_h(g);
        let dir = g.facing;
        let stride = if g.on_ground { sin(g.walk_phase) * 5.0 } else { 4.0 };

        // Animated orange feet
        push_quad(verts, hx + 4.0 + stride, hy + ph - 7.0, 8.0, 7.0, [249, 115, 22, 255]);
        push_quad(verts, hx + 14.0 - stride, hy + ph - 7.0, 8.0, 7.0, [234, 88, 12, 255]);
        // White Goose body & neck
        push_quad(verts, hx + 2.0, hy + ph - 22.0, 22.0, 16.0, [248, 250, 252, 255]);
        push_quad(verts, hx + (if dir >= 0.0 { 10.0 } else { 4.0 }), hy + 6.0, 13.0, ph - 16.0,
                  [248, 250, 252, 255]);
        // Hero neck scarf when powered up
        if g.big {
            push_quad(verts, hx + (if dir >= 0.0 { 9.0 } else { 3.0 }), hy + 17.0, 15.0, 5.0,
                      [239, 68, 68, 255]);
        }
        // Flapping wing
        let wing_y = hy + ph - 20.0 + (if !g.on_ground { -3.0 } else { 0.0 });
        push_quad(verts, hx + (if dir >= 0.0 { 3.0 } else { 11.0 }), wing_y, 12.0, 9.0,
                  [203, 213, 225, 255]);
        // Red Mario-style Cap + brim (+ gold crown emblem when powered up)
        push_quad(verts, hx + (if dir >= 0.0 { 8.0 } else { 2.0 }), hy, 16.0, 8.0, [225, 36, 48, 255]);
        if g.big {
            push_quad(verts, hx + (if dir >= 0.0 { 13.0 } else { 7.0 }), hy + 2.0, 6.0, 4.0, [255, 215, 60, 255]);
        }
        push_quad(verts, hx + (if dir >= 0.0 { 12.0 } else { 0.0 }), hy + 5.0, 14.0, 4.0, [195, 24, 34, 255]);
        // Eye + Bright Orange Beak
        let eye_x = if dir >= 0.0 { hx + 17.0 } else { hx + 6.0 };
        push_quad(verts, eye_x, hy + 10.0, 4.0, 4.0, [20, 24, 36, 255]);
        let beak_x = if dir >= 0.0 { hx + 22.0 } else { hx - 5.0 };
        push_quad(verts, beak_x, hy + 12.0, 9.0, 6.0, [249, 115, 22, 255]);
    }

    // 7. Coin popups & particles
    for i in MAX_POPUPS {
        let pc = g.popups[i];
        if pc.life > 0.0 {
            push_quad(verts, pc.x - g.cam_x, pc.y, 14.0, 18.0, [255, 224, 64, 255]);
        }
    }
    for i in MAX_PARTS {
        let p = g.parts[i];
        if p.life > 0.0 {
            push_quad(verts, p.x - g.cam_x - 3.0, p.y - 3.0, 6.0, 6.0, p.color);
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
    var g = new_platform(42);
    check(g.world_num == 1 && g.lives == 3, "initial game state invalid");

    // Test ground resting & jump physics
    step_platform(g, 0.016, 0.0, false, false, false);
    check(g.on_ground, "hero must rest solidly on ground tile");
    step_platform(g, 0.016, 1.0, true, true, false);
    check(g.sfx_jump && !g.on_ground && g.vy < 0.0, "jump must launch hero upward");

    // Test head-bonking '?' block spawns coin & turns tile to 'U'
    var g2 = new_platform(7);
    let qtx = 11;
    let qty = 9;
    check(tile_at(g2, qtx, qty) == '?', "expected '?' block at (11,9)");
    g2.px = qtx * TILE + 4.0;
    g2.py = (qty + 1) * TILE - 4.0;
    g2.vy = -120.0;
    step_platform(g2, 0.016, 0.0, false, true, false);
    check(tile_at(g2, qtx, qty) == 'U' && g2.coins == 1 && g2.sfx_coin,
          "head-bonking '?' block must award coin and turn into 'U'");

    // Test enemy stomp kill & upward bounce
    var g3 = new_platform(9);
    g3.enemies[0] = Enemy {
        alive: true, squish_t: 0.0, x: 200.0, y: 12.0 * TILE,
        vx: -70.0, vy: 0.0, w: 30.0, h: 28.0,
    };
    g3.px = 202.0;
    g3.py = 12.0 * TILE - player_h(g3) - 2.0;
    g3.vy = 220.0;
    step_platform(g3, 0.016, 0.0, false, false, false);
    check(!g3.enemies[0].alive && g3.sfx_stomp && g3.vy < 0.0 && g3.score >= 200,
          "stomping enemy from above must kill enemy and bounce player");

    // Test standing jump apex height clears 3-tile pipe (> 3.8 * TILE)
    var gj = new_platform(1);
    let start_y = gj.py;
    var min_y = start_y;
    step_platform(gj, 1.0 / 60.0, 0.0, true, true, false);
    for f in 45 {
        step_platform(gj, 1.0 / 60.0, 0.0, false, true, false);
        if gj.py < min_y { min_y = gj.py; }
    }
    check(start_y - min_y >= 3.8 * TILE, "standing jump apex must easily clear 3-tile pipe");

    // Validate all 4 worlds: spawn ground, flagpole, pipe height <= 3 tiles, pit width <= 2 tiles
    for w in 1..5 {
        var gw = new_platform((w * 11) as! u64);
        load_level(gw, w);
        check(gw.world_num == w, "world_num mismatch");
        check(tile_at(gw, 3, 13) == 'G', "spawn ground missing");

        var has_flag = false;
        var pit_run: i64 = 0;
        var max_pit: i64 = 0;
        var min_pipe_top: i64 = 99;
        for tx in 98 {
            if tile_at(gw, tx, 13) == '.' {
                pit_run++;
                if pit_run > max_pit { max_pit = pit_run; }
            } else {
                pit_run = 0;
            }
            for ty in MAP_H {
                let ch = tile_at(gw, tx, ty);
                if ch == '[' && ty < min_pipe_top { min_pipe_top = ty; }
            }
        }
        for tx in 96..102 {
            if tile_at(gw, tx, 6) == 'F' { has_flag = true; }
        }
        check(has_flag, "flagpole missing near end of stage");
        check(min_pipe_top >= 10, "pipe taller than 3 tiles in stage");
        check(max_pit <= 3, "contiguous pit too wide to clear safely");

        var vtmp: Vertex2D[>..] = [];
        render_platform(gw, vtmp);
        check(vtmp.len > 300 && vtmp.len <= MAX_VERTS, "world render batch invalid");
    }

    // Test running jump pipe clearance on Worlds 1-2 (x=38), 1-3 (x=60), and 1-4 (x=48)
    let pipe_worlds: i64[3] = [2, 3, 4];
    let pipe_starts: f32[3] = [36.0, 58.0, 46.0];
    let pipe_goals: f32[3] = [40.2, 62.2, 50.2];
    for k in 3 {
        var gp = new_platform((5 + k) as! u64);
        load_level(gp, pipe_worlds[k]);
        for ei in MAX_ENEMIES { gp.enemies[ei].alive = false; }
        gp.px = pipe_starts[k] * TILE;
        for f in 90 {
            if gp.px > pipe_goals[k] * TILE { break; }
            let want_j = gp.on_ground;
            step_platform(gp, 1.0 / 60.0, 1.0, want_j, true, false);
        }
        check(gp.px > pipe_goals[k] * TILE && !gp.game_over && gp.lives == 3,
              "hero must clear pipe cleanly in all worlds");
    }

    // Test progression 1 -> 2 -> 3 -> 4 -> won_game == true
    var gprog = new_platform(99);
    for w in 1..5 {
        check(gprog.world_num == w && !gprog.won_game, "expected sequential world number");
        let ftx = if w == 1 { 98.0 } else { 99.0 };
        gprog.px = ftx * TILE - 12.0;
        gprog.py = 11.0 * TILE;
        gprog.vx = 120.0;
        step_platform(gprog, 0.05, 1.0, false, false, false);
        check(gprog.won_level, "flagpole must mark stage won");
        for _ in 40 { step_platform(gprog, 0.1, 0.0, false, false, false); }
    }
    check(gprog.won_game, "completing World 1-4 must set won_game = true");

    print("PASS super_goose (4 worlds 1-1..1-4, coyote jump, pipe clearance, ?-block bonk, stomp physics, GPU batching)\n");
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

    guard gfx::open("Super Goose Bros — Platformer", 960, 540, gfx::WINDOW_RESIZABLE) else {
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
    var sfx_p = audio::Sound { id: 0 };
    if use_audio {
        if audio::open() {
            sfx_j = audio::create_sound(build_tone(320.0, 640.0, 0.10));
            sfx_c = audio::create_sound(build_tone(988.0, 1318.0, 0.10));
            sfx_s = audio::create_sound(build_tone(240.0, 120.0, 0.09));
            sfx_p = audio::create_sound(build_tone(440.0, 880.0, 0.18));
        } else {
            use_audio = false;
        }
    }
    defer {
        if use_audio {
            audio::release_sound(sfx_j);
            audio::release_sound(sfx_c);
            audio::release_sound(sfx_s);
            audio::release_sound(sfx_p);
            audio::close();
        }
    }

    var game = new_platform(if demo_mode { 2026 } else { random_seed() });
    if demo_mode {
        game.big = true;
        game.score = 1250;
        game.coins = 7;
    }

    var verts: Vertex2D[>..] = [];
    var drawn: i64 = 0;
    var has_hud = false;

    while gfx::frame() {
        if gfx::key_pressed("Escape") { break; }
        if gfx::key_pressed("P") && !game.game_over && !game.won_level { game.paused = !game.paused; }
        if gfx::key_pressed("R") { game = new_platform(random_seed()); }
        if gfx::key_pressed("1") { load_level(game, 1); game.game_over = false; }
        if gfx::key_pressed("2") { load_level(game, 2); game.game_over = false; }
        if gfx::key_pressed("3") { load_level(game, 3); game.game_over = false; }
        if gfx::key_pressed("4") { load_level(game, 4); game.game_over = false; }

        var move_x: f32 = 0.0;
        if gfx::key_down("Left") || gfx::key_down("A") { move_x -= 1.0; }
        if gfx::key_down("Right") || gfx::key_down("D") { move_x += 1.0; }
        let jump_p = gfx::key_pressed("Space") || gfx::key_pressed("W") || gfx::key_pressed("Up");
        let jump_h = gfx::key_down("Space") || gfx::key_down("W") || gfx::key_down("Up");

        if (game.game_over || game.won_game) && jump_p {
            game = new_platform(random_seed());
        }

        let dt = if demo_mode { 1.0 / 60.0 } else { min(gfx::delta_time(), 0.04) };
        step_platform(game, dt as f32, move_x, jump_p, jump_h, demo_mode);

        if use_audio {
            if game.sfx_jump && sfx_j.id != 0 { audio::play(sfx_j, 0.40); }
            if game.sfx_coin && sfx_c.id != 0 { audio::play(sfx_c, 0.50); }
            if game.sfx_stomp && sfx_s.id != 0 { audio::play(sfx_s, 0.50); }
            if game.sfx_power && sfx_p.id != 0 { audio::play(sfx_p, 0.55); }
        }

        render_platform(game, verts);
        if verts.len > 0 { gfx::update_buffer(vb, bytes_of(verts)); }

        ui::input_from_gfx(ctx);
        let px = gfx::screen_size();
        let sc = ui::scale(ctx);
        let hud_bounds = ui::rect(0.0, 0.0, px.x / sc, px.y / sc);
        if has_hud { ui::window_set_bounds(ctx, "PlatHUD", hud_bounds); }
        if ui::begin(ctx, "PlatHUD", hud_bounds, ui::WINDOW_NO_INPUT | ui::WINDOW_NO_SCROLLBAR) {
            has_hud = true;
            ui::layout_row_dynamic(ctx, 28.0, 5);
            ui::label_colored(ctx, str("GOOSE ", game.score), ui::TEXT_LEFT, ui::rgb(255, 255, 255));
            ui::label_colored(ctx, str("COINS: ", game.coins), ui::TEXT_CENTERED, ui::rgb(255, 224, 70));
            ui::label_colored(ctx, str("WORLD 1-", game.world_num), ui::TEXT_CENTERED, ui::rgb(220, 240, 255));
            ui::label_colored(ctx, str("LIVES: ", game.lives), ui::TEXT_CENTERED, ui::rgb(255, 130, 130));
            ui::label_colored(ctx, str("TIME: ", game.time_left as i64), ui::TEXT_RIGHT, ui::rgb(240, 248, 255));

            if game.game_over || game.paused || game.won_level {
                ui::layout_row_dynamic(ctx, 180.0, 1);
                ui::spacer(ctx);
                ui::layout_row_dynamic(ctx, 36.0, 1);
                let msg: u8[>..] = if game.won_game {
                    str("VICTORY! ALL 4 WORLDS CLEARED! Press SPACE or R to Play Again")
                } else if game.won_level {
                    str("WORLD 1-", game.world_num, " CLEAR! Advancing to World 1-", game.world_num + 1, "...")
                } else if game.game_over {
                    str("GAME OVER - Press SPACE or R to Restart")
                } else {
                    str("PAUSED - Press P to Resume")
                };
                ui::label_colored(ctx, msg, ui::TEXT_CENTERED, ui::rgb(255, 250, 210));
            }
        }
        ui::end(ctx);

        gfx::begin_screen(float4 { 0.25, 0.56, 0.92, 1.0 });
        if verts.len > 0 {
            gfx::bind(pipe);
            gfx::bind_vertex_buffer(vb);
            gfx::uniforms(gfx::VERTEX, 0, OrthoUniform { screen: float4 { VIEW_W, VIEW_H, 0.0, 0.0 } });
            gfx::draw(verts.len);
        }
        gfx::end_pass();
        ui::render(ctx);

        drawn++;
        if frames > 0 && drawn >= frames { break; }
    }

    if screenshot_path.len > 0 {
        let ok = gfx::screenshot(screenshot_path);
        check(ok, "failed to save super_goose screenshot");
    }
}

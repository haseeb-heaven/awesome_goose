// term_snake: 2D Console Arcade Snake powered by Goose & goose-tui.
//
// Features:
//   - Diffed 24-bit truecolor terminal rendering via goose-tui
//   - Smooth directional queueing, glowing neon snake, apples & rare golden stars
//   - Progressive speed levels + HUD panel + score progress bar
//   - Headless deterministic tests (--test) and ANSI frame export (--ansi-dump)

import std;
import os;
import math;
import tui from "github.com/ZHENGSY/goose-tui@v0.1.0";

let GRID_W: i32 = 30;
let GRID_H: i32 = 14;
let MAX_SNAKE: i32 = 512;

let DIR_RIGHT: i32 = 0;
let DIR_DOWN: i32 = 1;
let DIR_LEFT: i32 = 2;
let DIR_UP: i32 = 3;

struct Pos { x: i32, y: i32 }

struct SnakeGame {
    body: Pos[..512],
    dir: i32,
    next_dir: i32,
    apple: Pos,
    bonus: Pos,
    has_bonus: bool,
    bonus_ttl: i32,
    score: i32,
    best: i32,
    level: i32,
    paused: bool,
    game_over: bool,
    last_step_ms: i64,
    prng: rng,
}

fn check(ok: bool, msg: const u8[:]) {
    if !ok { abort(msg); }
}

fn contains_pos(body: const Pos[:], p: Pos) -> bool {
    for b in body {
        if b.x == p.x && b.y == p.y { return true; }
    }
    return false;
}

fn spawn_free(g: SnakeGame&) -> Pos {
    for _ in 256 {
        let p = Pos {
            x: g.prng.rand_range(GRID_W) as i32,
            y: g.prng.rand_range(GRID_H) as i32,
        };
        if !contains_pos(g.body, p) && !(g.has_bonus && g.bonus.x == p.x && g.bonus.y == p.y) {
            return p;
        }
    }
    for y in GRID_H {
        for x in GRID_W {
            let p = Pos { x: x, y: y };
            if !contains_pos(g.body, p) { return p; }
        }
    }
    return Pos { x: 0, y: 0 };
}

fn new_game(seed: u64, best_score: i32) -> SnakeGame {
    var g = SnakeGame {
        body: [],
        dir: DIR_RIGHT,
        next_dir: DIR_RIGHT,
        apple: Pos { x: 20, y: 7 },
        bonus: Pos { x: 0, y: 0 },
        has_bonus: false,
        bonus_ttl: 0,
        score: 0,
        best: best_score,
        level: 1,
        paused: false,
        game_over: false,
        last_step_ms: 0,
        prng: rng { seed },
    };
    g.body.push(Pos { x: 8, y: 7 });
    g.body.push(Pos { x: 7, y: 7 });
    g.body.push(Pos { x: 6, y: 7 });
    g.body.push(Pos { x: 5, y: 7 });
    g.apple = spawn_free(g);
    return g;
}

fn set_dir(g: SnakeGame&, want: i32) {
    // Disallow 180-degree reversal
    if (want + 2) % 4 == g.dir { return; }
    g.next_dir = want;
}

fn step_interval_ms(level: i32) -> i64 {
    let ms = 140 - (level - 1) * 12;
    return max(ms as i64, 55);
}

fn step_game(g: SnakeGame&) {
    if g.paused || g.game_over { return; }
    g.dir = g.next_dir;
    var nx = g.body[0].x;
    var ny = g.body[0].y;
    if g.dir == DIR_RIGHT { nx += 1; }
    else if g.dir == DIR_LEFT { nx -= 1; }
    else if g.dir == DIR_DOWN { ny += 1; }
    else if g.dir == DIR_UP { ny -= 1; }

    if nx < 0 || nx >= GRID_W || ny < 0 || ny >= GRID_H {
        g.game_over = true;
        return;
    }

    let head = Pos { x: nx, y: ny };
    let ate_apple = head.x == g.apple.x && head.y == g.apple.y;
    let ate_bonus = g.has_bonus && head.x == g.bonus.x && head.y == g.bonus.y;

    // Check self-collision (tail cell is safe if not growing)
    let limit = if ate_apple { g.body.len } else { g.body.len - 1 };
    for i in limit {
        if g.body[i].x == head.x && g.body[i].y == head.y {
            g.game_over = true;
            return;
        }
    }

    // Shift body forward
    if ate_apple && g.body.len < MAX_SNAKE {
        g.body.push(g.body[g.body.len - 1]);
    }
    var idx = g.body.len - 1;
    while idx > 0 {
        g.body[idx] = g.body[idx - 1];
        idx--;
    }
    g.body[0] = head;

    if ate_apple {
        g.score += 10;
        if g.score > g.best { g.best = g.score; }
        g.level = 1 + g.score / 50;
        g.apple = spawn_free(g);
        if !g.has_bonus && g.prng.rand_range(4) == 0 {
            g.bonus = spawn_free(g);
            g.has_bonus = true;
            g.bonus_ttl = 35;
        }
    }

    if ate_bonus {
        g.score += 50;
        if g.score > g.best { g.best = g.score; }
        g.level = 1 + g.score / 50;
        g.has_bonus = false;
        g.bonus_ttl = 0;
    } else if g.has_bonus {
        g.bonus_ttl -= 1;
        if g.bonus_ttl <= 0 { g.has_bonus = false; }
    }
}

fn handle_event(g: SnakeGame&, app: tui::App&, ev: tui::Event) {
    if tui::key_is(ev, 'q') || tui::key_is(ev, 'Q') || tui::key_is_any(ev, tui::Key.Esc) {
        tui::quit(app);
        return;
    }
    if tui::key_is(ev, 'p') || tui::key_is(ev, 'P') {
        if !g.game_over { g.paused = !g.paused; }
        return;
    }
    if tui::key_is(ev, 'r') || tui::key_is(ev, 'R') {
        let best = g.best;
        g = new_game(random_seed(), best);
        g.last_step_ms = app.now_ms;
        return;
    }
    if tui::key_is_any(ev, tui::Key.Up) || tui::key_is(ev, 'w') || tui::key_is(ev, 'W') {
        set_dir(g, DIR_UP);
    } else if tui::key_is_any(ev, tui::Key.Down) || tui::key_is(ev, 's') || tui::key_is(ev, 'S') {
        set_dir(g, DIR_DOWN);
    } else if tui::key_is_any(ev, tui::Key.Left) || tui::key_is(ev, 'a') || tui::key_is(ev, 'A') {
        set_dir(g, DIR_LEFT);
    } else if tui::key_is_any(ev, tui::Key.Right) || tui::key_is(ev, 'd') || tui::key_is(ev, 'D') {
        set_dir(g, DIR_RIGHT);
    }
}

fn draw_game(g: const SnakeGame&, cv: tui::Canvas&, theme: tui::Theme) {
    let bg_board = tui::rgb(13, 17, 26);
    let bg_grid = tui::rgb(18, 24, 36);
    let border_st = tui::style(tui::rgb(70, 160, 240), bg_board);
    let hud_bg = tui::rgb(22, 27, 40);

    let full = tui::rect(0, 0, cv.w, cv.h);
    tui::fill_rect(cv, full, ' ', tui::style(theme.fg, tui::rgb(10, 12, 18)));

    // Header HUD bar
    let top_r = tui::rect(0, 0, cv.w, 3);
    let inner_hud = tui::panel(cv, top_r, " HEAVEN TERM SNAKE ", theme);
    let _ = hud_bg;
    let hud_text = str("SCORE ", g.score, "   BEST ", g.best, "   LEN ", g.body.len,
                       "   LVL ", g.level);
    let mut_left = tui::rect(inner_hud.x + 1, inner_hud.y, max(1, inner_hud.w - 24), 1);
    let _ = tui::draw_text(cv, mut_left, mut_left.x, mut_left.y, hud_text,
                           tui::bold(tui::style(tui::rgb(120, 235, 190), theme.panel_bg)));
    let gauge_r = tui::rect(inner_hud.x + inner_hud.w - 22, inner_hud.y, 20, 1);
    let next_lvl_frac = ((g.score % 50) as f64) / 50.0;
    tui::gauge(cv, gauge_r, next_lvl_frac, "NEXT", theme);

    // Centered arena box: 2 chars per cell => GRID_W*2 + 2 by GRID_H + 2
    let box_w = GRID_W * 2 + 2;
    let box_h = GRID_H + 2;
    let mid_r = tui::rect(0, 3, cv.w, max(1, cv.h - 4));
    let arena = tui::center(mid_r, min(box_w, mid_r.w), min(box_h, mid_r.h));

    tui::fill_rect(cv, arena, ' ', tui::style(theme.fg, bg_board));

    // Draw border around arena
    let ax0 = arena.x;
    let ay0 = arena.y;
    let ax1 = arena.x + box_w - 1;
    let ay1 = arena.y + box_h - 1;
    if ax1 < cv.w && ay1 < cv.h {
        tui::put(cv, ax0, ay0, 0x250C, border_st); // ┌
        tui::put(cv, ax1, ay0, 0x2510, border_st); // ┐
        tui::put(cv, ax0, ay1, 0x2514, border_st); // └
        tui::put(cv, ax1, ay1, 0x2518, border_st); // ┘
        var x = ax0 + 1;
        while x < ax1 {
            tui::put(cv, x, ay0, 0x2500, border_st);
            tui::put(cv, x, ay1, 0x2500, border_st);
            x += 1;
        }
        var y = ay0 + 1;
        while y < ay1 {
            tui::put(cv, ax0, y, 0x2502, border_st);
            tui::put(cv, ax1, y, 0x2502, border_st);
            y += 1;
        }
    }

    let ox = ax0 + 1;
    let oy = ay0 + 1;

    // Subtle checkerboard dots
    for gy in GRID_H {
        for gx in GRID_W {
            if (gx + gy) % 2 == 0 {
                tui::put(cv, ox + gx * 2, oy + gy, '.', tui::style(tui::rgb(38, 48, 70), bg_grid));
                tui::put(cv, ox + gx * 2 + 1, oy + gy, ' ', tui::style(tui::rgb(38, 48, 70), bg_grid));
            }
        }
    }

    // Apple
    let app_st = tui::bold(tui::style(tui::rgb(255, 92, 108), bg_board));
    tui::put(cv, ox + g.apple.x * 2, oy + g.apple.y, 0x25CF, app_st); // ●
    tui::put(cv, ox + g.apple.x * 2 + 1, oy + g.apple.y, 0x25CF, app_st);

    // Bonus star
    if g.has_bonus {
        let bon_st = tui::bold(tui::style(tui::rgb(255, 215, 70), bg_board));
        tui::put(cv, ox + g.bonus.x * 2, oy + g.bonus.y, 0x25C6, bon_st); // ◆
        tui::put(cv, ox + g.bonus.x * 2 + 1, oy + g.bonus.y, 0x25C6, bon_st);
    }

    // Snake body (back to head so head draws on top)
    var i = g.body.len;
    while i > 0 {
        i--;
        let p = g.body[i];
        let sx = ox + p.x * 2;
        let sy = oy + p.y;
        if i == 0 {
            let hd_st = tui::bold(tui::style(tui::rgb(80, 255, 190), tui::rgb(18, 70, 56)));
            tui::put(cv, sx, sy, 0x2588, hd_st);
            tui::put(cv, sx + 1, sy, 0x2588, hd_st);
        } else {
            let t = i / max(g.body.len as f64, 1.0);
            let r_c = (40 + round(t * 25.0) as i64) as u8;
            let g_c = (230 - round(t * 100.0) as i64) as u8;
            let b_c = (165 + round(t * 50.0) as i64) as u8;
            let bd_st = tui::style(tui::rgb(r_c, g_c, b_c), bg_board);
            let ch: u32 = if i % 2 == 1 { 0x2593 } else { 0x2592 }; // ▓ / ▒
            tui::put(cv, sx, sy, ch, bd_st);
            tui::put(cv, sx + 1, sy, ch, bd_st);
        }
    }

    // Overlay prompt if paused or game over
    if g.game_over {
        let banner = tui::center(arena, 32, 3);
        tui::fill_rect(cv, banner, ' ', tui::style(tui::rgb(255, 255, 255), tui::rgb(130, 30, 42)));
        let _ = tui::draw_text_center(cv, banner, banner.y + 1,
                                      str("GAME OVER! R:Retry  Q:Quit"),
                                      tui::bold(tui::style(tui::rgb(255, 240, 240),
                                                           tui::rgb(130, 30, 42))));
    } else if g.paused {
        let banner = tui::center(arena, 26, 3);
        tui::fill_rect(cv, banner, ' ', tui::style(tui::rgb(255, 255, 255), tui::rgb(55, 70, 110)));
        let _ = tui::draw_text_center(cv, banner, banner.y + 1, "PAUSED — Press P",
                                      tui::bold(tui::style(tui::rgb(255, 235, 160),
                                                           tui::rgb(55, 70, 110))));
    }

    // Bottom status bar
    let bot_r = tui::rect(0, cv.h - 1, cv.w, 1);
    tui::status(cv, bot_r, "Arrows/WASD: Move  P: Pause  R: Restart  Q: Quit",
                if g.game_over { "GAME OVER" } else if g.paused { "PAUSED" } else { "LIVE" },
                theme);
}

fn setup_demo_game() -> SnakeGame {
    var g = new_game(1337, 180);
    g.body = [];
    // Curving multi-segment snake showcase
    g.body.push(Pos { x: 18, y: 6 });
    g.body.push(Pos { x: 17, y: 6 });
    g.body.push(Pos { x: 16, y: 6 });
    g.body.push(Pos { x: 15, y: 6 });
    g.body.push(Pos { x: 15, y: 7 });
    g.body.push(Pos { x: 15, y: 8 });
    g.body.push(Pos { x: 14, y: 8 });
    g.body.push(Pos { x: 13, y: 8 });
    g.body.push(Pos { x: 12, y: 8 });
    g.body.push(Pos { x: 11, y: 8 });
    g.dir = DIR_RIGHT;
    g.next_dir = DIR_RIGHT;
    g.apple = Pos { x: 22, y: 6 };
    g.bonus = Pos { x: 9, y: 4 };
    g.has_bonus = true;
    g.bonus_ttl = 24;
    g.score = 130;
    g.best = 180;
    g.level = 3;
    return g;
}

fn run_tests() {
    var g = new_game(42, 0);
    let start_x = g.body[0].x;
    var app = tui::app();
    var cv = tui::canvas(78, 22);

    // Test headless movement & rendering via goose-tui
    tui::headless(app, cv, "dd", 20) { c, ev =>
        handle_event(g, app, ev);
        if g.dir != DIR_RIGHT { abort("expected right movement"); }
        step_game(g);
        draw_game(g, c, app.theme);
    };
    check(g.body[0].x > start_x || g.game_over, "snake must move right in headless simulation");
    let txt = tui::screen_text(cv);
    check(find(txt, "HEAVEN TERM SNAKE") >= 0, "rendered TUI screen missing title");
    check(find(txt, "SCORE") >= 0, "rendered TUI screen missing HUD score");

    // Test apple eating increases score & length
    var g2 = new_game(7, 0);
    g2.apple = Pos { x: g2.body[0].x + 1, y: g2.body[0].y };
    let old_len = g2.body.len;
    step_game(g2);
    check(g2.score == 10 && g2.body.len == old_len + 1, "eating apple must add 10 score and 1 length");

    // Test wall collision ends game
    var g3 = new_game(9, 0);
    g3.body[0] = Pos { x: GRID_W - 1, y: 5 };
    g3.dir = DIR_RIGHT;
    g3.next_dir = DIR_RIGHT;
    step_game(g3);
    check(g3.game_over, "hitting right wall must trigger game_over");

    print("PASS term_snake (headless TUI, movement, apple growth, wall collision, ANSI render)\n");
}

fn dump_ansi_frame() {
    let g = setup_demo_game();
    var app = tui::app();
    var cv = tui::canvas(76, 20);
    tui::begin_frame(app, cv);
    draw_game(g, cv, app.theme);
    var front: tui::Cell[>..] = [];
    tui::invalidate(front);
    var shown = tui::cursor_hidden();
    var out: u8[>..] = [];
    let _ = tui::present(out, cv, front, tui::cursor_hidden(), shown);
    write_stdout(out);
    flush_stdout();
}

fn main() {
    let argv = args();
    for i in argv.len {
        if i == 0 { continue; }
        if argv[i] == "--test" {
            run_tests();
            return;
        }
        if argv[i] == "--ansi-dump" {
            dump_ansi_frame();
            return;
        }
    }

    var t = tui::term();
    t.idle_ms = 35;
    if !tui::open(t) {
        write_stderr("term_snake: open requires an interactive terminal (or run with --test / --ansi-dump)\n");
        exit(1);
    }
    var app = tui::app();
    var cv = tui::canvas(t.w, t.h);
    var g = new_game(random_seed(), 0);
    g.last_step_ms = tui::clock_ms();

    tui::run(app, t, cv) { c, ev =>
        handle_event(g, app, ev);
        while app.now_ms - g.last_step_ms >= step_interval_ms(g.level) {
            g.last_step_ms += step_interval_ms(g.level);
            step_game(g);
        }
        draw_game(g, c, app.theme);
    };
    tui::close(t);
}

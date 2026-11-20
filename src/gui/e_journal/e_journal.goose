// e_journal: Quiet, local-first Desktop Journal in Goose (inspired by haseeb-heaven/e-journal).
//
// Features:
//   - Two-pane notebook layout: Search + Tag Pills + Entry List on left, Writing Surface on right
//   - Four authentic themes: Warm, Dark, Slate, Forest (persistent across launches)
//   - Multi-line undo-capable TextEdit body editor with live word/character counts & unsaved indicator
//   - Create, Edit, Save, Duplicate, Confirmed Delete, and atomic JSON persistence + Backup Export/Import
//   - UTC timestamps formatted with clintecker/goose-date
//   - CLI flags: --db <path>, --theme warm|dark|slate|forest, --test, --demo, --frames N, --screenshot <path>

import std;
import os;
import json;
import gfx;
import ui;
import date from "github.com/clintecker/goose-date@v1";

let FONT: const u8[:] = embed_file("../../../assets/Roboto-Regular.ttf");

let THEME_WARM: i64 = 0;
let THEME_DARK: i64 = 1;
let THEME_SLATE: i64 = 2;
let THEME_FOREST: i64 = 3;

let VIEW_JOURNAL: i64 = 0;
let VIEW_SETTINGS: i64 = 1;

struct ThemePalette {
    name: u8[..16],
    is_dark: bool,
    bg: ui::Color,
    sidebar: ui::Color,
    field: ui::Color,
    text: ui::Color,
    weak_text: ui::Color,
    accent: ui::Color,
    accent_text: ui::Color,
    accent_soft: ui::Color,
    hover: ui::Color,
    stroke: ui::Color,
    danger: ui::Color,
    on_danger: ui::Color,
    success: ui::Color,
}

struct JournalEntry {
    id: i64,
    revision: i64,
    created_at: i64,
    updated_at: i64,
    title: u8[..128],
    tags: u8[..128],
    body: u8[..2048],
}

struct JournalStore {
    theme: i64,
    next_id: i64,
    entries: JournalEntry[>..],
}

fn check(ok: bool, msg: const u8[:]) {
    if !ok { abort(msg); }
}

fn to_buf16(s: const u8[:]) -> u8[..16] {
    var b: u8[..16] = [];
    b.append(s[..min(s.len, 16)]);
    return b;
}

fn to_buf128(s: const u8[:]) -> u8[..128] {
    var b: u8[..128] = [];
    b.append(s[..min(s.len, 128)]);
    return b;
}

fn to_buf2048(s: const u8[:]) -> u8[..2048] {
    var b: u8[..2048] = [];
    b.append(s[..min(s.len, 2048)]);
    return b;
}

fn theme_from_name(s: const u8[:]) -> i64 {
    if s == "dark" || s == "Dark" { return THEME_DARK; }
    if s == "slate" || s == "Slate" { return THEME_SLATE; }
    if s == "forest" || s == "Forest" { return THEME_FOREST; }
    return THEME_WARM;
}

fn theme_key(t: i64) -> u8[>..] {
    if t == THEME_DARK { return str("dark"); }
    if t == THEME_SLATE { return str("slate"); }
    if t == THEME_FOREST { return str("forest"); }
    return str("warm");
}

fn get_palette(t: i64) -> ThemePalette {
    if t == THEME_DARK {
        return ThemePalette {
            name: to_buf16("Dark"),
            is_dark: true,
            bg: ui::rgb(21, 20, 25),
            sidebar: ui::rgb(29, 27, 33),
            field: ui::rgb(36, 33, 40),
            text: ui::rgb(234, 226, 212),
            weak_text: ui::rgb(164, 154, 139),
            accent: ui::rgb(212, 162, 76),
            accent_text: ui::rgb(27, 23, 16),
            accent_soft: ui::rgb(69, 58, 37),
            hover: ui::rgb(43, 40, 48),
            stroke: ui::rgb(55, 50, 60),
            danger: ui::rgb(229, 133, 122),
            on_danger: ui::rgb(35, 18, 16),
            success: ui::rgb(143, 191, 135),
        };
    }
    if t == THEME_SLATE {
        return ThemePalette {
            name: to_buf16("Slate"),
            is_dark: true,
            bg: ui::rgb(18, 22, 28),
            sidebar: ui::rgb(24, 30, 38),
            field: ui::rgb(32, 40, 50),
            text: ui::rgb(227, 234, 242),
            weak_text: ui::rgb(147, 161, 179),
            accent: ui::rgb(95, 168, 211),
            accent_text: ui::rgb(13, 20, 27),
            accent_soft: ui::rgb(42, 63, 82),
            hover: ui::rgb(35, 45, 57),
            stroke: ui::rgb(51, 64, 78),
            danger: ui::rgb(224, 122, 122),
            on_danger: ui::rgb(27, 15, 16),
            success: ui::rgb(127, 200, 169),
        };
    }
    if t == THEME_FOREST {
        return ThemePalette {
            name: to_buf16("Forest"),
            is_dark: false,
            bg: ui::rgb(241, 244, 236),
            sidebar: ui::rgb(228, 234, 219),
            field: ui::rgb(249, 251, 245),
            text: ui::rgb(45, 58, 46),
            weak_text: ui::rgb(109, 124, 106),
            accent: ui::rgb(63, 107, 79),
            accent_text: ui::rgb(247, 251, 247),
            accent_soft: ui::rgb(201, 220, 201),
            hover: ui::rgb(221, 230, 213),
            stroke: ui::rgb(200, 211, 192),
            danger: ui::rgb(166, 75, 60),
            on_danger: ui::rgb(255, 247, 242),
            success: ui::rgb(63, 107, 79),
        };
    }
    return ThemePalette {
        name: to_buf16("Warm"),
        is_dark: false,
        bg: ui::rgb(246, 241, 231),
        sidebar: ui::rgb(239, 231, 217),
        field: ui::rgb(252, 249, 243),
        text: ui::rgb(59, 50, 39),
        weak_text: ui::rgb(122, 107, 89),
        accent: ui::rgb(150, 78, 38),
        accent_text: ui::rgb(255, 249, 241),
        accent_soft: ui::rgb(228, 211, 184),
        hover: ui::rgb(234, 224, 206),
        stroke: ui::rgb(217, 203, 182),
        danger: ui::rgb(166, 58, 46),
        on_danger: ui::rgb(255, 247, 242),
        success: ui::rgb(63, 107, 63),
    };
}

fn trim_slice(s: const u8[:]) -> const u8[:] {
    var a: i64 = 0;
    var b: i64 = s.len;
    while a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r' || s[a] == '\n') { a++; }
    while b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r' || s[b - 1] == '\n') {
        b--;
    }
    return s[a..b];
}

fn to_lower_ascii(c: u8) -> u8 {
    if c >= 'A' && c <= 'Z' { return c + 32; }
    return c;
}

fn contains_icase(haystack: const u8[:], needle: const u8[:]) -> bool {
    if needle.len == 0 { return true; }
    if needle.len > haystack.len { return false; }
    let limit = haystack.len - needle.len + 1;
    for i in limit {
        var matched = true;
        for j in needle.len {
            if to_lower_ascii(haystack[i + j]) != to_lower_ascii(needle[j]) {
                matched = false;
                break;
            }
        }
        if matched { return true; }
    }
    return false;
}

fn split_tags(raw: const u8[:]) -> u8[..32][>..] {
    var out: u8[..32][>..] = [];
    var start: i64 = 0;
    var i: i64 = 0;
    while i <= raw.len {
        if i == raw.len || raw[i] == ',' {
            let part = trim_slice(raw[start..i]);
            if part.len > 0 {
                var dup = false;
                for existing in out {
                    if existing == part { dup = true; break; }
                }
                if !dup {
                    var tok: u8[..32] = [];
                    tok.append(part[..min(part.len, 32)]);
                    out.push(tok);
                }
            }
            start = i + 1;
        }
        i++;
    }
    return out;
}

fn normalize_tags_text(raw: const u8[:]) -> u8[..128] {
    let tags = split_tags(raw);
    var out: u8[>..] = [];
    for i in tags.len {
        if i > 0 { out.append(", "); }
        out.append(tags[i]);
    }
    return to_buf128(out);
}

fn entry_has_tag(e: const JournalEntry&, tag: const u8[:]) -> bool {
    if tag.len == 0 { return true; }
    let tags = split_tags(e.tags);
    for t in tags {
        if t == tag { return true; }
    }
    return false;
}

fn collect_all_tags(entries: const JournalEntry[:]) -> u8[..32][>..] {
    var out: u8[..32][>..] = [];
    for e in entries {
        let tags = split_tags(e.tags);
        for t in tags {
            var seen = false;
            for x in out {
                if x == t { seen = true; break; }
            }
            if !seen && out.len < 16 { out.push(t); }
        }
    }
    return out;
}

fn count_words(s: const u8[:]) -> i64 {
    var words: i64 = 0;
    var in_w = false;
    for c in s {
        let ws = c == ' ' || c == '\t' || c == '\n' || c == '\r';
        if ws { in_w = false; }
        else if !in_w { words++; in_w = true; }
    }
    return words;
}

fn format_ts(ts: i64) -> u8[>..] {
    var out: u8[>..] = [];
    date::format_civil(out, ts, ' ', false);
    out.append(" UTC");
    return out;
}

fn default_db_path() -> u8[>..] {
    var home: u8[>..] = [];
    if env("HOME", home) && home.len > 0 {
        return str(home, "/.heaven_e_journal.json");
    }
    return str("e_journal_data.json");
}

fn encode_store_json(store: const JournalStore&) -> u8[>..] {
    var out: u8[>..] = [];
    out.append("{\"version\":1,");
    json::format_key(out, "theme");
    json::format_string(out, theme_key(store.theme));
    out.push(',');
    json::format_key(out, "next_id");
    json::format_int(out, store.next_id);
    out.push(',');
    json::format_key(out, "entries");
    out.push('[');
    for i in store.entries.len {
        if i > 0 { out.push(','); }
        let e = store.entries[i];
        out.push('{');
        json::format_key(out, "id"); json::format_int(out, e.id); out.push(',');
        json::format_key(out, "revision"); json::format_int(out, e.revision); out.push(',');
        json::format_key(out, "created_at"); json::format_int(out, e.created_at); out.push(',');
        json::format_key(out, "updated_at"); json::format_int(out, e.updated_at); out.push(',');
        json::format_key(out, "title"); json::format_string(out, e.title); out.push(',');
        json::format_key(out, "tags"); json::format_string(out, e.tags); out.push(',');
        json::format_key(out, "body"); json::format_string(out, e.body);
        out.push('}');
    }
    out.append("]}\n");
    return out;
}

fn decode_store_json(text: const u8[:], store: JournalStore&) -> bool, u8[>..] {
    store.theme = THEME_WARM;
    store.next_id = 1;
    store.entries = [];
    var r = json::reader(text);
    var scratch: u8[>..] = [];

    json::each_member(r) { key =>
        if key == "theme" {
            store.theme = theme_from_name(json::read_string(r, scratch));
        } else if key == "next_id" {
            store.next_id = json::read_int(r);
        } else if key == "entries" {
            json::each_element(r) {
                var e = JournalEntry {
                    id: 0,
                    revision: 1,
                    created_at: 0,
                    updated_at: 0,
                    title: to_buf128(""),
                    tags: to_buf128(""),
                    body: to_buf2048(""),
                };
                json::each_member(r) { ek =>
                    if ek == "id" { e.id = json::read_int(r); }
                    else if ek == "revision" { e.revision = json::read_int(r); }
                    else if ek == "created_at" { e.created_at = json::read_int(r); }
                    else if ek == "updated_at" { e.updated_at = json::read_int(r); }
                    else if ek == "title" { e.title = to_buf128(json::read_string(r, scratch)); }
                    else if ek == "tags" { e.tags = to_buf128(json::read_string(r, scratch)); }
                    else if ek == "body" { e.body = to_buf2048(json::read_string(r, scratch)); }
                    else { json::skip(r); }
                };
                if e.id >= store.next_id { store.next_id = e.id + 1; }
                store.entries.push(e);
            };
        } else {
            json::skip(r);
        }
    };

    if !json::finish(r) {
        store.theme = THEME_WARM;
        store.next_id = 1;
        store.entries = [];
        return false, json::message(r);
    }
    return true, str("");
}

fn save_store_file(path: const u8[:], store: const JournalStore&) -> bool {
    let bytes = encode_store_json(store);
    return write_file_atomic(path, bytes);
}

fn load_store_file(path: const u8[:], store: JournalStore&) -> bool, u8[>..] {
    var raw: u8[>..] = [];
    if !read_file(path, raw) {
        return false, str("unable to read file");
    }
    return decode_store_json(raw, store);
}

fn seed_demo_store() -> JournalStore {
    var s = JournalStore { theme: THEME_WARM, next_id: 5, entries: [] };
    s.entries.push(JournalEntry {
        id: 4,
        revision: 3,
        created_at: 1795136400,
        updated_at: 1795140000,
        title: to_buf128("Morning Notes on Goose Architecture"),
        tags: to_buf128("systems, goose, reflection"),
        body: to_buf2048(str(
            "Spent the morning exploring Goose's stack-based ownership\n",
            "and value semantics.\n\n",
            "No garbage collector pauses, explicit copies via copy(x),\n",
            "and single-pass C23 codegen make desktop apps responsive.\n\n",
            "Next up:\n",
            "- Keep entries local-first with atomic JSON writes\n",
            "- Maintain all four calm notebook themes\n",
            "  (Warm, Dark, Slate, Forest)\n",
            "- Keep search and tag filtering instantaneous"
        )),
    });
    s.entries.push(JournalEntry {
        id: 3,
        revision: 2,
        created_at: 1795050000,
        updated_at: 1795054200,
        title: to_buf128("Ridge Trail & Cedar Creek"),
        tags: to_buf128("outdoors, photography"),
        body: to_buf2048("Crisp morning air at 1,800m elevation.\nLight mist across the valley before sunrise."),
    });
    s.entries.push(JournalEntry {
        id: 2,
        revision: 1,
        created_at: 1794963600,
        updated_at: 1794963600,
        title: to_buf128("Reading List - Fall 2026"),
        tags: to_buf128("books, notes"),
        body: to_buf2048("1. Designing Data-Intensive Applications\n2. Crafting Interpreters\n3. The Art of Doing Science and Engineering"),
    });
    s.entries.push(JournalEntry {
        id: 1,
        revision: 1,
        created_at: 1794877200,
        updated_at: 1794877200,
        title: to_buf128("Welcome to E-Journal (Goose Edition)"),
        tags: to_buf128("journal, local-first"),
        body: to_buf2048("A quiet desktop notebook built in Goose with Nuklear, SDL3 GPU, and local JSON snapshots."),
    });
    return s;
}

fn find_entry_index(entries: const JournalEntry[:], id: i64) -> i64 {
    for i in entries.len {
        if entries[i].id == id { return i; }
    }
    return -1;
}

fn truncate_ellipsis(s: const u8[:], max_len: i64) -> u8[>..] {
    if s.len <= max_len { return str(s); }
    var out: u8[>..] = [];
    for i in max_len - 3 {
        out.push(s[i]);
    }
    out.append("...");
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

fn apply_ui_theme(ctx: ui::Context, p: ThemePalette) {
    var tbl = ui::default_color_table();
    tbl[ui::COLOR_TEXT] = p.text;
    tbl[ui::COLOR_WINDOW] = p.bg;
    tbl[ui::COLOR_HEADER] = p.sidebar;
    tbl[ui::COLOR_BORDER] = p.stroke;
    tbl[ui::COLOR_BUTTON] = p.sidebar;
    tbl[ui::COLOR_BUTTON_HOVER] = p.hover;
    tbl[ui::COLOR_BUTTON_ACTIVE] = p.accent_soft;
    tbl[ui::COLOR_EDIT] = p.field;
    tbl[ui::COLOR_EDIT_CURSOR] = p.accent;
    tbl[ui::COLOR_SCROLLBAR] = p.sidebar;
    tbl[ui::COLOR_SCROLLBAR_CURSOR] = p.stroke;
    tbl[ui::COLOR_SCROLLBAR_CURSOR_HOVER] = p.weak_text;
    tbl[ui::COLOR_SCROLLBAR_CURSOR_ACTIVE] = p.accent;
    ui::style_from_table(ctx, tbl);

    var st = ui::style(ctx);
    st.window.fixed_background = ui::style_item_color(p.bg);
    st.window.background = p.bg;
    st.window.border_color = p.stroke;
    st.window.group_border_color = p.stroke;
    st.window.group_border = 1.0;
    st.window.padding = float2 { 12.0, 10.0 };
    st.window.group_padding = float2 { 12.0, 10.0 };
    st.window.spacing = float2 { 8.0, 8.0 };
    st.edit.rounding = 6.0;
    st.edit.border = 1.0;
    st.edit.border_color = p.stroke;
    st.edit.normal = ui::style_item_color(p.field);
    st.edit.hover = ui::style_item_color(p.field);
    st.edit.active = ui::style_item_color(p.field);
    st.edit.text_normal = p.text;
    st.edit.text_hover = p.text;
    st.edit.text_active = p.text;
    st.edit.cursor_normal = p.accent;
    st.edit.cursor_hover = p.accent;
    st.edit.cursor_text_normal = p.accent_text;
    st.edit.cursor_text_hover = p.accent_text;
    ui::set_style(ctx, st);
}

fn run_tests() {
    var st = seed_demo_store();
    check(st.entries.len == 4, "demo store must have 4 entries");

    // Tag normalization & deduping
    let norm = normalize_tags_text("  goose , systems, goose,  notes ");
    check(norm == "goose, systems, notes", "tag normalization failed");

    // Case-insensitive search + tag filter
    check(contains_icase(st.entries[0].title, "architecture"), "icase search failed");
    check(entry_has_tag(st.entries[0], "systems"), "tag filter failed");
    check(!entry_has_tag(st.entries[0], "books"), "tag filter false positive");

    // Date formatting
    let ts_str = format_ts(1795140000);
    check(find(ts_str, "2026-11-") >= 0 && find(ts_str, "UTC") >= 0, "timestamp format invalid");

    // JSON encode -> decode roundtrip & atomic file persistence
    let tmp_path = "/tmp/heaven_e_journal_test.json";
    let saved = save_store_file(tmp_path, st);
    check(saved, "atomic save failed");
    var loaded = JournalStore { theme: THEME_WARM, next_id: 1, entries: [] };
    let ok, err = load_store_file(tmp_path, loaded);
    let _ = delete_file(tmp_path);
    check(ok && err.len == 0, "load after atomic save failed");
    check(loaded.entries.len == 4 && loaded.entries[0].title == st.entries[0].title,
          "decoded entry title mismatch");
    check(find(loaded.entries[0].body, "Next up:") >= 0, "multi-line body roundtrip failed");

    // Reject corrupt JSON safely
    var bad_s = JournalStore { theme: THEME_WARM, next_id: 1, entries: [] };
    let bad_ok, bad_err = decode_store_json("{\"entries\":[", bad_s);
    let _ = bad_s;
    check(!bad_ok && bad_err.len > 0, "invalid JSON must fail cleanly");

    print("PASS e_journal (CRUD model, tag normalization, search, UTC dates, atomic JSON backup)\n");
}

fn main() {
    let argv = args();
    var frames: i64 = -1;
    var demo_mode = false;
    var screenshot_path = str("");
    var db_path = default_db_path();
    var override_theme: i64 = -1;

    var i: i64 = 1;
    while i < argv.len {
        let a = argv[i];
        if a == "--test" {
            run_tests();
            return;
        } else if a == "--demo" {
            demo_mode = true;
        } else if a == "--db" && i + 1 < argv.len {
            db_path = str(argv[i + 1]);
            i++;
        } else if a == "--theme" && i + 1 < argv.len {
            override_theme = theme_from_name(argv[i + 1]);
            i++;
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

    var store = JournalStore { theme: THEME_WARM, next_id: 1, entries: [] };
    if demo_mode {
        store = seed_demo_store();
    } else if file_exists(db_path) {
        let ok, err = load_store_file(db_path, store);
        if !ok {
            let _ = err;
            store = seed_demo_store();
        }
    } else {
        store = seed_demo_store();
    }
    if override_theme >= 0 { store.theme = override_theme; }

    guard gfx::open("E-Journal — Goose Edition", 1020, 660, gfx::WINDOW_RESIZABLE) else {
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
    let base_w: f32 = 1020.0;
    var dpi_scale: f32 = init_pixels.x / base_w;
    if dpi_scale < 0.5 { dpi_scale = 1.0; }
    if dpi_scale > 4.0 { dpi_scale = 4.0; }
    if dpi_scale != ui::scale(ctx) { ui::set_scale(ctx, dpi_scale); }

    let body_edit = ui::create_text_edit();
    ui::set_mode(body_edit, ui::TEXT_EDIT_MODE_INSERT);
    defer ui::destroy(body_edit);

    var active_view = VIEW_JOURNAL;
    var selected_id: i64 = if store.entries.len > 0 { store.entries[0].id } else { -1 };
    var draft_title: u8[..128] = to_buf128("");
    var draft_tags: u8[..128] = to_buf128("");
    var search_query: u8[..64] = [];
    var filter_tag: u8[..32] = [];
    var confirm_delete = false;
    var notice_text = str("Local journal ready.");
    var notice_is_err = false;
    var active_theme = -1;

    if selected_id >= 0 {
        let idx = find_entry_index(store.entries, selected_id);
        if idx >= 0 {
            draft_title = store.entries[idx].title;
            draft_tags = store.entries[idx].tags;
            ui::set_text(body_edit, store.entries[idx].body);
        }
    }

    var has_window = false;
    var drawn: i64 = 0;

    while gfx::frame() {
        if gfx::key_pressed("Escape") { break; }
        ui::input_from_gfx(ctx);

        if active_theme != store.theme {
            active_theme = store.theme;
            apply_ui_theme(ctx, get_palette(store.theme));
        }

        let pal = get_palette(store.theme);
        let base_style = ui::style(ctx);
        let btn_primary = make_btn_style(base_style.button, pal.accent, pal.accent,
                                         pal.accent, pal.accent, pal.accent_text);
        let btn_soft = make_btn_style(base_style.button, pal.accent_soft, pal.hover,
                                      pal.accent_soft, pal.stroke, pal.text);
        let btn_ghost = make_btn_style(base_style.button, pal.sidebar, pal.hover,
                                       pal.accent_soft, pal.stroke, pal.text);
        let btn_danger = make_btn_style(base_style.button, pal.danger, pal.danger,
                                        pal.danger, pal.danger, pal.on_danger);
        let btn_selected = make_btn_style(base_style.button, pal.accent_soft, pal.accent_soft,
                                          pal.accent_soft, pal.accent, pal.text);

        let pixels = gfx::screen_size();
        let sc = ui::scale(ctx);
        let win_w = pixels.x / sc;
        let win_h = pixels.y / sc;
        let bounds = ui::rect(0.0, 0.0, win_w, win_h);
        if has_window { ui::window_set_bounds(ctx, "EJournalRoot", bounds); }

        if ui::begin(ctx, "EJournalRoot", bounds, ui::WINDOW_NO_SCROLLBAR) {
            has_window = true;
            let content = ui::window_get_content_region_size(ctx);

            // Top Bar
            let top_ratios: f32[9] = [0.18, 0.095, 0.095, 0.075, 0.085, 0.085, 0.085, 0.095, 0.205];
            ui::layout_row(ctx, ui::DYNAMIC, 34.0, top_ratios);
            ui::label_colored(ctx, str("E-Journal  (", store.entries.len, ")"),
                              ui::TEXT_LEFT, pal.text);
            if ui::button_label_styled(ctx, if active_view == VIEW_JOURNAL { btn_soft } else { btn_ghost }, "Journal") {
                active_view = VIEW_JOURNAL;
            }
            if ui::button_label_styled(ctx, if active_view == VIEW_SETTINGS { btn_soft } else { btn_ghost }, "Settings") {
                active_view = VIEW_SETTINGS;
            }
            ui::label_colored(ctx, "Theme:", ui::TEXT_RIGHT, pal.weak_text);
            if ui::button_label_styled(ctx, if store.theme == THEME_WARM { btn_soft } else { btn_ghost }, "Warm") {
                store.theme = THEME_WARM;
            }
            if ui::button_label_styled(ctx, if store.theme == THEME_DARK { btn_soft } else { btn_ghost }, "Dark") {
                store.theme = THEME_DARK;
            }
            if ui::button_label_styled(ctx, if store.theme == THEME_SLATE { btn_soft } else { btn_ghost }, "Slate") {
                store.theme = THEME_SLATE;
            }
            if ui::button_label_styled(ctx, if store.theme == THEME_FOREST { btn_soft } else { btn_ghost }, "Forest") {
                store.theme = THEME_FOREST;
            }
            if ui::button_label_styled(ctx, btn_primary, "+ New Entry") {
                active_view = VIEW_JOURNAL;
                selected_id = -1;
                draft_title = to_buf128("");
                draft_tags = to_buf128("");
                ui::set_text(body_edit, "");
                confirm_delete = false;
                notice_text = str("New entry draft ready.");
                notice_is_err = false;
            }

            if active_view == VIEW_JOURNAL {
                var pane_h = content.y - 94.0;
                if pane_h < 260.0 { pane_h = 260.0; }
                let split_ratios: f32[2] = [0.35, 0.65];
                ui::layout_row(ctx, ui::DYNAMIC, pane_h, split_ratios);

                // Left Sidebar
                if ui::group_begin(ctx, "Sidebar", ui::WINDOW_BORDER) {
                    ui::layout_row_dynamic(ctx, 22.0, 1);
                    ui::label_colored(ctx, "Search & Filter", ui::TEXT_LEFT, pal.weak_text);

                    ui::layout_row_dynamic(ctx, 30.0, 1);
                    let _ = ui::edit_string(ctx, ui::EDIT_FIELD, search_query, ui::FILTER_DEFAULT);

                    let all_tags = collect_all_tags(store.entries);
                    let pill_cols = min(all_tags.len + 1, 3);
                    ui::layout_row_dynamic(ctx, 26.0, pill_cols);
                    if ui::button_label_styled(ctx, if filter_tag.len == 0 { btn_soft } else { btn_ghost }, "All") {
                        filter_tag.resize(0);
                    }
                    for ti in min(all_tags.len, 5) {
                        let tname = all_tags[ti];
                        let active_t = filter_tag == tname;
                        if ui::button_label_styled(ctx, if active_t { btn_soft } else { btn_ghost }, truncate_ellipsis(tname, 11)) {
                            filter_tag = tname;
                        }
                    }

                    ui::layout_row_dynamic(ctx, 18.0, 1);
                    ui::label_colored(ctx, "Entries", ui::TEXT_LEFT, pal.weak_text);

                    var shown_count: i64 = 0;
                    for ei in store.entries.len {
                        let e = store.entries[ei];
                        let matches_search = contains_icase(e.title, search_query) ||
                                             contains_icase(e.body, search_query) ||
                                             contains_icase(e.tags, search_query);
                        if !matches_search || !entry_has_tag(e, filter_tag) { continue; }
                        shown_count++;
                        let is_sel = e.id == selected_id;
                        ui::layout_row_dynamic(ctx, 42.0, 1);
                        let card_lbl = truncate_ellipsis(e.title, 34);
                        if ui::button_label_styled(ctx, if is_sel { btn_selected } else { btn_ghost }, card_lbl) {
                            selected_id = e.id;
                            draft_title = e.title;
                            draft_tags = e.tags;
                            ui::set_text(body_edit, e.body);
                            confirm_delete = false;
                            notice_text = str("Opened entry #", e.id);
                            notice_is_err = false;
                        }
                    }
                    if shown_count == 0 {
                        ui::layout_row_dynamic(ctx, 28.0, 1);
                        ui::label_colored(ctx, "No matching entries.", ui::TEXT_CENTERED, pal.weak_text);
                    }
                    ui::group_end(ctx);
                }

                // Right Writing Surface
                if ui::group_begin(ctx, "EditorPane", ui::WINDOW_BORDER) {
                    let cur_body = ui::text(body_edit);
                    let cur_idx = find_entry_index(store.entries, selected_id);
                    var dirty = false;
                    if cur_idx < 0 {
                        dirty = trim_slice(draft_title).len > 0 || trim_slice(cur_body).len > 0 ||
                                trim_slice(draft_tags).len > 0;
                    } else {
                        let orig = store.entries[cur_idx];
                        dirty = trim_slice(draft_title) != trim_slice(orig.title) ||
                                cur_body != orig.body ||
                                normalize_tags_text(draft_tags) != orig.tags;
                    }

                    // Title + Tags fields
                    let field_lbl_ratio: f32[2] = [0.12, 0.88];
                    ui::layout_row(ctx, ui::DYNAMIC, 32.0, field_lbl_ratio);
                    ui::label_colored(ctx, "Title", ui::TEXT_LEFT, pal.weak_text);
                    let _ = ui::edit_string(ctx, ui::EDIT_FIELD, draft_title, ui::FILTER_DEFAULT);

                    ui::layout_row(ctx, ui::DYNAMIC, 30.0, field_lbl_ratio);
                    ui::label_colored(ctx, "Tags", ui::TEXT_LEFT, pal.weak_text);
                    let _ = ui::edit_string(ctx, ui::EDIT_FIELD, draft_tags, ui::FILTER_DEFAULT);

                    // Metadata line
                    ui::layout_row_dynamic(ctx, 22.0, 2);
                    let meta_left = if cur_idx >= 0 {
                        str("Updated: ", format_ts(store.entries[cur_idx].updated_at),
                            "  (rev ", store.entries[cur_idx].revision, ")")
                    } else {
                        str("Draft (unsaved new entry)")
                    };
                    let meta_right = str(count_words(cur_body), " words · ", cur_body.len, " chars",
                                         if dirty { " · * Unsaved" } else { " · Saved" });
                    ui::label_colored(ctx, meta_left, ui::TEXT_LEFT, pal.weak_text);
                    ui::label_colored(ctx, meta_right, ui::TEXT_RIGHT,
                                      if dirty { pal.accent } else { pal.success });

                    // Body editor
                    var body_h = pane_h - 172.0;
                    if body_h < 140.0 { body_h = 140.0; }
                    ui::layout_row_dynamic(ctx, body_h, 1);
                    let _ = ui::edit_buffer(ctx, ui::EDIT_EDITOR, body_edit, ui::FILTER_DEFAULT);

                    // Action buttons
                    ui::layout_row_dynamic(ctx, 34.0, 4);
                    if ui::button_label_styled(ctx, btn_primary, "Save") {
                        let clean_title = trim_slice(draft_title);
                        if clean_title.len == 0 {
                            notice_text = str("Add a title before saving this entry.");
                            notice_is_err = true;
                        } else {
                            let now_s = time_ns() / 1000000000;
                            let norm_tags = normalize_tags_text(draft_tags);
                            draft_tags = norm_tags;
                            let b_text = ui::text(body_edit);
                            if cur_idx >= 0 {
                                store.entries[cur_idx].title = to_buf128(clean_title);
                                store.entries[cur_idx].tags = norm_tags;
                                store.entries[cur_idx].body = to_buf2048(b_text);
                                store.entries[cur_idx].updated_at = now_s;
                                store.entries[cur_idx].revision++;
                            } else {
                                let new_e = JournalEntry {
                                    id: store.next_id,
                                    revision: 1,
                                    created_at: now_s,
                                    updated_at: now_s,
                                    title: to_buf128(clean_title),
                                    tags: norm_tags,
                                    body: to_buf2048(b_text),
                                };
                                selected_id = new_e.id;
                                store.next_id++;
                                // Prepend newest first by pushing and rotating
                                store.entries.push(new_e);
                                var k = store.entries.len - 1;
                                while k > 0 {
                                    let tmp = store.entries[k];
                                    store.entries[k] = store.entries[k - 1];
                                    store.entries[k - 1] = tmp;
                                    k--;
                                }
                            }
                            if !demo_mode {
                                if save_store_file(db_path, store) {
                                    notice_text = str("Saved to local journal.");
                                    notice_is_err = false;
                                } else {
                                    notice_text = str("Error: failed writing ", db_path);
                                    notice_is_err = true;
                                }
                            } else {
                                notice_text = str("Saved (demo mode).");
                                notice_is_err = false;
                            }
                            confirm_delete = false;
                        }
                    }

                    if ui::button_label_styled(ctx, btn_ghost, "Duplicate") {
                        if cur_idx >= 0 {
                            let src_e = store.entries[cur_idx];
                            let now_s = time_ns() / 1000000000;
                            let dup_e = JournalEntry {
                                id: store.next_id,
                                revision: 1,
                                created_at: now_s,
                                updated_at: now_s,
                                title: to_buf128(str(src_e.title, " (Copy)")),
                                tags: src_e.tags,
                                body: src_e.body,
                            };
                            store.next_id++;
                            selected_id = dup_e.id;
                            store.entries.push(dup_e);
                            draft_title = dup_e.title;
                            draft_tags = dup_e.tags;
                            ui::set_text(body_edit, dup_e.body);
                            if !demo_mode { let _ = save_store_file(db_path, store); }
                            notice_text = str("Duplicated entry #", dup_e.id);
                            notice_is_err = false;
                        }
                    }

                    if !confirm_delete {
                        if ui::button_label_styled(ctx, btn_danger, "Delete") {
                            if cur_idx >= 0 { confirm_delete = true; }
                        }
                        ui::spacer(ctx);
                    } else {
                        if ui::button_label_styled(ctx, btn_danger, "Confirm Delete") {
                            if cur_idx >= 0 {
                                remove_at(store.entries, cur_idx);
                                if store.entries.len > 0 {
                                    selected_id = store.entries[0].id;
                                    draft_title = store.entries[0].title;
                                    draft_tags = store.entries[0].tags;
                                    ui::set_text(body_edit, store.entries[0].body);
                                } else {
                                    selected_id = -1;
                                    draft_title = to_buf128("");
                                    draft_tags = to_buf128("");
                                    ui::set_text(body_edit, "");
                                }
                                if !demo_mode { let _ = save_store_file(db_path, store); }
                                notice_text = str("Entry deleted.");
                                notice_is_err = false;
                            }
                            confirm_delete = false;
                        }
                        if ui::button_label_styled(ctx, btn_ghost, "Cancel") {
                            confirm_delete = false;
                        }
                    }
                    ui::group_end(ctx);
                }
            } else {
                // Settings View
                var set_h = content.y - 94.0;
                if set_h < 260.0 { set_h = 260.0; }
                ui::layout_row_dynamic(ctx, set_h, 1);
                if ui::group_begin(ctx, "SettingsPane", ui::WINDOW_BORDER) {
                    ui::layout_row_dynamic(ctx, 28.0, 1);
                    ui::label_colored(ctx, "E-Journal Settings & Local Storage", ui::TEXT_LEFT, pal.text);

                    ui::layout_row_dynamic(ctx, 24.0, 1);
                    ui::label_colored(ctx, str("Active Theme: ", get_palette(store.theme).name,
                                               "  |  Database file: ", db_path),
                                      ui::TEXT_LEFT, pal.weak_text);

                    ui::layout_row_dynamic(ctx, 36.0, 4);
                    if ui::button_label_styled(ctx, if store.theme == THEME_WARM { btn_soft } else { btn_ghost }, "Theme: Warm") {
                        store.theme = THEME_WARM;
                    }
                    if ui::button_label_styled(ctx, if store.theme == THEME_DARK { btn_soft } else { btn_ghost }, "Theme: Dark") {
                        store.theme = THEME_DARK;
                    }
                    if ui::button_label_styled(ctx, if store.theme == THEME_SLATE { btn_soft } else { btn_ghost }, "Theme: Slate") {
                        store.theme = THEME_SLATE;
                    }
                    if ui::button_label_styled(ctx, if store.theme == THEME_FOREST { btn_soft } else { btn_ghost }, "Theme: Forest") {
                        store.theme = THEME_FOREST;
                    }

                    ui::layout_row_dynamic(ctx, 36.0, 2);
                    if ui::button_label_styled(ctx, btn_primary, "Export JSON Backup (e_journal_backup.json)") {
                        if save_store_file("e_journal_backup.json", store) {
                            notice_text = str("Exported backup to e_journal_backup.json");
                            notice_is_err = false;
                        } else {
                            notice_text = str("Failed to export backup.");
                            notice_is_err = true;
                        }
                    }
                    if ui::button_label_styled(ctx, btn_ghost, "Import JSON Backup (e_journal_backup.json)") {
                        var imp = JournalStore { theme: THEME_WARM, next_id: 1, entries: [] };
                        let ok, err = load_store_file("e_journal_backup.json", imp);
                        if ok {
                            store = copy(imp);
                            if store.entries.len > 0 {
                                selected_id = store.entries[0].id;
                                draft_title = store.entries[0].title;
                                draft_tags = store.entries[0].tags;
                                ui::set_text(body_edit, store.entries[0].body);
                            }
                            notice_text = str("Imported ", store.entries.len, " entries from backup.");
                            notice_is_err = false;
                        } else {
                            notice_text = str("Import failed: ", err);
                            notice_is_err = true;
                        }
                    }

                    ui::layout_row_dynamic(ctx, 26.0, 1);
                    ui::label_colored(ctx, "About: E-Journal Goose Edition — inspired by haseeb-heaven/e-journal (MIT)",
                                      ui::TEXT_LEFT, pal.weak_text);
                    ui::group_end(ctx);
                }
            }

            // Bottom Notice Bar
            ui::layout_row_dynamic(ctx, 24.0, 1);
            ui::label_colored(ctx, notice_text, ui::TEXT_LEFT,
                              if notice_is_err { pal.danger } else { pal.weak_text });
        }
        ui::end(ctx);

        let bg_r = pal.bg.r / 255.0;
        let bg_g = pal.bg.g / 255.0;
        let bg_b = pal.bg.b / 255.0;
        gfx::begin_screen(float4 { bg_r as f32, bg_g as f32, bg_b as f32, 1.0 });
        gfx::end_pass();
        ui::render(ctx);

        drawn++;
        if frames > 0 && drawn >= frames { break; }
    }

    if screenshot_path.len > 0 {
        let ok = gfx::screenshot(screenshot_path);
        check(ok, "failed to save e_journal screenshot");
    }
}

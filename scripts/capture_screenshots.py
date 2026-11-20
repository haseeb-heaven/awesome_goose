#!/usr/bin/env python3
"""Capture screenshots for all 7 heaven_goose apps into screenshots/."""

import os
import re
import subprocess
import sys
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
BUILDS = ROOT / "builds"
SHOTS = ROOT / "screenshots"
SHOTS.mkdir(parents=True, exist_ok=True)

ANSI_RE = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])")

ANSI_16 = {
    30: (30, 34, 45),
    31: (244, 94, 94),
    32: (80, 220, 140),
    33: (245, 200, 90),
    34: (96, 165, 250),
    35: (192, 132, 252),
    36: (56, 210, 235),
    37: (224, 232, 244),
    90: (120, 130, 150),
    91: (255, 120, 120),
    92: (120, 240, 170),
    93: (255, 225, 130),
    94: (130, 190, 255),
    95: (220, 165, 255),
    96: (100, 235, 255),
    97: (248, 250, 252),
}


def find_mono_font(size: int) -> ImageFont.FreeTypeFont:
    candidates = [
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Monaco.ttf",
        "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
        "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def render_ansi_terminal(
    raw_text: str,
    title: str,
    out_path: Path,
    cols: int,
    rows: int,
    default_bg=(14, 17, 25),
    default_fg=(220, 228, 240),
) -> None:
    grid = [[(" ", default_fg, default_bg, False) for _ in range(cols)] for _ in range(rows)]
    cur_r, cur_c = 0, 0
    fg, bg, bold = default_fg, default_bg, False

    pos = 0
    n = len(raw_text)
    while pos < n:
        if raw_text[pos] == "\x1b" and pos + 1 < n and raw_text[pos + 1] == "[":
            m = ANSI_RE.match(raw_text, pos)
            if m:
                params_str, cmd = m.group(1), m.group(2)
                pos = m.end()
                if params_str.startswith("?"):
                    continue
                parts = [int(p) if p else 0 for p in params_str.split(";")] if params_str else [0]
                if cmd in ("H", "f"):
                    r = (parts[0] if len(parts) >= 1 and parts[0] > 0 else 1) - 1
                    c = (parts[1] if len(parts) >= 2 and parts[1] > 0 else 1) - 1
                    cur_r = max(0, min(rows - 1, r))
                    cur_c = max(0, min(cols - 1, c))
                elif cmd == "J" and parts[0] == 2:
                    grid = [[(" ", fg, bg, False) for _ in range(cols)] for _ in range(rows)]
                elif cmd == "K":
                    for c in range(cur_c, cols):
                        grid[cur_r][c] = (" ", fg, bg, False)
                elif cmd == "m":
                    i = 0
                    while i < len(parts):
                        code = parts[i]
                        if code == 0:
                            fg, bg, bold = default_fg, default_bg, False
                        elif code == 1:
                            bold = True
                        elif code == 22:
                            bold = False
                        elif code == 7:
                            fg, bg = bg, fg
                        elif code == 39:
                            fg = default_fg
                        elif code == 49:
                            bg = default_bg
                        elif code in ANSI_16:
                            fg = ANSI_16[code]
                        elif 40 <= code <= 47:
                            bg = ANSI_16[code - 10]
                        elif 100 <= code <= 107:
                            bg = ANSI_16[code - 10]
                        elif code == 38 and i + 4 < len(parts) and parts[i + 1] == 2:
                            fg = (parts[i + 2], parts[i + 3], parts[i + 4])
                            i += 4
                        elif code == 48 and i + 4 < len(parts) and parts[i + 1] == 2:
                            bg = (parts[i + 2], parts[i + 3], parts[i + 4])
                            i += 4
                        i += 1
                continue
        ch = raw_text[pos]
        pos += 1
        if ch == "\r":
            cur_c = 0
            continue
        if ch == "\n":
            cur_r += 1
            cur_c = 0
            if cur_r >= rows:
                cur_r = rows - 1
            continue
        if ord(ch) < 32:
            continue
        if 0 <= cur_r < rows and 0 <= cur_c < cols:
            grid[cur_r][cur_c] = (ch, fg, bg, bold)
            cur_c += 1

    font = find_mono_font(16)
    cell_w, cell_h = 10, 22
    pad_x, pad_y = 18, 16
    title_h = 36

    img_w = pad_x * 2 + cols * cell_w
    img_h = title_h + pad_y * 2 + rows * cell_h
    img = Image.new("RGB", (img_w, img_h), default_bg)
    draw = ImageDraw.Draw(img)

    # macOS-style terminal title bar
    draw.rectangle([0, 0, img_w, title_h], fill=(24, 28, 38))
    draw.line([0, title_h, img_w, title_h], fill=(42, 50, 68), width=1)
    dots = [(20, (255, 95, 86)), (40, (255, 189, 46)), (60, (39, 201, 63))]
    for dx, col in dots:
        draw.ellipse([dx - 6, title_h // 2 - 6, dx + 6, title_h // 2 + 6], fill=col)
    title_font = find_mono_font(14)
    draw.text((84, 9), title, font=title_font, fill=(180, 192, 212))

    # Draw cell backgrounds then glyphs
    for r in range(rows):
        y0 = title_h + pad_y + r * cell_h
        for c in range(cols):
            ch, cell_fg, cell_bg, is_bold = grid[r][c]
            x0 = pad_x + c * cell_w
            if cell_bg != default_bg:
                draw.rectangle([x0, y0, x0 + cell_w, y0 + cell_h], fill=cell_bg)
            if ch != " ":
                draw.text((x0, y0 + 2), ch, font=font, fill=cell_fg)
                if is_bold:
                    draw.text((x0 + 1, y0 + 2), ch, font=font, fill=cell_fg)

    img.save(out_path)
    print(f"Saved {out_path} ({img_w}x{img_h})")


def main() -> int:
    env = dict(os.environ)
    env["GOOSE_GFX_HEADLESS"] = "1"

    gpu_demos = [
        ("calculator", 5),
        ("pomodoro", 5),
        ("neon_breakout", 28),
        ("voxel_runner", 65),
    ]
    for name, frames in gpu_demos:
        out = SHOTS / f"{name}.png"
        subprocess.run(
            [str(BUILDS / name), "--demo", "--frames", str(frames), "--screenshot", str(out)],
            env=env,
            check=True,
        )
        print(f"Saved {out}")

    # term_snake truecolor ANSI dump -> PNG
    snake_raw = subprocess.check_output([str(BUILDS / "term_snake"), "--ansi-dump"], text=True)
    render_ansi_terminal(
        snake_raw,
        "term_snake — Goose TUI (24-bit TrueColor)",
        SHOTS / "term_snake.png",
        cols=76,
        rows=20,
        default_bg=(10, 12, 18),
    )

    # sysbench CLI output -> PNG
    sys_raw = subprocess.check_output([str(BUILDS / "sysbench")], text=True)
    sys_lines = [line for line in sys_raw.splitlines() if line.strip() != ""]
    render_ansi_terminal(
        "\n".join(sys_lines) + "\n",
        "sysbench — Goose Native Micro-Benchmarks",
        SHOTS / "sysbench.png",
        cols=74,
        rows=max(10, len(sys_lines) + 1),
    )

    # devbox CLI demo output -> PNG
    dev_raw = subprocess.check_output([str(BUILDS / "devbox"), "demo"], text=True)
    dev_lines = [line for line in dev_raw.splitlines() if line.strip() != ""]
    render_ansi_terminal(
        "\n".join(dev_lines) + "\n",
        "devbox — Goose Developer Toolkit",
        SHOTS / "devbox.png",
        cols=76,
        rows=max(10, len(dev_lines) + 1),
    )

    return 0


if __name__ == "__main__":
    sys.exit(main())

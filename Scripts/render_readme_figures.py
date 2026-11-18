#!/usr/bin/env python3
"""Compose the README figures from real engine renders.

Inputs:
  <RAW_DIR>   output of Scripts/render_readme_figures.swift (real PhotoEngine renders)
  <UI_DIR>    artifacts/p3-verify/ui-smoke (real app window screenshots)
Output:
  docs/images/*.png|jpg

Boundaries: the photographs in every figure are the synthetic fixtures under
artifacts/demo/input. No user photograph is read or written here. These figures
document pipeline behaviour, not photographic quality or aesthetic acceptance.
"""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

RAW = Path(sys.argv[1])
UI = Path(sys.argv[2])
OUT = Path(sys.argv[3])
OUT.mkdir(parents=True, exist_ok=True)

BG = (13, 20, 25)
FG = (232, 236, 238)
MUTED = (138, 152, 160)
ACCENT = (198, 226, 130)

FONT_REG = "/System/Library/Fonts/PingFang.ttc"
FONT_MONO = "/System/Library/Fonts/SFNSMono.ttf"


def font(size, mono=False):
    return ImageFont.truetype(FONT_MONO if mono else FONT_REG, size)


def label(draw, xy, text, size=22, fill=FG, anchor="la", mono=False):
    draw.text(xy, text, font=font(size, mono), fill=fill, anchor=anchor)


def caption_bar(draw, box, title, subtitle=None):
    x, y, w, h = box
    draw.text((x, y), title, font=font(24), fill=FG, anchor="la")
    if subtitle:
        draw.text((x, y + 34), subtitle, font=font(18), fill=MUTED, anchor="la")


# ---------------------------------------------------------------- before/after
def figure_before_after():
    steps = [
        ("raw-valley-baseline.jpg", "① 解码基线", "解码后未做任何调整"),
        ("raw-valley-balanced.jpg", "② 自动方案「暗部可读」",
         "曝光 +0.04 EV · 阴影 +0.31 EV · 中间调 +0.08 EV（引擎实测输出）"),
        ("raw-valley-film.jpg", "③ 胶片风格", "富士 Classic Chrome 近似，强度 0.60"),
        ("raw-valley-effects.jpg", "④ 质感叠加", "辉光 / 暗角 / 颗粒 / 红晕 / 薄雾 / 褪色"),
    ]
    imgs = [Image.open(RAW / name).convert("RGB") for name, _, _ in steps]
    tile_w = 620
    tile_h = int(tile_w * imgs[0].height / imgs[0].width)
    gap, pad, cap = 24, 40, 78
    width = pad * 2 + tile_w * 2 + gap
    height = pad * 2 + (tile_h + cap) * 2 + gap
    canvas = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(canvas)
    for index, (image, (_, title, subtitle)) in enumerate(zip(imgs, steps)):
        column, row = index % 2, index // 2
        x = pad + column * (tile_w + gap)
        y = pad + row * (tile_h + cap + gap)
        canvas.paste(image.resize((tile_w, tile_h), Image.LANCZOS), (x, y))
        caption_bar(draw, (x, y + tile_h + 12, tile_w, cap), title, subtitle)
    canvas.save(OUT / "fig-before-after.jpg", quality=88, optimize=True, progressive=True)
    print("fig-before-after.jpg", canvas.size)


# ---------------------------------------------------------------- LUT catalogue
def figure_lut_catalogue():
    presets = json.loads((RAW / "lut-order.json").read_text())
    columns, tile = 8, 150
    pad, gap, cap = 36, 10, 44
    rows = (len(presets) + 1 + columns - 1) // columns  # +1 for the neutral reference
    width = pad * 2 + columns * tile + (columns - 1) * gap
    height = pad * 2 + rows * (tile + cap) + (rows - 1) * gap
    canvas = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(canvas)
    entries = [("raw-lut-original.jpg", "原色（未套用）")] + [
        (f"raw-lut-{p['id']}.jpg", p["name"]) for p in presets
    ]
    for index, (name, title) in enumerate(entries):
        column, row = index % columns, index // columns
        x = pad + column * (tile + gap)
        y = pad + row * (tile + cap + gap)
        image = Image.open(RAW / name).convert("RGB").resize((tile, tile), Image.LANCZOS)
        canvas.paste(image, (x, y))
        draw.rectangle([x, y, x + tile - 1, y + tile - 1], outline=(40, 52, 60))
        draw.text((x + tile // 2, y + tile + 10), title, font=font(15), fill=MUTED, anchor="ma")
    canvas.save(OUT / "fig-lut-catalogue.jpg", quality=86, optimize=True, progressive=True)
    print("fig-lut-catalogue.jpg", canvas.size)


# ------------------------------------------------------------------ tone curve
def figure_tone_curve():
    samples = json.loads((RAW / "tone-curve.json").read_text())
    size, pad, head = 760, 96, 132
    plot = size
    width, height = plot + pad * 2, plot + pad + head + 116
    canvas = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(canvas)
    left, top = pad, head

    # Grid every 25% of the encoded range.
    for fraction in [0, 0.25, 0.5, 0.75, 1.0]:
        x = left + fraction * plot
        y = top + (1 - fraction) * plot
        draw.line([(left, y), (left + plot, y)], fill=(32, 44, 51), width=1)
        draw.line([(x, top), (x, top + plot)], fill=(32, 44, 51), width=1)
        label(draw, (left - 12, y), f"{int(fraction * 100)}", 16, MUTED, anchor="rm")
        label(draw, (x, top + plot + 10), f"{int(fraction * 100)}", 16, MUTED, anchor="ma")
    draw.rectangle([left, top, left + plot, top + plot], outline=(56, 70, 78))
    # Identity reference.
    draw.line([(left, top + plot), (left + plot, top)], fill=(60, 72, 80), width=2)
    label(draw, (left + plot - 8, top + 8), "恒等线 y = x", 16, (96, 110, 118), anchor="ra")

    points = [(left + s["in"] * plot, top + (1 - s["out"]) * plot) for s in samples]
    draw.line(points, fill=ACCENT, width=4, joint="curve")

    # Zone labels along the input axis.
    zones = [("黑调", 0.08), ("阴影", 0.28), ("中间调", 0.50), ("高光", 0.74), ("白调", 0.93)]
    for name, position in zones:
        x = left + position * plot
        draw.line([(x, top + plot), (x, top + plot + 7)], fill=(90, 104, 112), width=2)
        label(draw, (x, top + plot + 30), name, 17, MUTED, anchor="ma")

    label(draw, (left, 24), "五区 EV 曲线的实测响应", 26, FG, anchor="la")
    label(draw, (left, 60), "黑调 −0.60　阴影 +0.35　中间调 +0.20　高光 −0.45　白调 +0.25 EV", 18, MUTED, anchor="la")
    label(draw, (left, 84), "1024 级灰阶斜坡经 PhotoEngine 实测", 16, (104, 118, 126), anchor="la")
    label(draw, (left + plot // 2, top + plot + 62), "输入亮度（编码值 %）", 18, MUTED, anchor="ma")
    canvas.save(OUT / "fig-tone-curve.png", optimize=True)
    print("fig-tone-curve.png", canvas.size)


# --------------------------------------------------------------- mask coverage
def figure_masks():
    panels = [
        ("raw-mask-coverage.png", "径向蒙版覆盖率", "椭圆半径 0.20 · 羽化 0.75 · 实测权重"),
        ("raw-valley-masked.jpg", "径向蒙版效果", "+0.55 EV · 饱和度 1.05"),
        ("raw-mask-range.png", "亮度范围蒙版覆盖率", "选区 0.62–1.00 · 软边 0.18"),
        ("raw-valley-range-mask.jpg", "亮度范围效果", "−0.45 EV，仅作用于实测高亮区"),
    ]
    imgs = [Image.open(RAW / name).convert("RGB") for name, _, _ in panels]
    tile_w = 620
    tile_h = int(tile_w * imgs[0].height / imgs[0].width)
    gap, pad, cap = 24, 40, 74
    width = pad * 2 + tile_w * 2 + gap
    height = pad * 2 + (tile_h + cap) * 2 + gap
    canvas = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(canvas)
    for index, (image, (_, title, subtitle)) in enumerate(zip(imgs, panels)):
        column, row = index % 2, index // 2
        x = pad + column * (tile_w + gap)
        y = pad + row * (tile_h + cap + gap)
        canvas.paste(image.resize((tile_w, tile_h), Image.LANCZOS), (x, y))
        caption_bar(draw, (x, y + tile_h + 12, tile_w, cap), title, subtitle)
    canvas.save(OUT / "fig-mask-coverage.jpg", quality=88, optimize=True, progressive=True)
    print("fig-mask-coverage.jpg", canvas.size)


# ------------------------------------------------------------------- UI sheets
def ui_sheet(source_names, out_name, columns, tile_w, title=None):
    missing = [n for n in source_names if not (UI / n).exists()]
    if missing:
        print(f"skip {out_name}: missing {missing} (run Scripts/ui_smoke.sh first)")
        return
    imgs = [Image.open(UI / name).convert("RGB") for name in source_names]
    tiles = []
    for image in imgs:
        tiles.append(image.resize((tile_w, int(tile_w * image.height / image.width)), Image.LANCZOS))
    tile_h = tiles[0].height
    gap, pad = 16, 28
    rows = (len(tiles) + columns - 1) // columns
    header = 62 if title else 0
    width = pad * 2 + columns * tile_w + (columns - 1) * gap
    height = pad * 2 + header + rows * tile_h + (rows - 1) * gap
    canvas = Image.new("RGB", (width, height), BG)
    draw = ImageDraw.Draw(canvas)
    if title:
        label(draw, (pad, pad), title, 24, FG, anchor="la")
    for index, tile in enumerate(tiles):
        column, row = index % columns, index // columns
        x = pad + column * (tile_w + gap)
        y = pad + header + row * (tile_h + gap)
        canvas.paste(tile, (x, y))
        draw.rectangle([x, y, x + tile_w - 1, y + tile_h - 1], outline=(40, 52, 60))
    canvas.save(OUT / out_name, quality=88, optimize=True, progressive=True)
    print(out_name, canvas.size)


if __name__ == "__main__":
    figure_before_after()
    figure_lut_catalogue()
    figure_tone_curve()
    figure_masks()
    ui_sheet(["01-launch.png", "02-folder-loaded.png"], "fig-ui-workspace.jpg", 2, 880)
    ui_sheet(["tab-01-分析.png", "tab-02-基础.png", "tab-03-局部.png", "tab-04-人像.png"],
             "fig-ui-inspector.jpg", 2, 880)

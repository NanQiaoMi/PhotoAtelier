#!/usr/bin/env python3
"""Draws docs/images/fig-pipeline.svg -> .png (rasterized with qlmanage).

The stage order encoded here mirrors Sources/PhotoCore/PhotoEngine.swift
(`process`). If that order changes, update this file: the README figure is a
diagram of the real call sequence, not an idealized one.
"""
import subprocess
import sys
from pathlib import Path

OUT = (Path(sys.argv[1]) if len(sys.argv) > 1 else Path("docs/images")).resolve()
OUT.mkdir(parents=True, exist_ok=True)

W, H = 1560, 1010
BG = "#0d1419"
PANEL = "#141f27"
PANEL_EDGE = "#24333d"
FG = "#e8ecee"
MUTED = "#8a98a0"
DIM = "#66757e"
ACCENT = "#c6e282"
BLUE = "#7fb6d6"
WARM = "#e0b071"

FONT = "PingFang SC, Helvetica Neue, sans-serif"
MONO = "SF Mono, Menlo, monospace"

parts = []
add = parts.append

add(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}">')
add(f'<rect width="{W}" height="{H}" fill="{BG}"/>')


def esc(s):
    return (s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))


def text(x, y, s, size=15, fill=FG, weight="400", anchor="start", family=FONT, spacing=0):
    extra = f' letter-spacing="{spacing}"' if spacing else ""
    add(f'<text x="{x}" y="{y}" font-family="{family}" font-size="{size}" fill="{fill}" '
        f'font-weight="{weight}" text-anchor="{anchor}"{extra}>{esc(s)}</text>')


def box(x, y, w, h, title, body="", fill=PANEL, edge=PANEL_EDGE, title_fill=FG, radius=8, tag=None):
    add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{radius}" fill="{fill}" '
        f'stroke="{edge}" stroke-width="1"/>')
    ty = y + (30 if body else h / 2 + 6)
    text(x + 16, ty, title, 16, title_fill, "600")
    if body:
        for index, line in enumerate(body.split("\n")):
            text(x + 16, ty + 24 + index * 20, line, 13, MUTED)
    if tag:
        text(x + w - 14, y + 22, tag, 12, DIM, "500", "end", MONO)


def arrow(x1, y1, x2, y2, color=MUTED, dash=None, width=1.6):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<path d="M {x1} {y1} L {x2} {y2}" stroke="{color}" stroke-width="{width}" '
        f'fill="none" marker-end="url(#arrow)"{d}/>')


def elbow(x1, y1, x2, y2, color=MUTED, dash=None):
    mid = (y1 + y2) / 2
    d = f' stroke-dasharray="{dash}"' if dash else ""
    add(f'<path d="M {x1} {y1} L {x1} {mid} L {x2} {mid} L {x2} {y2}" stroke="{color}" '
        f'stroke-width="1.6" fill="none" marker-end="url(#arrow)"{d}/>')


add('<defs><marker id="arrow" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" '
    'markerHeight="7" orient="auto-start-reverse">'
    f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{MUTED}"/></marker></defs>')

# ---------------------------------------------------------------- title
text(48, 54, "Photo Atelier 处理管线", 26, FG, "600")
text(48, 84, "Sources/PhotoCore/PhotoEngine.swift · process() 的实际阶段顺序", 14, MUTED)

# ---------------------------------------------------------------- input column
COL_A_X, COL_A_W = 48, 300
text(COL_A_X, 132, "输入", 13, DIM, "600", spacing=1)
box(COL_A_X, 146, COL_A_W, 96, "解码", "ImageIO / CIRAWFilter\n方向已烘焙 · 归一化 EXIF")
box(COL_A_X, 258, COL_A_W, 96, "色彩管理", "嵌入 ICC → extended linear sRGB\n浮点工作空间 RGBAf")
box(COL_A_X, 370, COL_A_W, 118, "分析（只读）", "最长边 384 px 线性采样\nP05/P50/P95/P99 · 中性色偏差\nVision 人脸框与内容标签")
box(COL_A_X, 504, COL_A_W, 118, "场景判定", "题材证据 → 三套方案\n自动增量经原尺寸渲染复核\n超限一起减弱，不静默越界")

text(COL_A_X, 660, "配方", 13, DIM, "600", spacing=1)
box(COL_A_X, 674, COL_A_W, 96, "AdjustmentSettings", "版本 1–33 · 非破坏性\n中性字段走旧像素路径")
box(COL_A_X, 786, COL_A_W, 96, "批量配方", "整文件夹一份配方\n逐图重算场景与保护测量", fill="#111b22")

# ---------------------------------------------------------------- pipeline column
COL_B_X, COL_B_W = 412, 560
text(COL_B_X, 132, "处理（逐张串行，取消以整张为边界）", 13, DIM, "600", spacing=1)

stages = [
    ("基础影调", "曝光 · 白平衡 · 对比/饱和 · 五区 EV 曲线"),
    ("几何", "自动水平 · 透视 · Lensfun 镜头配置"),
    ("液化 / 美型", "人脸网格形变场 · 全局位移硬顶 3%"),
    ("调色工具", "RGB/亮度曲线 · HSL 8 色相 · 三色轮分级"),
    ("镜头效果", "暗角 · 横向色差"),
    ("修复 / 仿制画笔", "邻近纹理启发式填充 · 按来源偏移复制"),
    ("人像精修", "多人独立：磨皮 · 五区祛皱 · 眼牙 · 妆容 · 发色 · 五官微雕"),
    ("追色", "OKLab 分位数匹配 · 可仅作用于皮肤"),
    ("局部蒙版（LUT 前）", "径向/渐变/画笔/亮度范围/颜色范围 · 逐图细节适配"),
    ("LUT", "显式色彩空间与 DOMAIN · 三线性插值 · 皮肤/中性/亮度保护"),
    ("局部蒙版（LUT 后）", "收尾调整，与 LUT 前蒙版共享固定参考"),
    ("质感滤镜", "辉光 · 暗角 · 颗粒 · 红晕 · 薄雾 · 褪色 · 留银"),
    ("颜色协调与色域", "新增强色度/中性染色限制 → 目标色域收敛"),
]

y = 146
row_h = 46
gap = 9
for index, (title, body) in enumerate(stages):
    add(f'<rect x="{COL_B_X}" y="{y}" width="{COL_B_W}" height="{row_h}" rx="7" fill="{PANEL}" '
        f'stroke="{PANEL_EDGE}"/>')
    text(COL_B_X + 14, y + 20, f"{index + 1:02d}", 12, DIM, "500", family=MONO)
    text(COL_B_X + 48, y + 20, title, 15, FG, "600")
    text(COL_B_X + 48, y + 37, body, 12, MUTED)
    if index:
        arrow(COL_B_X + COL_B_W / 2, y - gap + 1, COL_B_X + COL_B_W / 2, y - 1)
    y += row_h + gap

# ---------------------------------------------------------------- output column
COL_C_X, COL_C_W = 1016, 300
text(COL_C_X, 132, "输出", 13, DIM, "600", spacing=1)
box(COL_C_X, 146, COL_C_W, 96, "编码", "JPEG · 16 位 PNG/TIFF · HEIC\nsRGB / Display P3")
box(COL_C_X, 258, COL_C_W, 118, "原子落盘", "排他安装，同名递增\n绝不覆盖原片或已有导出")
box(COL_C_X, 392, COL_C_W, 118, "报告", "batch-<UUID>.json\n逐张结果 · 警告 · 保护前后变化")
box(COL_C_X, 526, COL_C_W, 96, "隐私", "默认移除 GPS 与相机标识\n可选保留拍摄参数")

text(COL_C_X, 660, "只读承诺", 13, DIM, "600", spacing=1)
box(COL_C_X, 674, COL_C_W, 208,
    "原片永不修改",
    "· 输入/输出目录不得相同或互相包含\n"
    "· 扫描不追随符号链接\n"
    "· 单张失败写入报告并继续\n"
    "· 评级与废片存于应用支持目录\n"
    "· 无出站请求；局域网预览需显式开启",
    fill="#111b22")

# ---------------------------------------------------------------- cross links
def stage_y(index):
    return 146 + index * (row_h + gap)


arrow(COL_A_X + COL_A_W, 194, COL_B_X, stage_y(0) + 23)                  # decode -> 01
arrow(COL_A_X + COL_A_W, 563, COL_B_X, stage_y(0) + 23, BLUE, "4 3")     # scene -> 01
arrow(COL_A_X + COL_A_W, 429, COL_B_X, stage_y(6) + 23, BLUE, "4 3")     # analysis -> 07

# The recipe drives every stage, so it joins a bracket along the pipeline's
# left edge instead of a single box.
bracket_x = COL_B_X - 18
add(f'<path d="M {bracket_x} {stage_y(0) + 23} L {bracket_x} {stage_y(12) + 23}" '
    f'stroke="{BLUE}" stroke-width="1.4" stroke-dasharray="4 3" fill="none"/>')
for index in range(13):
    add(f'<path d="M {bracket_x} {stage_y(index) + 23} L {COL_B_X - 3} {stage_y(index) + 23}" '
        f'stroke="{BLUE}" stroke-width="1.2" stroke-dasharray="4 3" fill="none"/>')
add(f'<path d="M {COL_A_X + COL_A_W} 722 L {bracket_x} 722 L {bracket_x} {stage_y(12) + 23}" '
    f'stroke="{BLUE}" stroke-width="1.4" stroke-dasharray="4 3" fill="none"/>')

arrow(COL_B_X + COL_B_W, stage_y(12) + 23, COL_C_X, 194, WARM)           # 13 -> encode
arrow(COL_B_X + COL_B_W, stage_y(12) + 23, COL_C_X, 451, WARM, "4 3")    # 13 -> report

# ---------------------------------------------------------------- legend
legend_y = 960
add(f'<rect x="48" y="{legend_y - 16}" width="22" height="2" fill="{BLUE}"/>')
text(80, legend_y - 10, "分析证据流入（只读，不改变像素）", 13, MUTED)
add(f'<rect x="352" y="{legend_y - 16}" width="22" height="2" fill="{WARM}"/>')
text(384, legend_y - 10, "像素流", 13, MUTED)
add(f'<rect x="470" y="{legend_y - 16}" width="22" height="2" fill="{MUTED}" stroke-dasharray="4 3"/>')
text(502, legend_y - 10, "阶段顺序（与代码一致）", 13, MUTED)
add(f'<rect x="700" y="{legend_y - 16}" width="22" height="2" fill="{BLUE}" stroke-dasharray="4 3"/>')
text(732, legend_y - 10, "配方与批量参数驱动全部阶段", 13, MUTED)

add('</svg>')

svg_path = OUT / "fig-pipeline.svg"
svg_path.write_text("\n".join(parts))
print("wrote", svg_path)

# qlmanage's WebKit renderer rejects a few valid constructs; Chrome renders the
# same file faithfully, so it is the rasterizer used for the committed PNG.
chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
png = OUT / "fig-pipeline.png"
result = subprocess.run([chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                         f"--window-size={W},{H}",
                         f"--screenshot={png}", svg_path.as_uri()],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if not png.exists():
    raise SystemExit("Chrome screenshot failed; the SVG is still written and valid.")
print("wrote", png)

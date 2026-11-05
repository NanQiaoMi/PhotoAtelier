# P2-A Implementation Plan: Hair & Cranial Volume, Hairline and Temple Reshaping

> Baseline Commit: `a638f8c`
> Branch: `feat/p2a-hair-cranial-reshaping`
> Target Milestone: P2-A (First Milestone of P2: Advanced Head & Hair Aesthetics)

---

## 1. Objectives & Scope

In commercial portrait photography and high-end beauty retouchers (e.g., PixelCake / 像素蛋糕), head-to-face proportion and hair volume are among the highest-demand adjustments:
1. **高颅顶 / 颅顶蓬松 (Cranial Top / Volume)**:
   - Elevates the crown of the head above the forehead, creating the desirable "头包脸" (head framing face) aesthetic, making the face look smaller and younger while giving flat hair a natural, voluminous lift.
2. **发际线微调 (Hairline Refinement)**:
   - Lowering a receding or excessively high forehead hairline (or raising an overly cramped forehead) with smooth, natural transitions.
3. **丰太阳穴 (Temple Plumping)**:
   - Fills in temporal bone depressions (太阳穴凹陷) between the outer eyebrows and hairline, smoothing the zygomatic-to-forehead transition for a fluid, youthful face outline.

---

## 2. Technical Architecture & Invariants

1. **Pure Vector Warp Fields (`WarpField`)**:
   - Built on top of the robust `WarpField` architecture (`CIWarpKernel` / Metal-backed grid interpolation).
   - Zero external neural network dependencies; runs natively on CPU/GPU via Core Image.
2. **Deterministic Geometry & Landmark Extrapolation**:
   - Derives temporal anchor points from facial contour upper points and eyebrow endpoints.
   - Derives cranial top anchor points from eyebrow-to-chin vertical proportions projected upward into the crown region (`y > boundingBox.maxY` in Core Image coordinates).
   - Smooth Gaussian falloff ensures hair texture is preserved with 0 tearing or high-frequency distortion.
3. **Strict Neutrality & Recipe Backward Compatibility**:
   - `cranialTop == 0`, `hairline == 0`, `temple == 0` are exactly neutral (0 displacement).
   - Existing recipes v1~v14 decode missing fields as 0 (clean round-trip).
   - Presets updated with aesthetic starting points (e.g. `youthful` gets +0.25 cranialTop, +0.15 temple).
4. **Full UI & Control Binding**:
   - `PortraitRetouchPanel` adds three responsive sliders with label, value display, range `-1...1`, and instant undo/reset.
   - Preserves background protection (`backgroundProtection`) and manual liquify brush compatibility.

---

## 3. Work Breakdown & Checkable Items

- [x] Task 1: Extend `FaceReshapeParameters` with `cranialTop`, `hairline`, `temple` in `Sources/PhotoCore/FaceReshape.swift`.
- [x] Task 2: Implement displacement vector math in `FaceReshapeEngine.addFaceControls` for cranial top, hairline, and temple plumping.
- [x] Task 3: Update `FaceShapePreset` presets with appropriate cranial top and temple values.
- [x] Task 4: Add UI sliders to `Sources/PhotoAtelier/PortraitRetouchPanel.swift`.
- [x] Task 5: Add comprehensive unit tests in `Tests/PhotoCoreTests/LiquifyWarpTests.swift`.
- [x] Task 6: Run verification (`swift build`, `swift test -j 2`, `build_app.sh --universal`, `verify_app.py`, `ui_smoke.sh`).
- [x] Task 7: Author `docs/p2a-release-notes.md` and update `docs/development-handover.md` and `README.md`.
- [x] Task 8: Git commit with clean hygiene and merge `--no-ff` into `feat/p1c-culling-makeup-perf`.

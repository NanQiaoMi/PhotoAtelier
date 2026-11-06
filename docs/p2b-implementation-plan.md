# P2-B Implementation Plan: Hair Refinement (Gap Filling, Hair Sheen & Tone)

> Baseline Commit: `40e119d`
> Branch: `feat/p2b-hair-refinement`
> Target Milestone: P2-B (Second Milestone of P2: Advanced Hair Aesthetics & Refinement)

---

## 1. Objectives & Scope

In portrait retouching, hair condition heavily influences perceived portrait quality:
1. **发缝填充 (Hair Parting / Scalp Gap Filling)**:
   - Fills wide, sparse hair partings and receding temples/hairline gaps where bright scalp skin shows through dark hair.
   - Preserves crossing hair strand textures while shading and suppressing the bright pink/pale scalp skin tone underneath toward surrounding hair root tones.
2. **秀发光泽 / 天使光环 (Hair Sheen / Angel Ring Highlight)**:
   - Enhances soft specular highlights across the crown arc, giving dry/frizzy hair a healthy, luminous satin finish.
3. **发色深邃 / 去枯黄 (Hair Tone Depth & Brassiness Suppression)**:
   - Subtly deepens hair mid-tones and reduces yellowish/brassy tinting in dull hair, improving figure-ground contrast and making facial skin look brighter and cleaner.

---

## 2. Technical Architecture & Invariants

1. **Deterministic Core Image / Metal Pipeline (`HairRefinementEngine`)**:
   - Zero external neural network dependencies; runs natively on GPU/CPU via Core Image kernels.
   - Evaluated within `PortraitRefinementEngine` stage, after blemish/frequency separation and before teeth/eyes.
2. **Geometrical Scalp & Crown Localization**:
   - Anchored on facial landmarks (`FaceLandmarkSet` / `FaceSemanticMaskSet`):
     - Derives the crown & parting corridor from forehead/eyebrow endpoints up to the cranial top.
     - Skin-tone scalp gate: detects pixels in the hair corridor that have skin-like chrominance and high luminance relative to dense hair.
   - Soft feathering and edge-aware blending ensure no hard cutoffs, color blockiness, or background artifacts.
3. **Strict Backward Compatibility & Neutrality**:
   - `hairGapFilling == 0`, `hairGloss == 0`, `hairDarkening == 0` are strictly neutral (0 pixel change).
   - Codable decodes missing fields from older recipes as 0 (clean round-trip with recipes v10~v14).
   - Bounds validated in `0...1`.
4. **UI & Preset Integration**:
   - Integrated into `PortraitRetouchPanel` under a dedicated "秀发精修与发缝" section with smooth sliders.

---

## 3. Work Breakdown & Checkable Items

- [x] Task 1: Extend `PortraitRefinementSettings` with `hairGapFilling`, `hairGloss`, `hairDarkening` in `Sources/PhotoCore/PortraitRefinement.swift`.
- [x] Task 2: Implement `HairRefinementEngine` with scalp detection, parting gap shading, and hair sheen kernels in `Sources/PhotoCore/HairRefinement.swift`.
- [x] Task 3: Wire `HairRefinementEngine.apply` into `PortraitRefinementEngine.apply`.
- [x] Task 4: Add UI controls to `Sources/PhotoAtelier/PortraitRetouchPanel.swift`.
- [x] Task 5: Add comprehensive unit tests in `Tests/PhotoCoreTests/HairRefinementTests.swift` and `PortraitRetouchTests.swift`.
- [x] Task 6: Run verification (`swift build`, `swift test -j 2`, `build_app.sh --universal`, `verify_app.py`, `ui_smoke.sh`).
- [x] Task 7: Author `docs/p2b-release-notes.md` and update `docs/development-handover.md` and `README.md`.
- [x] Task 8: Git commit per path and merge `--no-ff` into `feat/p1c-culling-makeup-perf`.

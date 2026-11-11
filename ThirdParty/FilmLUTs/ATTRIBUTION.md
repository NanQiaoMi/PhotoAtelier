# Film LUT attribution and color contract

`PhotoCore.FilmLUTCatalog` is an original Swift adaptation of the selected
hand-tuned look parameters and color transform from
[`sadziu/Fuji-Recipe-Converter`](https://github.com/sadziu/Fuji-Recipe-Converter/tree/a6691ea0e880ddd5fd19d7ca2d48a502fb0e7e07).
The upstream repository is pinned to commit
`a6691ea0e880ddd5fd19d7ca2d48a502fb0e7e07` (2026-10-07).

Upstream attribution: Copyright (c) 2026 Sadziu and contributors. The upstream
code and the material adapted here are used under the MIT License; the full
license text is in [LICENSE-MIT.txt](LICENSE-MIT.txt).

## Upstream files used

The SHA-256 values below were computed from the raw files at the pinned commit.

| File | Use | SHA-256 |
| --- | --- | --- |
| `js/data.js` | Selected hand-tuned parameters for Classic Chrome, ASTIA, Classic Neg, ETERNA, and ACROS | `e0b7bb407413da3143c88d57126cc0307df3859450bdea02bd44ad05f72eb5bd` |
| `js/engine.js` | Monotone tone curve, hue-band interpolation, HSL adjustments, split toning, and 3D grid ordering | `4bddd884627a3b4ba1b03f102b01f84480e1c709a79711567e2ae439200b22a8` |
| `js/export.js` | `.cube` input/output description, domain, and table export contract | `ee2b4a24fcf2121c6736cc0977e48937ab433f4314dce4bcefacf04f8e3fb258` |
| `README.md` | Accuracy disclaimer and LUT working-space expectation | `0733c681241a5662dcaa1a829b1d955fdc1bc34a43d2c3aad09c2675fed63c25` |
| `LICENSE` | MIT grant and required notice | `c487b0f66664fc7141ea8764edfed92b2d8969efdf50778e5bbf5f7a530e966f` |

## Adapted behavior and limits

- `js/data.js` lines 13–29 describes its simulation values as hand-tuned
  approximations, not measurements of Fujifilm's proprietary color science.
  The port carries only the five listed looks and their default color settings.
- `js/engine.js` functions `FR.makeCurve`, `FR.derive`, `FR.makeTransform`, and
  `FR.buildLut` define the adapted transform. The Swift implementation keeps
  the monotone cubic curve, hue-band interpolation, HSL and split-tone behavior,
  and red-fastest 33 × 33 × 33 sampling order.
- `js/export.js` `FR.toCube` identifies display-referred Rec.709 / sRGB gamma
  input and writes a `[0,1]` RGB domain. The port uses gamma-encoded sRGB values
  on input and output. `.cube` has no transfer-function metadata, so the
  contract is also attached to each preset as `LUTProvenance.inputContract`.
- Grain, clarity, sharpening, noise reduction, white-balance shifts, and
  camera-specific RAW development are not included in these static looks.
- The five tables are generated deterministically in memory. This application
  does not include an upstream `.cube`, Fujifilm software, Adobe camera
  profiles, or Fujifilm's official LUT data.

The names Classic Chrome, ASTIA, Classic Neg, ETERNA, and ACROS identify the
look being approximated. They are Fujifilm trademarks. This catalog is
independent, unofficial, and not a claim of camera-level equivalence.

# P1-I Implementation Plan: Technical Debt Cleanup & Harness Stabilization

> Baseline Commit: `026ac7f`
> Branch: `feat/p1i-tech-debt-cleanup`
> Target Milestone: P1-I (Closing P1 Release Lifecycle)

---

## 1. Objectives & Scope

1. **SmokeHarness Forward-Compatibility Protection**:
   - In `Sources/PhotoAtelier/SmokeHarness.swift`, replace rigid `restored.version == 9` and `savedRecipe["version"] == 9` with `>= 9`.
   - In `Sources/PhotoAtelier/PortraitSmokeHarness.swift` and `StyleWorkflowSmokeHarness.swift`, ensure version checks gracefully accept forward-compatible recipe versions (>= 9).
2. **`ui_smoke.sh` Robustness & De-flakiness**:
   - Add immediate macOS session lock detection (`ioreg -n Root -d1 -a | grep -q "<key>CGSSessionScreenIsLocked</key>"`), outputting actionable diagnostics with exit code 2 (precondition failure) rather than hanging AX keystroke automation.
   - Support `UI_SMOKE_OPEN_METHOD=cli` (or `--open-folder` hook via `open "$APP" --args --open-folder "$INPUT"`), providing a rock-solid alternative when NSOpenPanel GUI automation is blocked by window focus or sheet overlays.
   - Verify app executable mtime, SHA-256, and git commit integrity binding in evidence JSON.
3. **Documentation & Consistency Review**:
   - Verify recipe version gates (v1 to v14), Universal build pipeline (`--universal`), aesthetic review system integration, and test suite execution time.
   - Update `docs/development-handover.md`:
     - Update branch/HEAD table in §1.
     - In §9.1, mark P1-G, P1-H, P1-I as completed.
     - In §9.2, officially mark P1 milestones 100% finished.
     - Prepare P2 transition notes.
   - Update `README.md` to reflect full P1 feature set (Culling, Makeup, Performance, Universal build, Aesthetic acceptance).
   - Write `docs/p1i-release-notes.md`.
4. **Verification Gate**:
   - `swift build -j 2`
   - `swift test -j 2` (540 unit/integration tests all pass, 0 failures, total time <10 min)
   - `bash Scripts/build_app.sh --universal`
   - `python3 Scripts/verify_app.py build/PhotoAtelier.app`

---

## 2. Work Breakdown & Checkable Items

- [x] Task 1: Fix SmokeHarness rigid version gates (`restored.version >= 9`) in `Sources/PhotoAtelier/SmokeHarness.swift`, `PortraitSmokeHarness.swift`, and `StyleWorkflowSmokeHarness.swift`.
- [x] Task 2: Enhance `Scripts/ui_smoke.sh` with lock screen detection and CLI-based direct open option (`UI_SMOKE_OPEN_METHOD`).
- [x] Task 3: Run comprehensive test suite (`swift test -j 2`) verifying all 540 tests pass.
- [x] Task 4: Run universal app build (`Scripts/build_app.sh --universal`) and package verification (`Scripts/verify_app.py`).
- [x] Task 5: Author `docs/p1i-release-notes.md` and update `docs/development-handover.md` + `README.md`.
- [x] Task 6: Commit changes following git hygiene guidelines (Rule 3.6).
- [ ] Task 7: Merge `--no-ff` into `feat/p1c-culling-makeup-perf`, run post-merge regression, and delete branch.

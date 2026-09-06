# Paused: native multi-rebound shadow prediction

Not linked into `EightBPOfflineLines.dylib`. Active product is colored ball rings
plus extended native VisualGuide lines only.

Restore later by:

1. Moving `EightBPShadowPhysics.h` / `.mm` back beside `EightBPOfflineLines.m`
2. Re-adding the `.mm` compile + `-lc++` in `.github/workflows/build-ios.yml`
3. Re-wiring call sites carefully — **do not** call `EightBPShadowPredict` from
   the live shoot/aim path until staged dry-runs stop crashing

Full forensic notes: `E:\Cli\HANDOFF.md` section **8 Ball Pool 56.29.2 — paused rebound prediction**.

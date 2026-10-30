# Android phone-test harness (not game code, do not merge)

Branch `qa/android-phone-test`. A scene picker plus a perf field with an on-screen readout, built into a debug
arm64-v8a APK so the frame budget can be read off a real phone.

- `launcher.tscn` scene picker (big touch buttons); Android Back leaves a scene / quits the launcher.
- `field.tscn` + `field.gd`: the same world and spawner as `tests/benchmark/bullet_benchmark.gd`, run through the real
  game path (`BulletManager` stepping at 60 Hz in `_physics_process`, MultiMesh interpolation, rendered every frame).
  Scenes: Lua spike 1,000 scripted bullets (batched call, or per-bullet call) and plain 5,000 / 10,000 bullets.
- `overlay.gd`: FPS, frame time p50 / p95 / max over the last 300 rendered frames (full frame interval, including
  vsync wait), live bullet count, sim ms per physics tick, Lua ms per tick, renderer. Refreshes once a second and logs
  `SPIKE_RESULT {json}` (`adb logcat -s godot | grep SPIKE_`).
- `steer.lua` is the Scripting Engineer's spike script from PR #3 (b3a407f), `lua_driver.gd` drives it through stock
  lua-gdextension 0.8.2 (fetched by `tools/android_test/fetch_lua.sh`, SHA256-pinned, git-ignored).
- Desktop check: `godot --path . -- --scene=lua_batch|lua_each|plain_5k|plain_10k --seconds=10 [--shot=/tmp/x.png]`.
- Build: `tools/android_test/build_apk.sh`.

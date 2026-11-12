# Release builds

Release targets: **Windows, macOS, Linux, Web and Android (arm64)**. iOS is not a release target.
Builds come from the `export` job of `.github/workflows/ci.yml` and the presets in `export_presets.cfg`.
Nothing is code-signed with a paid identity: **Windows and Linux are unsigned**, macOS is ad-hoc signed only
(no Apple developer account, not notarized), and Android is a debug-signed APK.

**Where to download playable Linux, Windows and web builds:** every successful push to `main` (Import + GUT
must have passed) uploads three Actions artifacts, kept for 90 days:

* `scriptshot-linux-<sha7>` — `Scriptshot.x86_64` plus the native bullet `.so` and the Lua GDExtension `.so`
* `scriptshot-windows-<sha7>` — `Scriptshot.exe` plus the native bullet DLL and the Lua GDExtension DLL
* `scriptshot-web-<sha7>` — the web tree (`index.html`, wasm, pck, Lua side module)

Open the CI run for that commit (Actions → CI → the push to `main`, or the checks on the commit) and download
the artifact. The first 7 characters of the commit SHA are in the name, for example `scriptshot-linux-08f3c94`.
Those 90-day Actions artifacts stay available. After this workflow is on `main`, each successful CI push to `main` also replaces a rolling **pre-release** tagged `nightly` (unsigned Linux, Windows and web zips; never Latest; macOS is not included) and deploys the web tree to GitHub Pages (see section 10). Windows builds are unsigned,
so SmartScreen will warn on first launch (**More info > Run anyway**). Linux: `chmod +x Scriptshot.x86_64`
(artifact download strips the executable bit) then run it.

The full matrix, including macOS and Android, is still manual: Actions → CI → Run workflow → tick `run_export`.
A mid-suite GUT hang (issue #67) fails the test job and skips the export; rerun that workflow rather than
expecting a build from a red commit.

## 1. What the job produces

Exports run on `ubuntu-24.04` with the pinned headless Godot 4.7.2 and its export templates
(checksum-verified). The template cache stores only the files the matrix needs, not the full tpz
(see below). Each artifact is the ready-to-run folder (`build/<platform>/`) and is named
`scriptshot-<slug>-<sha7>` (`linux`, `windows`, `web`, and on a manual full run also `macos` and `android`),
retained 90 days. Pull requests do not run this job.

| Preset | Output (git-ignored `build/`) | Contents | Signing |
|---|---|---|---|
| Windows Desktop | `build/windows/Scriptshot.exe` | x86_64 exe (`embed_pck=true`, no separate `.pck`) plus `libscriptshot_native.windows.template_release.x86_64.dll` and `libluagdextension.windows.template_release.x86_64.dll` | none (SmartScreen warns on first run) |
| macOS | `build/macos/Scriptshot.zip` | `Scriptshot.app`, universal (x86_64 + arm64), including the native dylib | ad-hoc (`codesign/codesign=1`), not notarized |
| Linux | `build/linux/Scriptshot.x86_64` | x86_64 executable (`embed_pck=true`, no separate `.pck`) plus `libscriptshot_native.linux.template_release.x86_64.so` and `libluagdextension.linux.template_release.x86_64.so` | none |
| Web | `build/web/index.html` + `index.js`, `index.wasm` (dlink main module), `index.side.wasm` (engine side module), `libluagdextension.web.template_release.wasm32.nothreads.wasm` (Lua), `index.pck`, audio worklets, icons. No native bullet wasm (see section 4) | static site | n/a |
| Android | `build/android/Scriptshot-debug.apk` (+ `.idsig`) | arm64-v8a only, minSdk 24, targetSdk 36 | debug keystore generated in CI |

The macOS and Android exports need **Import ETC2 ASTC** enabled in `project.godot`
(`rendering/textures/vram_compression/import_etc2_astc=true`; already on `main`). Without it Godot refuses to export,
with the message "ETC2/ASTC texture compression is required".


### Android emulator smoke (not the release APK)

The release Android artifact above is **arm64-v8a only** (phones). GitHub-hosted runners are x86_64, so CI emulator smoke uses the **Lua spike** dual-ABI APK instead — see `.github/workflows/android-emulator-smoke.yml` and `docs/scripting/testing.md` §2.4. Dispatch it from Actions; it does not run on PRs.

`tools/ci/check_export_preset.py` runs in the `test` job on every pull request and push, once per preset
(Windows Desktop, macOS, Linux, Web, Android, Web (smoke)), and again before each export. It fails on: any password
in the committed `export_presets.cfg`, committed Android keystore paths, an Android preset that is not arm64-only
or uses Gradle, a macOS preset whose `codesign/codesign` is not `1` or that enables notarization, and an iOS preset.
`codesign/codesign=3` (Xcode codesign) is rejected: that mode exists only on a macOS editor host, and CI exports
from Linux, where the only ad-hoc value is `1`. For the Web preset it fails when `extensions_support` is off (the no-dlink
template refuses to boot with the Lua GDExtension, issue #40) or when `exclude_filter` does not list
`scriptshot_native.gdextension`, and warns when threads are on (needs COOP/COEP). Every preset except `Web (smoke)` must
list `src/qa/*` in `exclude_filter` and must not set the `web_smoke` custom feature, and `Web (smoke)` must match the Web
preset except for its name, export path, `web_smoke` feature and the missing `src/qa/*` exclude (section 4.1).

After a successful export the same job checks the artifact, because Godot can exit 0 on a failed ad-hoc sign
(it is only an export warning):

* macOS: the zip listing must contain `_CodeSignature/CodeResources`.
* Android: `apksigner verify` on the APK (build-tools from the Android matrix entry).
* Linux: `timeout 60s ./Scriptshot.x86_64 --headless --quit`. The official template targets an older glibc, so the `ubuntu-24.04` runner can launch it. Windows has no equivalent cheap smoke here.
* Web: `tools/ci/web_smoke.py check-export build/web` (dlink template used, only the Lua side module in `gdextensionLibs`,
  no native bullet wasm, no `src/qa/` file). The browser smoke is the separate `web-smoke` job (section 4.1).

## 2. macOS: unsigned first launch

The app is ad-hoc signed and **not notarized**, so Gatekeeper blocks the first launch of a downloaded copy
("Apple cannot check it for malicious software"). Ad-hoc signing is still required: arm64 macOS refuses to
run completely unsigned binaries, so keep `codesign/codesign=1`. Do not commit `3` (Xcode codesign); CI rejects it.

1. Unzip `Scriptshot.zip` and move `Scriptshot.app` to Applications (or anywhere).
2. **macOS 14 (Sonoma) and older:** right-click (or Control-click) `Scriptshot.app` > **Open** > **Open**.
3. **macOS 15 (Sequoia) and newer** (the right-click shortcut no longer bypasses Gatekeeper): double-click the app once and dismiss
   the warning, then open **System Settings > Privacy & Security**, scroll to *Security*, click **Open Anyway** next to
   "Scriptshot was blocked", and confirm with your password / Touch ID.
4. Advanced alternative: remove the quarantine flag, then launch normally:
   `xattr -dr com.apple.quarantine /path/to/Scriptshot.app`

You only need to do this once per downloaded copy. A copy fetched with `curl` carries no quarantine flag and opens directly.
Notarization (no warning at all) needs a paid Apple developer account and is out of scope.

## 3. Windows and Linux

* Windows: run `Scriptshot.exe`. On the first launch SmartScreen shows "Windows protected your PC": **More info > Run anyway**.
  Resource editing (icon/metadata) is built into the 4.7.2 exporter, so no rcedit or wine is needed on the Linux runner.
* Linux: `chmod +x Scriptshot.x86_64 && ./Scriptshot.x86_64`. The Godot template is built on an older Ubuntu LTS for
  portability. Artifact download strips the executable bit, hence the chmod. CI also runs the binary once with
  `--headless --quit` before uploading it.

## 4. Web hosting

* Serve the folder as static files over **HTTPS** (or `localhost`) with `.wasm` as `application/wasm`.
* The current Web preset uses the **no-threads** template (`thread_support=false`): no special headers are needed.
* If **threads** are enabled, the page must be cross-origin isolated (otherwise `SharedArrayBuffer` is unavailable and the game does
  not start). Send on the HTML document and all assets:
  `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` (or `credentialless`).
  The preset option `progressive_web_app/ensure_cross_origin_isolation_headers` can emulate this via a service worker, which needs HTTPS and a
  second load. itch.io has a "SharedArrayBuffer support" checkbox.
* The Web preset has **`variant/extensions_support=true`** and `thread_support=false`, so it exports with
  `web_dlink_nothreads_{debug,release}.zip`. This is required, not optional: the Lua binding (lua-gdextension 0.8.2) is a
  GDExtension. Godot 4.7.2 copies every exported `.gdextension` wasm into the export and lists it in
  `GODOT_CONFIG.gdextensionLibs` **even when `extensions_support` is off**, and the no-dlink template's `index.js` then refuses to
  start ("GDExtension libraries are not supported by this engine version", issue #40). The extension's wasm must match the
  thread mode: lua-gdextension's `web.release.wasm32` key is the `.nothreads.wasm` side module (no shared memory, no atomics,
  `dylink.0`), which matches the 4.7.2 template build (Emscripten 4.0.20, "single-threaded, GDExtension support").
* **The native bullet library is not shipped on web** (CoS ruling on #36; native-on-web is tracked there). The Web preset's
  `exclude_filter` lists `scriptshot_native.gdextension, bin/*`. Godot 4.7.2 honours that for GDExtensions: an excluded
  `.gdextension` file is not exported, its libraries are not copied or listed in `gdextensionLibs`, and the exported
  `.godot/extension_list.cfg` drops it, so the engine never tries to load it (no "No GDExtension library found" errors). This works
  with or without web keys in `scriptshot_native.gdextension`: main has had `web.*.wasm32` keys and the `bin/web.wasm32/`
  layout since #35, and the exclusion was also checked on the tree before #35, which had none. Web therefore runs on the
  GDScript bullet pool and does not warn for that default (the library is not shipped, and the game does not try to load it). Selecting native (`--bullet-backend=native`) stays on GDScript, does not instantiate the sim, and logs the usual single fallback warning. Android has no separate bullet path: a missing library uses the same one-warning GDScript fallback as desktop.
* Size: the dlink no-threads release export is about **49.2 MiB** on disk (`index.side.wasm` 44.1 MB, `index.wasm` 1.5 MB,
  Lua side module 2.65 MB, `index.js` 2.9 MB, `index.pck` 0.4 MB), versus 42.07 MiB for the old no-dlink export that did not boot.
  Gzipped, the three wasm files are about 11.7 MB. On a local server in headless Chromium (SwiftShader) the engine starts about
  1.7-2.0 s after navigation.

### 4.1 Browser smoke (`tools/ci/web_smoke.sh`, CI job "Web smoke (headless Chromium)")

`./tools/ci/web_smoke.sh` runs on every pull request and push to `main` (`web-smoke` job). For release, then debug, it
exports two presets, checks each export without a browser, then serves it over plain HTTP (no COOP/COEP; the no-threads
build needs none) and loads it in headless Chromium with Playwright (`tools/ci/web_smoke.py`). It needs the Godot 4.7.2
editor, the `web_dlink_nothreads_*.zip` templates, and `pip install playwright` plus `python -m playwright install chromium`
(or `CHROME_PATH` pointing at Chrome). `WEB_SMOKE_MODES=release` runs one mode. Exit code is non-zero on any failure.

The smoke scene never ships. `src/qa/` (`web_smoke.tscn`, `web_smoke.gd`, `web_smoke_shot.lua`) is in the `exclude_filter`
of every shipping preset, and there is no autoload. The `Web (smoke)` preset is the Web preset plus the custom feature
`web_smoke`, without the `src/qa/*` exclude. project.godot's `application/run/main_scene.web_smoke` override makes
`src/qa/web_smoke.tscn` the main scene only when that feature is set. Release web templates refuse a scene path on the
command line (`disable_path_overrides`), so a feature override is the way to pick the scene. A feature-tagged autoload
(`autoload/Name.feature`) does not work: Godot 4.7.2 registers it on every platform. The override key itself is still in
every project.binary, pointing at a file that is not exported; without the feature it is never read.
`check_export_preset.py` enforces both presets (section 1).

* **Export check, shipping `Web` (`build/web`):** `gdextensionLibs` is exactly the lua-gdextension no-threads side module,
  `index.side.wasm` exists, no `scriptshot_native` file is exported, and `index.pck` holds no
  `scriptshot_native.gdextension`, no `bin/` and no `src/qa/` file. Its `extension_list.cfg` lists only lua-gdextension,
  and its project.binary has no `WebSmoke` autoload and no `web_smoke` feature.
* **Export check, `Web (smoke)` (`build/web-smoke-export`):** the same, except that the `src/qa/` files and the `web_smoke`
  feature must be present.
* **`boot`** (shipping export): the engine starts and the main scene runs for 6 s with no console error. It fails if the
  6 s window does not finish before the scenario timeout.
* **`lua`** (smoke export): `web_smoke.tscn` instances `scenes/main.tscn` and loads `src/qa/web_smoke_shot.lua` through
  `ScriptHost` (`LuaBulletBehavior.load_file`). It spawns 8 shots on the main scene's `BulletManager`, and each one
  splits off a child from Lua. It needs exactly one `SMOKE_DONE ok`, `SMOKE_LUA_OK bullets=<n> backend=gdscript`, and
  `SMOKE_BACKEND backend=gdscript ... fallback_warnings=0`. Marker fields are compared exactly, not as substrings.
  The default on web is GDScript with no warning.
* **`native`** (smoke export, `GODOT_CONFIG.args = ["--", "--bullet-backend=native"]`): exactly one fallback warning and
  `fallback_warnings=1`, with bullets still on `gdscript`. Web does not instantiate `NativeBulletSim`.

Every scenario fails on a page error, a console error that is not allowlisted, or a request for any `scriptshot_native` wasm.
The allowlist (`ALLOWLIST` in `web_smoke.py`) holds one entry: lua-gdextension's
`Property not found: 'lua_gdextension/lua_script_language/script_import_map'` warning, which it also prints on desktop.
Artifacts go to `build/web-smoke/<mode>/` and are uploaded as `web-smoke`: `<scenario>.png`, `<scenario>.console.log`,
`<scenario>.requests.log`, `summary-<scenarios>.json`, `check-export-web.txt`, `check-export-web-smoke.txt`, and both
export logs. The job caches the dlink templates (key `...-web-dlink-nothreads`) and Playwright's Chromium.

* Local test with the right headers (stdlib only):
  ```python
  # serve.py: python3 serve.py build/web 8080
  import functools, http.server, sys
  class H(http.server.SimpleHTTPRequestHandler):
      def end_headers(self):
          self.send_header("Cross-Origin-Opener-Policy", "same-origin")
          self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
          super().end_headers()
  H.extensions_map[".wasm"] = "application/wasm"
  http.server.test(HandlerClass=functools.partial(H, directory=sys.argv[1]), port=int(sys.argv[2]))
  ```

## 5. Android

* The CI artifact is a **debug-signed APK** (`Scriptshot-debug.apk`), arm64-v8a only. The job installs JDK 17, the Android SDK packages
  (platform-tools, build-tools 36.1.0, platform android-36) and generates a throwaway debug keystore with `keytool`;
  Godot reads it from `GODOT_ANDROID_KEYSTORE_DEBUG_*`. The SDK/JDK paths go into the headless editor's `editor_settings-4.7.tres`.
* Because the keystore is regenerated on every run, an APK from a different run cannot be installed over an older one
  (signature mismatch): uninstall first.
* Sideload: copy the APK to the phone, open it and allow "Install unknown apps" for the app you opened it from, or
  `adb install -r Scriptshot-debug.apk` (`adb uninstall io.github.karyu42.scriptshot` first if the signature differs).
* **Bullet backend.** Android does not have its own native-bullet path. When `libscriptshot_native` is not in the APK, `BulletManager` stays on the GDScript pool and logs one warning for the run, the same fallback as a desktop build whose library failed to load.
* **Release signing is not set up.** A Play Store or stable-update build needs a release keystore, supplied as repository
  secrets and mapped to `GODOT_ANDROID_KEYSTORE_RELEASE_PATH`, `_USER` and `_PASSWORD` (plus a step that writes the keystore file
  from a base64 secret and an `--export-release` run). Creating and keeping that keystore is Karyu's decision: if it is lost, the app can never be updated.
* Gradle build, x86 and armv7 are intentionally off. `export_presets.cfg` must never contain keystore paths or passwords.

## 6. Toolchain pins

Taken from the Godot 4.7.2-stable tag (`godotengine/godot`) and kept in the `env:` block of `ci.yml`:

| Item | Pin | Upstream source |
|---|---|---|
| Godot | 4.7.2 stable, SHA512-checked | release assets |
| JDK | Temurin 17 | `platform/android/java/app/config.gradle` (`javaVersion`) |
| Android | compileSdk/targetSdk 36, build-tools 36.1.0, minSdk 24 | `config.gradle` |
| Android NDK (native builds only) | 29.0.14206865 | `config.gradle` (`ndkVersion`). Not r28b (`28.1.13356709`); the shared pipeline in `docs/scripting/spike-results.md` section 12 uses Godot's own NDK. |
| godot-cpp (native builds) | `507ed9d840c01a3c5b2a39af8bb4000bfac30bf5` (10.0.0-stable, `api_version` 4.7) | `docs/scripting/spike-results.md` section 12. Not `58d1de7` (lua-gdextension 0.8.2's 10.0.0-rc1, 4.6 API). |
| Python / SCons (native builds) | Python 3.x, SCons 4.10.1 | `.github/actions/godot-deps` |
| Emscripten (Web native builds) | 4.0.20 | The build-container pin of the official 4.7.2 web export templates (a side module must match it). Not the engine workflow's `EM_VERSION` 4.0.11, which is that CI file only. |

Runners for **native library builds** (issue #38, `docs/native.md` "CI"): `ubuntu-24.04` (`Native libs (linux)`,
`Native libs (web)`), `windows-latest` (`GUT (windows, native)`, MSVC) and `macos-latest` (`GUT (macos, native)`,
universal). They run on every PR. Android (NDK pin above, `$ANDROID_HOME/ndk/29.0.14206865`) is a TODO in `ci.yml`
and is not built. An iOS compile check is optional and low priority.

## 7. Export template cache

GitHub publishes one templates tpz (about 1.2 GB). The export job still downloads that archive on a cache miss,
checks its SHA512, and then extracts only the files the five presets need into
`~/.local/share/godot/export_templates/4.7.2.stable` (the directory name is what Godot matches; `version.txt` is
kept so the directory matches an official install):

| Kept | Used by |
|---|---|
| `android_debug.apk`, `android_release.apk` | Android (the matrix exports the debug APK; release is kept for a later signing switch) |
| `macos.zip` | macOS |
| `windows_debug_x86_64.exe`, `windows_release_x86_64.exe` | Windows Desktop, x86_64 |
| `linux_debug.x86_64`, `linux_release.x86_64` | Linux. The archive name uses a dot (`linux_release.x86_64`), not an underscore |
| `web_dlink_nothreads_debug.zip`, `web_dlink_nothreads_release.zip` | Web (`thread_support=false`, `extensions_support=true`) |
| `version.txt` | install marker |

Not cached, on purpose: other CPU architectures, iOS, threaded web, `android_source.zip`, and the no-dlink
`web_nothreads_*.zip` (the Web preset has `extensions_support=true`, so the exporter never opens them). The Windows console
wrappers (`windows_*_x86_64_console.exe`) are also omitted: `debug/export_console_wrapper=1` is "Debug Only"
and the matrix exports Windows as release, so the exporter does not copy a console exe. The cache key ends in
`-slim-dlink`, so neither an older full-template cache nor the earlier `-slim` cache (which had `web_nothreads_*.zip` and no
dlink zips) is restored. The `web-smoke` job keeps its own smaller cache with only `version.txt` and the two dlink zips.

## 8. Native library artifact layout (`bin/<platform>/`)

Only needed if the Lua binding is a GDExtension. Each platform's libraries live in their own folder under the project's `bin/`, so
the native jobs upload `bin/<platform>/` as `native-libs-<platform>` and the export job restores it (download-artifact, same run)
before an export. The `<platform>` ids are the `platform:` values of the export matrix.

```
bin/
  windows.x86_64/    <lib>.windows.template_{debug,release}.x86_64.dll
  macos.universal/   <lib>.macos.template_{debug,release}.universal.dylib
  linux.x86_64/      <lib>.linux.template_{debug,release}.x86_64.so
  web.wasm32/        <lib>.web.template_{debug,release}.wasm32.wasm            (threads)
                     <lib>.web.template_{debug,release}.wasm32.nothreads.wasm  (no threads)
  android.arm64/     <lib>.android.template_{debug,release}.arm64.so
```

The `.gdextension` file maps feature tags to these paths (same tag scheme as lua-gdextension 0.8.2; `threads` selects the threaded wasm):

```ini
[libraries]
windows.release.x86_64 = "res://bin/windows.x86_64/<lib>.windows.template_release.x86_64.dll"
macos.release          = "res://bin/macos.universal/<lib>.macos.template_release.universal.dylib"
linux.release.x86_64   = "res://bin/linux.x86_64/<lib>.linux.template_release.x86_64.so"
web.release.threads.wasm32 = "res://bin/web.wasm32/<lib>.web.template_release.wasm32.wasm"
web.release.wasm32         = "res://bin/web.wasm32/<lib>.web.template_release.wasm32.nothreads.wasm"
android.release.arm64  = "res://bin/android.arm64/<lib>.android.template_release.arm64.so"
# plus the matching *.debug.* entries: the editor, GUT and benchmark runs load the debug libraries
```

The `test` and `perf` jobs only need `bin/linux.x86_64/`. Whether the binaries are committed or fetched in CI (pinned release + SHA256) is open;
a 53 MB zip should not be committed. The macOS dylib is ad-hoc signed by the exporter together with the app.

## 9. Verified locally, and what was not

Checked on this box with Godot 4.7.2 and the official templates, a clean copy of the repo, and the real `export_presets.cfg`: all five exports
succeed (Windows exe 109 MB, Linux 74 MB, Web no-threads 40 MB wasm (before #40; the dlink export is in section 4), Android debug APK 28 MB with arm64-v8a libs only, macOS zip 61 MB
containing a code-signed universal `.app`), with the debug keystore and editor settings generated exactly as the job does. Not verified locally:
Android with build-tools 36.1.0 (the box has 35.0.1), the first-launch steps on real macOS, running the APK on a device, and the `native-libs` job.

## 10. Nightly pre-release and GitHub Pages

After each successful CI **push** to `main` (Import + GUT must have passed, so the export
job has run), `.github/workflows/nightly-pages.yml` replaces the rolling pre-release
tagged `nightly` with unsigned Linux, Windows and web zips, and deploys the same web
tree to GitHub Pages.

* Release: https://github.com/Karyu42/scriptshot/releases/tag/nightly
  Title `Unsigned nightly <sha7>`, body “This is an unsigned nightly pre-release at `<sha>`.”
  Always a pre-release, never Latest. macOS is not included.
* Pages: https://karyu42.github.io/scriptshot/

The workflow verifies the Linux, Windows and web artifacts with
`tools/ci/check_nightly_artifacts.py` before publishing: ready-to-run binaries and
libs are present, and `src/qa/*` (the web smoke scene and the playtest autoplay)
is not packed. A pull request or a `workflow_dispatch` of CI does not publish.
GitHub only runs this `workflow_run` workflow from the default branch, so a
feature branch cannot publish.

Permissions are job-level only: `contents: write` on the release job; `pages: write`
and `id-token: write` on the Pages job. The repository Actions default can stay
“Read repository contents.” Settings → Pages → Source must be GitHub Actions.


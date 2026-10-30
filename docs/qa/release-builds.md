# Release builds

Release targets: **Windows, macOS, Linux, Web and Android (arm64)**. iOS is not a release target.
Everything here is built by the manual `export` job of `.github/workflows/ci.yml`
(Actions > CI > Run workflow > tick `run_export`) from the presets in `export_presets.cfg`.
Nothing is code-signed with a paid identity: macOS is ad-hoc signed only (no Apple developer account),
Windows is unsigned, Android is a debug-signed APK.

## 1. What the job produces

All five exports run on `ubuntu-24.04` with the pinned headless Godot 4.7.2 and its export templates
(checksum-verified, cached). Each artifact is uploaded as `scriptshot-<preset>`.

| Preset | Output (git-ignored `build/`) | Contents | Signing |
|---|---|---|---|
| Windows Desktop | `build/windows/Scriptshot.exe` | single x86_64 exe (`embed_pck=true`) plus a console wrapper if the preset enables it | none (SmartScreen warns on first run) |
| macOS | `build/macos/Scriptshot.zip` | `Scriptshot.app`, universal (x86_64 + arm64) | ad-hoc (`codesign/codesign=1`), not notarized |
| Linux | `build/linux/Scriptshot.x86_64` | single x86_64 executable (`embed_pck=true`) | none |
| Web | `build/web/index.html` + `index.js`, `index.wasm`, `index.pck`, audio worklets, icons (`index.side.wasm` too when `extensions_support` is on) | static site | n/a |
| Android | `build/android/Scriptshot-debug.apk` (+ `.idsig`) | arm64-v8a only, minSdk 24, targetSdk 36 | debug keystore generated in CI |

The macOS and Android exports need **Import ETC2 ASTC** enabled in `project.godot`
(`rendering/textures/vram_compression/import_etc2_astc=true`; already on `main`). Without it Godot refuses to export,
with the message "ETC2/ASTC texture compression is required".

`tools/ci/check_export_preset.py` runs before each export and fails on: any password in the committed
`export_presets.cfg`, committed Android keystore paths, an Android preset that is not arm64-only or uses Gradle,
a macOS preset without ad-hoc signing or with notarization, and an iOS preset. It warns about the Web preset
having `extensions_support` off (needed once the Lua binding is a GDExtension) or threads on (needs COOP/COEP).

## 2. macOS: unsigned first launch

The app is ad-hoc signed and **not notarized**, so Gatekeeper blocks the first launch of a downloaded copy
("Apple cannot check it for malicious software"). Ad-hoc signing is still required: arm64 macOS refuses to
run completely unsigned binaries, so keep `codesign/codesign=1`.

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
  portability. Artifact download strips the executable bit, hence the chmod.

## 4. Web hosting

* Serve the folder as static files over **HTTPS** (or `localhost`) with `.wasm` as `application/wasm`.
* The current Web preset uses the **no-threads** template (`thread_support=false`): no special headers are needed.
* If **threads** are enabled, the page must be cross-origin isolated (otherwise `SharedArrayBuffer` is unavailable and the game does
  not start). Send on the HTML document and all assets:
  `Cross-Origin-Opener-Policy: same-origin` and `Cross-Origin-Embedder-Policy: require-corp` (or `credentialless`).
  The preset option `progressive_web_app/ensure_cross_origin_isolation_headers` can emulate this via a service worker, which needs HTTPS and a
  second load. itch.io has a "SharedArrayBuffer support" checkbox.
* **`variant/extensions_support=true`** is required as soon as any GDExtension (for example the Lua binding) is used. It switches the export to the `web_dlink_*`
  templates and adds `index.side.wasm`. The extension's wasm must match the thread mode: a
  `web.release.threads.wasm32` library for threads, `web.release.wasm32` (no-threads) otherwise. The Lua spike ran both variants on 4.7.2 in a browser.
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
| Android NDK (native builds only) | 29.0.14206865 | `config.gradle` (`ndkVersion`) |
| Python / SCons (native builds) | Python 3.x, SCons 4.10.1 | `.github/actions/godot-deps` |
| Emscripten (Web native builds) | 4.0.11 | `.github/workflows/web_builds.yml` (`EM_VERSION`) |

Runners for **native library builds**: `ubuntu-24.04` (Linux, Web, Android), `windows-latest` (MSVC), `macos-14` (Apple Silicon).
Upstream Godot builds macOS on `macos-26`; this project uses `macos-14`. The disabled `native-libs` job in `ci.yml`
documents this and runs only when the repository variable `ENABLE_NATIVE_LIBS` is `true`. An iOS compile check is optional and low priority:
there is a commented line in the matrix, nothing more.

## 7. Native library artifact layout (`bin/<platform>/`)

Only needed if the Lua binding is a GDExtension. Each platform's libraries live in their own folder under the project's `bin/`, so
the `native-libs` job can upload `bin/<platform>/` as `native-libs-<platform>` and `tools/ci/fetch_native_libs.sh <platform>` can restore it
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

## 8. Verified locally, and what was not

Checked on this box with Godot 4.7.2 and the official templates, a clean copy of the repo, and the real `export_presets.cfg`: all five exports
succeed (Windows exe 109 MB, Linux 74 MB, Web no-threads 40 MB wasm, Android debug APK 28 MB with arm64-v8a libs only, macOS zip 61 MB
containing a code-signed universal `.app`), with the debug keystore and editor settings generated exactly as the job does. Not verified locally:
Android with build-tools 36.1.0 (the box has 35.0.1), the first-launch steps on real macOS, running the APK on a device, and the `native-libs` job.

# allstak_flutter — Android native handler

**Status: SCAFFOLDED, requires device/emulator verification.**

`src/main/kotlin/io/allstak/flutter/AllStakPlugin.kt` implements a standard
Flutter `FlutterPlugin`. It:

- Installs `Thread.setDefaultUncaughtExceptionHandler`.
- Serialises the crash to `SharedPreferences` so it survives process death.
- Exposes a `MethodChannel("io.allstak.flutter/native")` with `install(release)`
  and `drainPendingCrash()` methods.

To wire it up in the host Flutter app, add the AllStak plugin declaration
to this package's `pubspec.yaml` (`flutter: plugin:` block). Dart side
calls `AllStak.instance?.installNativeHandlers()` once at startup.

Verify on an Android emulator/device by forcing a JVM crash from a native
callback (e.g. a `platform-side` channel method that `throw`s) and
re-launching the app.

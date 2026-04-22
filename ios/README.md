# allstak_flutter — iOS native handler

**Status: SCAFFOLDED, requires iOS device/simulator verification.**

`AllStakPlugin.swift` implements the iOS half: `NSSetUncaughtExceptionHandler`
that stashes a DTO-compatible JSON payload in `NSUserDefaults`, then the
same `io.allstak.flutter/native` MethodChannel exposes `install(release)`
and `drainPendingCrash()` to Dart.

To verify, build the containing example app with Flutter's iOS toolchain
(`flutter build ios`), crash it from Obj-C (`@throw`), and re-launch.

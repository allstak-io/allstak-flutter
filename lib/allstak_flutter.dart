/// AllStak SDK for Flutter / Dart.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart' hide runApp;
import 'package:flutter/widgets.dart' as widgets show runApp;
import 'package:http/http.dart' as http;

AllStak? _instance;

/// Thin wrapper so the MethodChannel name lives in one place and can be
/// swapped for tests. Kept private to the library.
class _NativeChannel {
  static const MethodChannel channel =
      MethodChannel('io.allstak.flutter/native');
}

class AllStakConfig {
  final String apiKey;
  final String host;
  final String environment;
  final String release;
  final String service;
  final Map<String, String> tags;
  final bool debug;

  const AllStakConfig({
    required this.apiKey,
    this.host = 'https://api.allstak.sa',
    this.environment = 'production',
    this.release = '',
    this.service = 'flutter',
    this.tags = const {},
    this.debug = false,
  });
}

class AllStak {
  final AllStakConfig config;
  final Map<String, String> _tags = {};
  String? _userId;
  String? _userEmail;

  AllStak._(this.config) {
    _tags.addAll(config.tags);
    _tags['platform'] = 'flutter';
  }

  static AllStak init(AllStakConfig config) {
    final sdk = AllStak._(config);
    _instance = sdk;
    return sdk;
  }

  static AllStak? get instance => _instance;

  /// Install Flutter/Dart error handlers and run the app inside a guarded zone.
  static Future<void> runApp(
    AllStakConfig config,
    Widget Function() appBuilder,
  ) async {
    final sdk = init(config);

    await runZonedGuarded<Future<void>>(() async {
      // Bindings MUST be initialized inside the zone so framework callbacks
      // run in the guarded zone, otherwise Flutter throws "Zone mismatch".
      WidgetsFlutterBinding.ensureInitialized();

      final previousOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        try {
          sdk.captureException(
            details.exceptionAsString(),
            stackTrace: details.stack?.toString() ?? '',
            context: {
              'source': 'FlutterError.onError',
              'library': details.library ?? 'flutter',
            },
          );
        } catch (_) {}
        previousOnError?.call(details);
      };

      PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
        try {
          sdk.captureException(
            error.toString(),
            stackTrace: stack.toString(),
            context: {'source': 'PlatformDispatcher.onError'},
          );
        } catch (_) {}
        return false;
      };

      widgets.runApp(appBuilder());
    }, (error, stack) {
      try {
        sdk.captureException(
          error.toString(),
          stackTrace: stack.toString(),
          context: {'source': 'runZonedGuarded'},
        );
      } catch (_) {}
    });
  }

  void setUser({String? id, String? email}) {
    _userId = id;
    _userEmail = email;
  }

  void setTag(String key, String value) {
    _tags[key] = value;
  }

  void setTags(Map<String, String> tags) {
    _tags.addAll(tags);
  }

  Future<void> captureException(
    Object error, {
    String? stackTrace,
    Map<String, String>? context,
  }) async {
    final className = error is Error
        ? error.runtimeType.toString()
        : error is Exception
            ? error.runtimeType.toString()
            : 'DartError';
    final message = error is String ? error : error.toString();
    final rawStack = stackTrace ??
        (error is Error ? error.stackTrace?.toString() ?? '' : '');
    final stackLines = rawStack
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList();
    // Drain breadcrumbs
    final crumbs = _breadcrumbs.isNotEmpty ? List<Map<String, dynamic>>.from(_breadcrumbs) : null;
    _breadcrumbs.clear();
    await _send('/ingest/v1/errors', {
      'exceptionClass': className,
      'message': message,
      // Backend expects `stackTrace: List<String>`, not a single `stacktrace` string.
      'stackTrace': stackLines,
      'environment': config.environment,
      'release': config.release,
      'level': 'error',
      'user': {
        if (_userId != null) 'id': _userId,
        if (_userEmail != null) 'email': _userEmail,
      },
      'metadata': {..._tags, if (context != null) ...context},
      if (crumbs != null) 'breadcrumbs': crumbs,
    });
  }

  Future<void> captureMessage(String message, {String level = 'info'}) async {
    await _send('/ingest/v1/errors', {
      'exceptionClass': 'Message',
      'message': message,
      'environment': config.environment,
      'release': config.release,
      'level': level,
      'user': {
        if (_userId != null) 'id': _userId,
        if (_userEmail != null) 'email': _userEmail,
      },
      'metadata': Map<String, String>.from(_tags),
    });
  }

  Future<void> captureLog(
    String level,
    String message, {
    Map<String, String>? metadata,
  }) async {
    await _send('/ingest/v1/logs', {
      'level': level,
      'message': message,
      'service': config.service,
      'environment': config.environment,
      'metadata': {..._tags, if (metadata != null) ...metadata},
    });
  }

  // ─── Breadcrumbs ────────────────────────────────────────────────
  final List<Map<String, dynamic>> _breadcrumbs = [];
  static const int _maxBreadcrumbs = 50;

  void addBreadcrumb(
    String type,
    String message, {
    String level = 'info',
    Map<String, dynamic>? data,
  }) {
    _breadcrumbs.add({
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'type': type,
      'message': message,
      'level': level,
      if (data != null) 'data': data,
    });
    if (_breadcrumbs.length > _maxBreadcrumbs) {
      _breadcrumbs.removeAt(0);
    }
  }

  // ─── HTTP request capture ────────────────────────────────────────
  Future<void> captureRequest({
    required String method,
    required String host,
    required String path,
    required int statusCode,
    required int durationMs,
    String direction = 'outbound',
  }) async {
    final traceId = 'flt-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    await _send('/ingest/v1/http-requests', {
      'requests': [
        {
          'traceId': traceId,
          'direction': direction,
          'method': method,
          'host': host,
          'path': path,
          'statusCode': statusCode,
          'durationMs': durationMs,
          'requestSize': 0,
          'responseSize': 0,
          'timestamp': DateTime.now().toUtc().toIso8601String(),
          'environment': config.environment,
          'release': config.release,
        }
      ]
    });
  }

  /// Installs platform-side uncaught exception handlers (Android Kotlin /
  /// iOS Obj-C) and drains any crash stashed by the previous app launch,
  /// shipping it to /ingest/v1/errors.
  ///
  /// SCAFFOLDED: requires the companion Android AllStakPlugin.kt and iOS
  /// AllStakPlugin.swift to be present in the host app's plugin registry,
  /// which is wired up automatically when this package is listed in
  /// pubspec.yaml. Verify on a real Android/iOS device build.
  Future<void> installNativeHandlers() async {
    try {
      const channel = _NativeChannel.channel;
      await channel.invokeMethod('install', {'release': config.release});
      final Object? raw = await channel.invokeMethod('drainPendingCrash');
      if (raw is String && raw.isNotEmpty) {
        try {
          // Payload from native side is already DTO-compatible — ship as-is
          // under the customer's api key.
          await _send('/ingest/v1/errors', _decodeNativeCrash(raw));
        } catch (_) {}
      }
    } catch (_) {
      // channel not available on web or in tests — no-op.
    }
  }

  Map<String, dynamic> _decodeNativeCrash(String json) {
    final decoded = jsonDecode(json);
    if (decoded is Map<String, dynamic>) return decoded;
    return <String, dynamic>{};
  }

  Future<void> flush() async {}

  String _platformTag() {
    try {
      if (kIsWeb) return 'web';
      if (Platform.isAndroid) return 'android';
      if (Platform.isIOS) return 'ios';
      if (Platform.isMacOS) return 'macos';
      if (Platform.isLinux) return 'linux';
      if (Platform.isWindows) return 'windows';
    } catch (_) {}
    return 'flutter';
  }

  Future<void> _send(String path, Map<String, dynamic> payload) async {
    final url = Uri.parse('${config.host}$path');
    final merged = {
      ...payload,
      'metadata': {
        ...((payload['metadata'] as Map?) ?? const {}),
        'device.platform': _platformTag(),
      },
    };
    final body = jsonEncode(merged);
    try {
      final res = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'X-AllStak-Key': config.apiKey,
              'User-Agent': 'allstak-flutter/1.0.0',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 5));
      if (config.debug) {
        final trim = res.body.length > 160 ? res.body.substring(0, 160) : res.body;
        // ignore: avoid_print
        print('[AllStak] POST $path -> ${res.statusCode} $trim');
      }
    } catch (e) {
      if (config.debug) {
        // ignore: avoid_print
        print('[AllStak] POST $path failed: $e');
      }
    }
  }

  /// Returns a [http.Client] that automatically records every outbound
  /// request to AllStak's /ingest/v1/http-requests with direction=outbound.
  ///
  /// Usage:
  /// ```dart
  /// final client = allstak.httpClient();
  /// final resp = await client.get(Uri.parse('https://api.example.com/users'));
  /// // auto-recorded, no extra code needed
  /// ```
  ///
  /// Skips requests to AllStak's own ingest host to prevent recursion.
  http.Client httpClient({http.Client? inner}) {
    return _AllStakHttpClient(this, inner ?? http.Client());
  }
}

/// Wraps any [http.Client] (by default `http.Client()`) so that every outbound
/// HTTP call is captured as an AllStak http-request row, with the real method,
/// host, path, status code, and duration. Errors are captured too with
/// status=0.
class _AllStakHttpClient extends http.BaseClient {
  final AllStak _allstak;
  final http.Client _inner;
  _AllStakHttpClient(this._allstak, this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final url = request.url.toString();
    final isOwnIngest = url.startsWith(_allstak.config.host);
    final sw = Stopwatch()..start();
    try {
      final resp = await _inner.send(request);
      sw.stop();
      if (!isOwnIngest) {
        // fire-and-forget — don't block the caller on ingest
        _allstak.captureRequest(
          method: request.method,
          host: request.url.host + (request.url.hasPort ? ':${request.url.port}' : ''),
          path: request.url.path.isEmpty ? '/' : request.url.path,
          statusCode: resp.statusCode,
          durationMs: sw.elapsedMilliseconds,
          direction: 'outbound',
        );
      }
      return resp;
    } catch (e) {
      sw.stop();
      if (!isOwnIngest) {
        _allstak.captureRequest(
          method: request.method,
          host: request.url.host + (request.url.hasPort ? ':${request.url.port}' : ''),
          path: request.url.path.isEmpty ? '/' : request.url.path,
          statusCode: 0,
          durationMs: sw.elapsedMilliseconds,
          direction: 'outbound',
        );
      }
      rethrow;
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

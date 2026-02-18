import 'dart:async';

import 'package:flutter/foundation.dart';

enum LogLevel { debug, info, warn, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String source; // 'auth' | 'bridge' | 'api' | 'js' | 'app'
  final String message;
  final Map<String, dynamic>? data;

  const LogEntry({
    required this.time,
    required this.level,
    required this.source,
    required this.message,
    this.data,
  });

  String get prefix => switch (level) {
        LogLevel.debug => '·',
        LogLevel.info => '→',
        LogLevel.warn => '⚠',
        LogLevel.error => '✗',
      };

  @override
  String toString() {
    final ts = '${time.hour.toString().padLeft(2, '0')}:'
        '${time.minute.toString().padLeft(2, '0')}:'
        '${time.second.toString().padLeft(2, '0')}.'
        '${(time.millisecond ~/ 10).toString().padLeft(2, '0')}';
    final tag = '[$source]'.padRight(8);
    final base = '$ts $prefix $tag $message';
    if (data == null || data!.isEmpty) return base;
    return '$base  ${_fmtData(data!)}';
  }

  String _fmtData(Map<String, dynamic> d) {
    final parts = d.entries.map((e) {
      final v = e.value?.toString() ?? 'null';
      final truncated = v.length > 80 ? '${v.substring(0, 77)}…' : v;
      return '${e.key}=$truncated';
    });
    return parts.join(' ');
  }
}

/// Central logger for the spike. Broadcasts to the in-app panel and debugPrint.
///
/// Usage:
///   L.info('auth', 'Token exchanged', data: {'expires_in': 3600});
///   L.error('bridge', 'EME keysystem failure', data: {'msg': e.message});
class L {
  static final _controller = StreamController<LogEntry>.broadcast();
  static Stream<LogEntry> get stream => _controller.stream;

  static void debug(String source, String message, {Map<String, dynamic>? data}) =>
      _emit(LogLevel.debug, source, message, data);

  static void info(String source, String message, {Map<String, dynamic>? data}) =>
      _emit(LogLevel.info, source, message, data);

  static void warn(String source, String message, {Map<String, dynamic>? data}) =>
      _emit(LogLevel.warn, source, message, data);

  static void error(String source, String message, {Map<String, dynamic>? data}) =>
      _emit(LogLevel.error, source, message, data);

  static void _emit(LogLevel level, String source, String message, Map<String, dynamic>? data) {
    final entry = LogEntry(time: DateTime.now(), level: level, source: source, message: message, data: data);
    debugPrint(entry.toString());
    if (!_controller.isClosed) _controller.add(entry);
  }

  static void dispose() => _controller.close();
}

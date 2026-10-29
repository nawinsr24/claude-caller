import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_foreground_task/flutter_foreground_task.dart' hide NotificationVisibility;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'config.dart';

/// One incoming call: the ntfy message id is the call id Claude waits on.
class CallInfo {
  const CallInfo({required this.id, required this.title, required this.message});

  final String id;
  final String title;
  final String message;

  Map<String, dynamic> toJson() => {'id': id, 'title': title, 'message': message};

  static CallInfo? fromPayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final m = jsonDecode(payload) as Map<String, dynamic>;
      return CallInfo(id: '${m['id']}', title: '${m['title'] ?? 'Claude is calling'}', message: '${m['message'] ?? ''}');
    } catch (_) {
      return null;
    }
  }

  /// Builds a call from one line of the ntfy JSON stream; null for keepalives/old messages.
  static CallInfo? fromStreamLine(String line, {int maxAgeSeconds = 120, DateTime? now}) {
    if (line.trim().isEmpty) return null;
    final m = jsonDecode(line) as Map<String, dynamic>;
    if (m['event'] != 'message') return null;
    final sent = (m['time'] as num?)?.toInt() ?? 0;
    final nowSec = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    if (nowSec - sent > maxAgeSeconds) return null; // missed while offline: don't ring for stale calls
    return CallInfo(id: '${m['id']}', title: '${m['title'] ?? 'Claude is calling'}', message: '${m['message'] ?? ''}');
  }
}

/// Rings like an incoming call: full-screen, ringtone on repeat, until answered or 60 s pass.
class CallNotifier {
  static final plugin = FlutterLocalNotificationsPlugin();
  static const _callId = 4242;

  static Future<void> init({DidReceiveNotificationResponseCallback? onResponse}) async {
    await plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
      onDidReceiveNotificationResponse: onResponse,
    );
  }

  static Future<void> requestPermissions() async {
    final android = plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestFullScreenIntentPermission();
  }

  static Future<void> ring(CallInfo call) async {
    final details = AndroidNotificationDetails(
      'claude_calls_v1',
      'Incoming calls',
      channelDescription: 'Rings when Claude calls you',
      importance: Importance.max,
      priority: Priority.max,
      category: AndroidNotificationCategory.call,
      fullScreenIntent: true,
      ongoing: true,
      autoCancel: false,
      timeoutAfter: 60000,
      visibility: NotificationVisibility.public,
      audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
      sound: const UriAndroidNotificationSound('content://settings/system/ringtone'),
      additionalFlags: Int32List.fromList(<int>[4]), // FLAG_INSISTENT: keep ringing until answered
      actions: const <AndroidNotificationAction>[
        AndroidNotificationAction('answer', 'Answer', showsUserInterface: true),
        AndroidNotificationAction('decline', 'Decline', showsUserInterface: true, cancelNotification: true),
      ],
    );
    await plugin.show(
      id: _callId,
      title: call.title,
      body: call.message,
      notificationDetails: NotificationDetails(android: details),
      payload: jsonEncode(call.toJson()),
    );
  }

  static Future<void> stopRinging() => plugin.cancel(id: _callId);
}

/// Sends the user's answer back to Claude (MCP `wait_for_reply`).
Future<void> sendReply(String callId, String action, {String text = ''}) async {
  final cfg = await CallerConfig.load();
  if (cfg.replyTopic.isEmpty) return;
  try {
    await http
        .post(cfg.replyUri, headers: {'Title': 'Call $action'},
            body: jsonEncode({'call_id': callId, 'action': action, 'text': text}))
        .timeout(const Duration(seconds: 10));
  } catch (_) {
    // best effort: the call itself already reached the user
  }
}

@pragma('vm:entry-point')
void startListener() {
  FlutterForegroundTask.setTaskHandler(CallListener());
}

/// Background listener (foreground service isolate): keeps an ntfy stream open and rings on each call.
class CallListener extends TaskHandler {
  http.Client? _client;
  bool _stopped = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    await CallNotifier.init();
    unawaited(_listen());
  }

  Future<void> _listen() async {
    var backoff = 2;
    while (!_stopped) {
      try {
        final cfg = await CallerConfig.load();
        if (!cfg.isPaired) {
          await Future<void>.delayed(const Duration(seconds: 30));
          continue;
        }
        final prefs = await SharedPreferences.getInstance();
        final lastId = prefs.getString('last_call_id');
        var uri = cfg.callStreamUri;
        if (lastId != null) uri = uri.replace(queryParameters: {'since': lastId}); // catch calls missed while reconnecting
        _client = http.Client();
        final resp = await _client!.send(http.Request('GET', uri));
        backoff = 2;
        // ntfy sends a keepalive every ~45 s; silence for 2 min means the connection died.
        final lines = resp.stream.transform(utf8.decoder).transform(const LineSplitter())
            .timeout(const Duration(minutes: 2));
        await for (final line in lines) {
          final call = CallInfo.fromStreamLine(line);
          final id = _messageId(line);
          if (id != null) await prefs.setString('last_call_id', id);
          if (call != null) await CallNotifier.ring(call);
        }
      } catch (_) {
        // network drop / timeout: reconnect below
      } finally {
        _client?.close();
      }
      if (_stopped) break;
      await Future<void>.delayed(Duration(seconds: backoff));
      backoff = min(backoff * 2, 60);
    }
  }

  String? _messageId(String line) {
    try {
      final m = jsonDecode(line) as Map<String, dynamic>;
      return m['event'] == 'message' ? '${m['id']}' : null;
    } catch (_) {
      return null;
    }
  }

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    _stopped = true;
    _client?.close();
  }
}

import 'package:shared_preferences/shared_preferences.dart';

/// Where calls come from. Defaults are baked in at build time from GitHub secrets
/// (`--dart-define=CALL_TOPIC=...`), and can be changed in the app's settings.
class CallerConfig {
  CallerConfig({required this.server, required this.callTopic, required this.replyTopic});

  final String server;
  final String callTopic;
  final String replyTopic;

  static const _defaultServer = String.fromEnvironment('NTFY_SERVER', defaultValue: 'https://ntfy.sh');
  static const _defaultCallTopic = String.fromEnvironment('CALL_TOPIC');
  static const _defaultReplyTopic = String.fromEnvironment('REPLY_TOPIC');

  bool get isPaired => server.isNotEmpty && callTopic.isNotEmpty;

  Uri get callStreamUri => Uri.parse('${_trim(server)}/$callTopic/json');
  Uri get replyUri => Uri.parse('${_trim(server)}/$replyTopic');

  static String _trim(String s) => s.endsWith('/') ? s.substring(0, s.length - 1) : s;

  static Future<CallerConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload(); // the listener runs in its own isolate; pick up settings saved by the UI
    return CallerConfig(
      server: prefs.getString('server') ?? _defaultServer,
      callTopic: prefs.getString('call_topic') ?? _defaultCallTopic,
      replyTopic: prefs.getString('reply_topic') ?? _defaultReplyTopic,
    );
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('server', server.trim());
    await prefs.setString('call_topic', callTopic.trim());
    await prefs.setString('reply_topic', replyTopic.trim());
  }
}

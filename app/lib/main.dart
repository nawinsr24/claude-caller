import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'calls.dart';
import 'config.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  await CallNotifier.init(onResponse: _onNotificationResponse);
  final launch = await CallNotifier.plugin.getNotificationAppLaunchDetails();
  final launchCall = (launch?.didNotificationLaunchApp ?? false)
      ? CallInfo.fromPayload(launch!.notificationResponse?.payload)
      : null;
  final declined = launch?.notificationResponse?.actionId == 'decline';
  if (launchCall != null && declined) await sendReply(launchCall.id, 'decline');
  runApp(CallerApp(initialCall: declined ? null : launchCall));
}

/// Notification tapped / Answer / Decline while the app process is alive.
void _onNotificationResponse(NotificationResponse response) {
  final call = CallInfo.fromPayload(response.payload);
  if (call == null) return;
  if (response.actionId == 'decline') {
    CallNotifier.stopRinging();
    sendReply(call.id, 'decline');
    return;
  }
  navigatorKey.currentState?.push(MaterialPageRoute(builder: (_) => CallScreen(call: call)));
}

class CallerApp extends StatelessWidget {
  const CallerApp({super.key, this.initialCall});

  final CallInfo? initialCall;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Claude Caller',
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF7C8CFF), brightness: Brightness.dark, useMaterial3: true),
      home: initialCall != null ? CallScreen(call: initialCall!) : const HomeScreen(),
    );
  }
}

// ----------------------------------------------------------------------------- home

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _server = TextEditingController();
  final _callTopic = TextEditingController();
  final _replyTopic = TextEditingController();
  bool _listening = false;
  bool _showSettings = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cfg = await CallerConfig.load();
    final running = await FlutterForegroundTask.isRunningService;
    if (!mounted) return;
    setState(() {
      _server.text = cfg.server;
      _callTopic.text = cfg.callTopic;
      _replyTopic.text = cfg.replyTopic;
      _listening = running;
      _showSettings = !cfg.isPaired;
    });
  }

  Future<void> _start() async {
    await CallNotifier.requestPermissions();
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'claude_listener',
        channelName: 'Listening for calls',
        channelDescription: 'Keeps Claude Caller ready to ring',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(showNotification: false, playSound: false),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.restartService();
    } else {
      await FlutterForegroundTask.startService(
        serviceId: 7001,
        serviceTypes: [ForegroundServiceTypes.remoteMessaging],
        notificationTitle: 'Claude Caller is ready',
        notificationText: 'Listening for calls',
        callback: startListener,
      );
    }
    _load();
  }

  Future<void> _stop() async {
    await FlutterForegroundTask.stopService();
    _load();
  }

  Future<void> _saveSettings() async {
    await CallerConfig(server: _server.text, callTopic: _callTopic.text, replyTopic: _replyTopic.text).save();
    if (_listening) await FlutterForegroundTask.restartService();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final paired = _callTopic.text.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Claude Caller')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _StatusCard(listening: _listening, paired: paired),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: paired ? (_listening ? _stop : _start) : null,
            icon: Icon(_listening ? Icons.stop_circle_outlined : Icons.phone_in_talk),
            label: Text(_listening ? 'Stop listening' : 'Start listening for calls'),
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => const CallScreen(
                call: CallInfo(id: 'test', title: 'Test call', message: 'This is a test call from Claude Caller.'),
                isTest: true,
              ),
            )),
            icon: const Icon(Icons.record_voice_over),
            label: const Text('Test the call screen and voice'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          ),
          const SizedBox(height: 20),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Connection settings'),
            subtitle: Text(paired ? 'Paired · topic ${_mask(_callTopic.text)}' : 'Not paired yet'),
            trailing: Icon(_showSettings ? Icons.expand_less : Icons.expand_more),
            onTap: () => setState(() => _showSettings = !_showSettings),
          ),
          if (_showSettings) ...[
            TextField(controller: _server, decoration: const InputDecoration(labelText: 'ntfy server')),
            TextField(controller: _callTopic, decoration: const InputDecoration(labelText: 'Call topic')),
            TextField(controller: _replyTopic, decoration: const InputDecoration(labelText: 'Reply topic')),
            const SizedBox(height: 12),
            FilledButton.tonal(onPressed: _saveSettings, child: const Text('Save')),
          ],
        ],
      ),
    );
  }

  String _mask(String t) => t.length <= 10 ? t : '${t.substring(0, 8)}…${t.substring(t.length - 3)}';
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.listening, required this.paired});

  final bool listening;
  final bool paired;

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = !paired
        ? (Icons.link_off, Colors.orange, 'Not paired — open Connection settings')
        : listening
            ? (Icons.check_circle, Colors.greenAccent, 'Ready — Claude can call you')
            : (Icons.pause_circle, Colors.grey, 'Not listening');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(children: [
          Icon(icon, color: color, size: 34),
          const SizedBox(width: 14),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.titleMedium)),
        ]),
      ),
    );
  }
}

// ----------------------------------------------------------------------------- call

/// Shown when a call is answered: reads the message aloud; Repeat / Got it / Decline go back to Claude.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.call, this.isTest = false});

  final CallInfo call;
  final bool isTest;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final _tts = FlutterTts();
  bool _speaking = false;

  @override
  void initState() {
    super.initState();
    CallNotifier.stopRinging();
    _tts.setSpeechRate(0.48);
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _speaking = false);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _speak());
  }

  Future<void> _speak() async {
    setState(() => _speaking = true);
    await _tts.stop();
    await _tts.speak(widget.call.message.isEmpty ? widget.call.title : widget.call.message);
  }

  Future<void> _finish(String action) async {
    await _tts.stop();
    if (!widget.isTest) await sendReply(widget.call.id, action);
    if (!mounted) return;
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    } else {
      SystemNavigator.pop(); // opened straight from the call: close back to where the user was
    }
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
          child: Column(
            children: [
              CircleAvatar(
                radius: 44,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(_speaking ? Icons.graphic_eq : Icons.smart_toy_outlined, size: 44),
              ),
              const SizedBox(height: 16),
              Text(widget.call.title, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
              const SizedBox(height: 6),
              Text(_speaking ? 'Speaking…' : 'Call connected', style: theme.textTheme.bodySmall),
              const SizedBox(height: 28),
              Expanded(
                child: SingleChildScrollView(
                  child: Text(widget.call.message, style: theme.textTheme.headlineSmall, textAlign: TextAlign.center),
                ),
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _RoundButton(icon: Icons.call_end, label: 'Decline', color: Colors.redAccent,
                      onTap: () => _finish('decline')),
                  _RoundButton(icon: Icons.replay, label: 'Repeat', color: theme.colorScheme.secondary, onTap: () {
                    _speak();
                    if (!widget.isTest) sendReply(widget.call.id, 'repeat');
                  }),
                  _RoundButton(icon: Icons.check, label: 'Got it', color: Colors.green, onTap: () => _finish('ack')),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.label, required this.color, required this.onTap});

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Material(
        color: color,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(padding: const EdgeInsets.all(20), child: Icon(icon, size: 30, color: Colors.white)),
        ),
      ),
      const SizedBox(height: 8),
      Text(label),
    ]);
  }
}

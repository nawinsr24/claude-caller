import 'package:claude_caller/calls.dart';
import 'package:claude_caller/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1793300000 * 1000);

  test('a fresh ntfy message becomes a call', () {
    final call = CallInfo.fromStreamLine(
      '{"id":"abc123","time":1793299990,"event":"message","topic":"t","title":"Prod alert","message":"5xx spike on invoice-service"}',
      now: now,
    );
    expect(call, isNotNull);
    expect(call!.id, 'abc123');
    expect(call.title, 'Prod alert');
    expect(call.message, '5xx spike on invoice-service');
  });

  test('keepalives and stale messages do not ring', () {
    expect(CallInfo.fromStreamLine('{"id":"k","time":1793299999,"event":"keepalive","topic":"t"}', now: now), isNull);
    expect(CallInfo.fromStreamLine('{"id":"old","time":1793290000,"event":"message","message":"old"}', now: now), isNull);
    expect(CallInfo.fromStreamLine('   ', now: now), isNull);
  });

  test('notification payload round-trips', () {
    const call = CallInfo(id: 'x1', title: 'Claude is calling', message: 'Build finished');
    final back = CallInfo.fromPayload(
      '{"id":"${call.id}","title":"${call.title}","message":"${call.message}"}',
    );
    expect(back!.message, 'Build finished');
    expect(CallInfo.fromPayload('not json'), isNull);
  });

  test('pairing link fills the connection settings', () {
    final cfg = CallerConfig.fromPairingUri(
      Uri.parse('claudecaller://pair?server=https%3A%2F%2Fntfy.sh&call=cc-call-abc&reply=cc-reply-def'),
    );
    expect(cfg!.server, 'https://ntfy.sh');
    expect(cfg.callTopic, 'cc-call-abc');
    expect(cfg.replyTopic, 'cc-reply-def');
    expect(CallerConfig.fromPairingUri(Uri.parse('https://example.com/pair?call=x')), isNull);
    expect(CallerConfig.fromPairingUri(Uri.parse('claudecaller://pair')), isNull);
  });
}

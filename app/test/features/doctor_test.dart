import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:melsi/features/doctor/verdict.dart';
import 'package:melsi/l10n/l10n.dart';
import 'package:melsi/state/app_state.dart';
import 'package:melsi/state/features.dart';
import 'package:melsi/ui/widgets/page.dart' show SheetClose;

import '../ui/fakes.dart';
import '../ui/harness.dart';

const _ok = StepResult(StepStatus.ok);
const _warn = StepResult(StepStatus.warn);
const _fail = StepResult(StepStatus.fail, 'doctor.timeout');
const _skipped = StepResult(StepStatus.skipped, 'doctor.skipped');

/// Every step ok, with the given overrides.
Map<String, StepResult> _all([Map<String, StepResult> over = const {}]) =>
    {for (final id in Diagnostics.stepIds) id: over[id] ?? _ok};

/// Settings › Инструменты › Диагностика сети, then wait for the sheet.
Future<void> _openDoctor(WidgetTester tester) async {
  await tester.tap(find.text('Настройки'));
  await settle(tester);
  // The tools group sits near the bottom of Settings: laid out but not
  // painted, which the default finder treats as offstage.
  await tester.ensureVisible(find.byKey(const ValueKey('doctor-row'), skipOffstage: false));
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey('doctor-row')));
  await settle(tester);
}

Future<void> _closeSheet(WidgetTester tester) async {
  await tester.tap(find.byType(SheetClose));
  await settle(tester);
}

/// The sheet scrolls on phones: bring [finder] on screen before tapping.
Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
}

/// Text anywhere in the sheet, scrolled out of view or not.
Finder _text(String s) => find.text(s, skipOffstage: false);
Finder _key(String k) => find.byKey(ValueKey(k), skipOffstage: false);

void main() {
  group('diagnose', () {
    test('internet down → offline, whatever else failed', () {
      expect(diagnose(_all({Diagnostics.internetId: _fail, Diagnostics.serverId: _fail})),
          Verdict.offline);
    });

    test('server port silent with internet up → port, with both fixes', () {
      final v = diagnose(_all({Diagnostics.serverId: _fail}));
      expect(v, Verdict.port);
      expect(v.fixes, [DoctorFix.antiDpi, DoctorFix.switchServer]);
    });

    test('core missing → core', () {
      expect(diagnose(_all({Diagnostics.coreId: _fail})), Verdict.core);
    });

    test('tunnel fails while the server answers → tunnel', () {
      expect(diagnose(_all({Diagnostics.tunnelId: _fail})), Verdict.tunnel);
      // The server verdict wins when both fail: the tunnel cannot pass
      // traffic through a port that does not answer.
      expect(diagnose(_all({Diagnostics.serverId: _fail, Diagnostics.tunnelId: _fail})),
          Verdict.port);
    });

    test('dns through the tunnel fails → dns', () {
      expect(diagnose(_all({Diagnostics.dnsId: _fail})), Verdict.dns);
    });

    test('clock skew → clock', () {
      expect(diagnose(_all({Diagnostics.clockId: _fail})), Verdict.clock);
    });

    test('same exit ip → leak', () {
      expect(diagnose(_all({Diagnostics.leakId: _fail})), Verdict.leak);
    });

    test('warnings only → warn; skipped steps do not count', () {
      expect(diagnose(_all({Diagnostics.rulesetsId: _warn})), Verdict.warn);
      expect(diagnose(_all({Diagnostics.tunnelId: _skipped, Diagnostics.dnsId: _skipped})),
          Verdict.ok);
    });

    test('everything ok → ok; incomplete → partial', () {
      expect(diagnose(_all()), Verdict.ok);
      expect(diagnose({}), Verdict.partial);
      expect(diagnose({Diagnostics.internetId: _ok}), Verdict.partial);
      expect(Verdict.ok.healthy, isTrue);
      expect(Verdict.port.healthy, isFalse);
    });
  });

  group('step helpers', () {
    test('clock: |skew| over 90 s fails, under it passes, sign is kept', () {
      final now = DateTime(2026, 10, 1, 12);
      final late = clockResult(now.subtract(const Duration(seconds: 120)), now);
      expect(late.status, StepStatus.fail);
      expect(late.args['n'], '+120');
      final early = clockResult(now.add(const Duration(seconds: 200)), now);
      expect(early.status, StepStatus.fail);
      expect(early.args['n'], '-200');
      final fine = clockResult(now.subtract(const Duration(seconds: 30)), now);
      expect(fine.status, StepStatus.ok);
      expect(fine.mono, isTrue);
      expect(fine.detail, 'unit.sec');
    });

    test('leak: unknown ip warns, same ip fails, different ip passes', () {
      expect(leakResult(null, '1.2.3.4').status, StepStatus.warn);
      expect(leakResult('1.2.3.4', null).status, StepStatus.warn);
      expect(leakResult('1.2.3.4', '1.2.3.4').status, StepStatus.fail);
      expect(leakResult('1.2.3.4', '5.6.7.8').status, StepStatus.ok);
    });
  });

  group('Diagnostics.run', () {
    late AppState state;
    late Features features;
    late Diagnostics doc;

    setUp(() async {
      state = testState();
      await state.load();
      state.settings.locale = 'ru';
      features = testFeatures(state);
      doc = features.doctor;
    });

    tearDown(() {
      features.dispose();
      state.dispose();
    });

    test('runs every step in order, streaming progress', () async {
      await state.importText(kSampleVless);
      doc.probes = DiagProbes.canned({Diagnostics.serverId: _fail});
      final seen = <String?>[];
      doc.addListener(() => seen.add(doc.currentStep));
      await doc.run();
      expect(doc.running, isFalse);
      expect(doc.complete, isTrue);
      expect(doc.finishedAt, isNotNull);
      expect(doc.results.keys, Diagnostics.stepIds);
      expect(doc.results[Diagnostics.serverId]!.isFail, isTrue);
      // Disconnected: the tunnel steps never call their probes.
      for (final id in [Diagnostics.tunnelId, Diagnostics.dnsId, Diagnostics.leakId]) {
        expect(doc.results[id]!.status, StepStatus.skipped, reason: id);
        expect(doc.results[id]!.detail, 'doctor.skipped');
      }
      expect(seen.whereType<String>().toSet(), Diagnostics.stepIds.toSet());
      expect(diagnose(doc.results), Verdict.port);
    });

    test('no server selected → server step skipped, not failed', () async {
      doc.probes = DiagProbes.canned({});
      await doc.run();
      expect(doc.results[Diagnostics.serverId]!.status, StepStatus.skipped);
      expect(doc.results[Diagnostics.serverId]!.detail, 'doctor.noServer');
      expect(diagnose(doc.results), Verdict.ok);
    });

    test('internet failure stops the run; the rest is recorded as not run', () async {
      await state.importText(kSampleVless);
      var serverCalls = 0;
      doc.probes = DiagProbes.canned({Diagnostics.internetId: _fail})
        ..server = (_, _) async {
          serverCalls++;
          return _ok;
        };
      await doc.run();
      expect(serverCalls, 0);
      expect(doc.results.length, Diagnostics.stepIds.length);
      expect(doc.results[Diagnostics.clockId]!.detail, 'doctor.notRun');
      expect(diagnose(doc.results), Verdict.offline);
    });

    test('the server probe gets the chain entry host when the double VPN is on', () async {
      await state.importText(kSampleVless);
      await state.importText(kSampleVless
          .replaceAll('nl1.example.com', 'de1.example.com')
          .replaceAll('Netherlands', 'Germany'));
      final entry = state.nodes.firstWhere((n) => n.server == 'de1.example.com');
      String? host;
      doc.probes = DiagProbes.canned({})
        ..server = (h, p) async {
          host = '$h:$p';
          return _ok;
        };
      await doc.run();
      expect(host, 'nl1.example.com:443');
      state.updateChain((c) => c
        ..enabled = true
        ..entryNodeId = entry.id);
      await doc.run();
      expect(host, 'de1.example.com:443');
    });

    testWidgets('a hung probe fails on its timeout, a throwing probe fails cleanly', (tester) async {
      await state.importText(kSampleVless);
      doc.probes = DiagProbes.canned({})
        ..server = ((_, _) => Completer<StepResult>().future)
        ..core = (() async => throw StateError('boom'));
      final run = doc.run();
      await tester.pump(Diagnostics.stepTimeout + const Duration(milliseconds: 10));
      await run;
      expect(doc.results[Diagnostics.serverId]!.detail, 'doctor.timeout');
      expect(doc.results[Diagnostics.coreId]!.detail, 'doctor.error');
      expect(doc.results.length, Diagnostics.stepIds.length);
    });

    test('cancel drops the step in flight and keeps what came before', () async {
      await state.importText(kSampleVless);
      final gate = Completer<StepResult>();
      doc.probes = DiagProbes.canned({})..server = (_, _) => gate.future;
      final run = doc.run();
      while (doc.currentStep != Diagnostics.serverId) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(doc.running, isTrue);
      doc.cancel();
      expect(doc.running, isFalse);
      expect(doc.currentStep, isNull);
      gate.complete(_ok);
      await run;
      expect(doc.results.keys, [Diagnostics.internetId]);
      expect(doc.complete, isTrue);
      expect(diagnose(doc.results), Verdict.partial);
    });

    test('registers the palette command on load', () async {
      await doc.load();
      final cmd = features.commands.byId('doctor.run');
      expect(cmd, isNotNull);
      expect(cmd!.titleKey, 'doctor.title');
    });
  });

  group('report', () {
    test('lists steps and setup facts but never the host, name or a secret', () async {
      final state = testState();
      await state.load();
      await state.importText(kSampleVless);
      final results = _all({Diagnostics.serverId: _fail, Diagnostics.internetId: StepResult.ms(StepStatus.ok, 23)});
      final text = doctorReport(
        l: const L10n('ru'),
        app: state,
        results: results,
        verdict: diagnose(results),
        appVersion: '1.0.0',
      );
      expect(text, contains('Melsi 1.0.0'));
      expect(text, contains('protocol: VLESS'));
      expect(text, contains('preset: smartRu'));
      expect(text, contains('Интернет: ok · 23 мс'));
      expect(text, contains('Сервер: fail · нет ответа'));
      expect(text, contains('Диагноз: Порт сервера не отвечает'));
      expect(text, isNot(contains('example.com')));
      expect(text, isNot(contains('Netherlands')));
      expect(text, isNot(contains('bf000d23')));
      expect(text, isNot(contains('SbVKOEMjK0s')));
      state.dispose();
    });
  });

  group('DoctorSheet', () {
    testWidgets('server fail → port verdict; the anti-DPI chip flips the setting', (tester) async {
      stubPlatformChannels(tester);
      final (state, f) = await bootApp(tester);
      await state.importText(kSampleVless);
      f.doctor.probes = DiagProbes.canned({Diagnostics.serverId: _fail});
      await _openDoctor(tester);

      expect(find.text('Диагностика сети'), findsWidgets);
      expect(find.textContaining('Порт сервера', skipOffstage: false), findsOneWidget);
      expect(_text('нет ответа'), findsOneWidget);
      expect(_text('пропущено: не подключено'), findsNWidgets(3));
      expect(state.settings.antiDpi, isFalse);

      await _reveal(tester, _text('Включить анти-DPI'));
      await tester.tap(_text('Включить анти-DPI'));
      await settle(tester);
      expect(state.settings.antiDpi, isTrue);
      // Applied fixes are not offered twice.
      expect(_text('Включить анти-DPI'), findsNothing);
      expect(_text('Сменить сервер'), findsOneWidget);

      await _reveal(tester, _key('doctor-copy'));
      await tester.tap(_key('doctor-copy'));
      await settle(tester);
      expect(find.text('Скопировано'), findsOneWidget);

      await _closeSheet(tester);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('connected without a Clash API: tunnel and dns are skipped, no sockets', (tester) async {
      stubPlatformChannels(tester);
      final vpn = FakeVpn();
      final (state, f) = await bootApp(tester, vpn: vpn);
      await state.importText(kSampleVless);
      state.connect();
      await tester.pump(const Duration(milliseconds: 100));
      expect(state.connected, isTrue);
      var leakCalls = 0;
      f.doctor.probes = DiagProbes.canned({
        Diagnostics.tunnelId: const StepResult(StepStatus.skipped, 'doctor.noApi'),
        Diagnostics.dnsId: const StepResult(StepStatus.skipped, 'doctor.noApi'),
      })
        ..leak = () async {
          leakCalls++;
          return const StepResult(StepStatus.ok, 'doctor.leakOk');
        };
      await _openDoctor(tester);

      expect(_text('API ядра недоступен'), findsNWidgets(2));
      expect(_text('IP отличается от реального'), findsOneWidget);
      expect(leakCalls, 1);
      expect(_text('Всё в порядке'), findsOneWidget);

      await _closeSheet(tester);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('run again re-runs; closing mid-run cancels; no leaked frames', (tester) async {
      stubPlatformChannels(tester);
      final (state, f) = await bootApp(tester);
      await state.importText(kSampleVless);
      var runs = 0;
      f.doctor.probes = DiagProbes.canned({})
        ..internet = () async {
          runs++;
          return _ok;
        };
      await _openDoctor(tester);
      expect(runs, 1);
      await _reveal(tester, _key('doctor-again'));
      await tester.tap(_key('doctor-again'));
      await settle(tester);
      expect(runs, 2);
      expect(_text('Всё в порядке'), findsOneWidget);

      // A probe that never answers: closing the sheet cancels the run and
      // the result that arrives later is dropped.
      final gate = Completer<StepResult>();
      f.doctor.probes = DiagProbes.canned({})..server = (_, _) => gate.future;
      await tester.tap(_key('doctor-again'));
      await tester.pump();
      expect(f.doctor.running, isTrue);
      expect(_text('Отмена'), findsOneWidget);
      await _closeSheet(tester);
      expect(f.doctor.running, isFalse);
      gate.complete(_ok);
      await tester.pump();
      expect(f.doctor.results.containsKey(Diagnostics.serverId), isFalse);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('360px phone with reduced motion: nothing overflows, verdict visible', (tester) async {
      stubPlatformChannels(tester);
      reducedMotion(tester);
      final (state, f) = await bootApp(tester, size: const Size(360, 640));
      await state.importText(kSampleVless);
      f.doctor.probes = DiagProbes.canned({Diagnostics.tunnelId: _fail});
      await _openDoctor(tester);
      expect(_text('Скопировать отчёт'), findsOneWidget);
      expect(_text('Повторить'), findsOneWidget);
      // Disconnected, so a canned tunnel failure never reaches the verdict.
      expect(_text('Всё в порядке'), findsOneWidget);
      await _reveal(tester, _key('doctor-again'));
      expect(find.text('Повторить'), findsOneWidget);
      await _closeSheet(tester);
      await shutdownApp(tester, state, features: f);
    });

    testWidgets('wide layout opens the doctor as a dialog', (tester) async {
      stubPlatformChannels(tester);
      final (state, f) = await bootApp(tester, size: const Size(1280, 800));
      await state.importText(kSampleVless);
      f.doctor.probes = DiagProbes.canned({Diagnostics.clockId: _fail});
      await _openDoctor(tester);
      expect(find.byType(Dialog), findsOneWidget);
      expect(find.text('Проверьте время на устройстве'), findsOneWidget);
      await _closeSheet(tester);
      expect(find.byType(Dialog), findsNothing);
      await shutdownApp(tester, state, features: f);
    });
  });
}

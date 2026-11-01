import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/features/settings/overview/sections/routing_options_page.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The rules file lives in [dir], as in the app's base directory.
class _Directories extends AppDirectories {
  _Directories(this.dir);

  final Directory dir;

  @override
  Future<Directories> build() async => (baseDir: dir, workingDir: dir, tempDir: dir);
}

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('builtin_rules_test');
    file = File('${dir.path}/route_rule.proto');
  });
  tearDown(() async {
    for (var attempt = 0; ; attempt++) {
      try {
        return dir.deleteSync(recursive: true);
      } on FileSystemException {
        if (attempt == 50) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  });

  Future<ProviderContainer> open() async {
    SharedPreferences.setMockInitialValues({});
    final container = ProviderContainer(
      overrides: [
        appDirectoriesProvider.overrideWith(() => _Directories(dir)),
        translationsProvider.overrideWith((ref) => AppLocale.en.build()),
      ],
    );
    addTearDown(container.dispose);
    await container.read(appDirectoriesProvider.future);
    await container.read(sharedPreferencesProvider.future);
    await container.read(translationsProvider.future);
    container.listen(rulesNotifierProvider, (_, _) {});
    return container;
  }

  void save(List<Rule> rules) {
    for (final (index, rule) in rules.indexed) {
      rule.listOrder = index;
    }
    file.writeAsBytesSync(RouteRule(rules: rules).writeToBuffer());
  }

  Rule custom(String name, {bool enabled = true}) =>
      Rule(name: name, enabled: enabled, outbound: Outbound.proxy, domains: ['$name.example']);

  Rule builtin(BuiltinRule builtin, {required bool enabled}) => builtin.rule()..enabled = enabled;

  List<String> describe(List<Rule> rules) => [for (final rule in rules) '${rule.name} ${rule.enabled ? 'on' : 'off'}'];

  List<String> current(ProviderContainer container) => describe(container.read(rulesNotifierProvider));

  const defaults = ['builtin:bypassLan on', 'builtin:blockAds off'];

  test('a new list holds the built-in rules in their default order and state', () async {
    final container = await open();
    expect(current(container), defaults);
    expect(file.existsSync(), isFalse);
  });

  test('a saved list keeps its order and switches, and its content comes from the app', () async {
    save([
      custom('a'),
      builtin(BuiltinRule.blockAds, enabled: true),
      builtin(BuiltinRule.bypassLan, enabled: false),
      Rule(name: 'builtin:blockAds', outbound: Outbound.direct, domains: ['example.com']),
    ]);
    final container = await open();
    expect(current(container), ['a on', 'builtin:blockAds on', 'builtin:bypassLan off']);
    for (final rule in container.read(rulesNotifierProvider)) {
      if (BuiltinRule.of(rule) case final builtin?) {
        expect(rule.outbound, builtin.rule().outbound, reason: rule.name);
      }
    }
  });

  test('the removed geo region rule is dropped, not kept as a custom rule', () async {
    save([
      custom('a'),
      Rule(name: 'builtin:bypassRegion', enabled: true, outbound: Outbound.direct, domains: ['ru']),
      Rule(name: 'builtin:bypassRegion:ip', enabled: true, outbound: Outbound.direct, ipCidrs: ['0.0.0.0/0']),
      builtin(BuiltinRule.bypassLan, enabled: true),
      builtin(BuiltinRule.blockAds, enabled: false),
    ]);
    final container = await open();
    expect(current(container), ['a on', 'builtin:bypassLan on', 'builtin:blockAds off']);
    expect(current(container).join('\n'), isNot(contains('bypassRegion')));
  });

  test('a saved list gets the built-in rules it lacks first', () async {
    save([custom('a'), builtin(BuiltinRule.blockAds, enabled: true)]);
    final container = await open();
    expect(current(container), ['builtin:bypassLan on', 'a on', 'builtin:blockAds on']);
  });

  test('the user switches and moves a built-in rule, and the list keeps it', () async {
    final container = await open();
    final notifier = container.read(rulesNotifierProvider.notifier);
    await notifier.updateEnabled(true, 1);
    await notifier.reorder(1, 0);
    const expected = ['builtin:blockAds on', 'builtin:bypassLan on'];
    expect(current(container), expected);
    expect(current(await open()), expected);
  });

  test('reset returns the default list', () async {
    save([
      custom('a'),
      builtin(BuiltinRule.blockAds, enabled: true),
      builtin(BuiltinRule.bypassLan, enabled: false),
    ]);
    final container = await open();
    await container.read(rulesNotifierProvider.notifier).resetRules();
    expect(current(container), defaults);
  });

  testWidgets('the routing page shows the built-in rules', (tester) async {
    final container = (await tester.runAsync(open))!;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: RoutingOptionsPage(routeRule: null)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Built-in'), findsNWidgets(2));
    expect(find.text('Bypass LAN'), findsOneWidget);
    expect(find.text('Block ads and malware'), findsOneWidget);
  });
}

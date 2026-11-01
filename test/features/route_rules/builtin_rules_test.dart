import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/directories/directories_provider.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/directories.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/route_rules/notifier/rules_notifier.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
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
    // a save the page started may still hold the file open
    for (var attempt = 0; ; attempt++) {
      try {
        return dir.deleteSync(recursive: true);
      } on FileSystemException {
        if (attempt == 50) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }
  });

  /// The app's providers with [region] saved. The rules stay alive, as the config options keep them in the app.
  Future<ProviderContainer> open({Region region = Region.ir}) async {
    SharedPreferences.setMockInitialValues({'region': region.name});
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

  Rule builtin(BuiltinRule builtin, {required bool enabled}) => builtin.rule(Region.ir)..enabled = enabled;

  /// Each rule as its name and switch, such as "builtin:bypassLan on".
  List<String> describe(List<Rule> rules) => [for (final rule in rules) '${rule.name} ${rule.enabled ? 'on' : 'off'}'];

  List<String> current(ProviderContainer container) {
    final rules = container.read(rulesNotifierProvider);
    expect([for (final rule in rules) rule.listOrder], List.generate(rules.length, (index) => index));
    return describe(rules);
  }

  void expectSaved(ProviderContainer container) =>
      expect(file.readAsBytesSync(), RouteRule(rules: container.read(rulesNotifierProvider)).writeToBuffer());

  /// The notifier saves the list after a region change without being awaited, so this waits for that save.
  Future<void> changeRegion(ProviderContainer container, Region region) async {
    if (file.existsSync()) file.setLastModifiedSync(DateTime(2000));
    await container.read(ConfigOptions.region.notifier).update(region);
    final expected = RouteRule(rules: container.read(rulesNotifierProvider)).writeToBuffer();
    for (var i = 0; i < 200; i++) {
      if (file.existsSync() && file.lastModifiedSync().year > 2000 && listEquals(file.readAsBytesSync(), expected)) {
        // the content is in; give the write time to close the file
        return Future<void>.delayed(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('the list was not saved after the region change');
  }

  const defaults = ['builtin:bypassLan on', 'builtin:blockAds off', 'builtin:bypassRegion on'];

  group('a new list', () {
    test('holds the built-in rules in their default order and state', () async {
      final container = await open();
      expect(current(container), defaults);
      expect(file.existsSync(), isFalse);
    });

    test('keeps the Russian sites rule even when the region is Other', () async {
      final container = await open(region: Region.other);
      expect(current(container), defaults);
    });
  });

  group('a saved list', () {
    test('keeps its order and switches', () async {
      save([
        custom('a'),
        builtin(BuiltinRule.bypassRegion, enabled: false),
        builtin(BuiltinRule.bypassLan, enabled: false),
        custom('b', enabled: false),
        builtin(BuiltinRule.blockAds, enabled: true),
      ]);
      final container = await open();
      expect(current(container), [
        'a on',
        'builtin:bypassRegion off',
        'builtin:bypassLan off',
        'b off',
        'builtin:blockAds on',
      ]);
    });

    test("takes each built-in rule's content from the app", () async {
      save([
        Rule(name: 'builtin:bypassLan', enabled: true, outbound: Outbound.proxy, ipCidrs: ['1.2.3.4/32']),
        Rule(name: 'builtin:blockAds', enabled: true, outbound: Outbound.direct, domains: ['example.com']),
        Rule(name: 'builtin:bypassRegion', outbound: Outbound.block, ruleSets: ['https://example.com/x.srs']),
      ]);
      final container = await open();
      for (final rule in container.read(rulesNotifierProvider)) {
        final expected = BuiltinRule.of(rule)!.rule(Region.ir)
          ..enabled = rule.enabled
          ..listOrder = rule.listOrder;
        expect(rule, expected, reason: rule.name);
      }
      expect(current(container), ['builtin:bypassLan on', 'builtin:blockAds on', 'builtin:bypassRegion off']);
    });

    test('gets the built-in rules it lacks first, in their default state', () async {
      save([custom('a'), builtin(BuiltinRule.blockAds, enabled: true)]);
      final container = await open();
      expect(current(container), ['builtin:bypassLan on', 'builtin:bypassRegion on', 'a on', 'builtin:blockAds on']);
    });

    test('keeps a built-in rule saved twice once, at its first place', () async {
      save([
        builtin(BuiltinRule.blockAds, enabled: true),
        custom('a'),
        builtin(BuiltinRule.blockAds, enabled: false),
        builtin(BuiltinRule.bypassLan, enabled: true),
        builtin(BuiltinRule.bypassRegion, enabled: true),
      ]);
      final container = await open();
      expect(current(container), ['builtin:blockAds on', 'a on', 'builtin:bypassLan on', 'builtin:bypassRegion on']);
    });

    test('keeps the Russian sites rule while the region is Other', () async {
      save([
        custom('a'),
        builtin(BuiltinRule.bypassRegion, enabled: true),
        builtin(BuiltinRule.bypassLan, enabled: true),
        builtin(BuiltinRule.blockAds, enabled: false),
      ]);
      final container = await open(region: Region.other);
      expect(current(container), ['a on', 'builtin:bypassRegion on', 'builtin:bypassLan on', 'builtin:blockAds off']);
    });
  });

  group('a region change', () {
    Future<ProviderContainer> openSaved() {
      save([
        custom('a'),
        builtin(BuiltinRule.bypassRegion, enabled: false),
        builtin(BuiltinRule.bypassLan, enabled: true),
        builtin(BuiltinRule.blockAds, enabled: false),
      ]);
      return open();
    }

    test('keeps the Russian rule and its switch whatever the region is', () async {
      final container = await openSaved();

      await changeRegion(container, Region.other);
      expect(current(container), ['a on', 'builtin:bypassRegion off', 'builtin:bypassLan on', 'builtin:blockAds off']);

      await changeRegion(container, Region.cn);
      expect(current(container), ['a on', 'builtin:bypassRegion off', 'builtin:bypassLan on', 'builtin:blockAds off']);
    });

    test("between regions keeps the region rule's place and switch", () async {
      final container = await openSaved();
      await changeRegion(container, Region.cn);
      expect(current(container), ['a on', 'builtin:bypassRegion off', 'builtin:bypassLan on', 'builtin:blockAds off']);
    });

    test('on a list never saved keeps the default order', () async {
      final container = await open(region: Region.other);
      await changeRegion(container, Region.ir);
      expect(current(container), defaults);
    });
  });

  group('the user', () {
    test('adds a new rule first, turned on', () async {
      final container = await open();
      await container
          .read(rulesNotifierProvider.notifier)
          .addRule(Rule(name: 'new', outbound: Outbound.direct, domains: ['new.example']));
      expect(current(container), ['new on', ...defaults]);
      expectSaved(container);
    });

    test("switches and moves a built-in rule, and the list keeps it", () async {
      final container = await open();
      final notifier = container.read(rulesNotifierProvider.notifier);
      await notifier.updateEnabled(true, 1);
      await notifier.reorder(1, 0);
      final expected = ['builtin:blockAds on', 'builtin:bypassLan on', 'builtin:bypassRegion on'];
      expect(current(container), expected);

      expect(current(await open()), expected);
    });

    test('resets to the default list', () async {
      save([
        custom('a'),
        builtin(BuiltinRule.blockAds, enabled: true),
        builtin(BuiltinRule.bypassRegion, enabled: false),
        builtin(BuiltinRule.bypassLan, enabled: false),
      ]);
      final container = await open();
      await container.read(rulesNotifierProvider.notifier).resetRules();
      expect(current(container), defaults);

      expect(current(await open()), defaults);
    });

    test('imports a list, which gets the built-in rules with their app content', () async {
      final container = await open();
      final imported = RouteRule(
        rules: [
          custom('a'),
          Rule(
            name: 'builtin:blockAds',
            enabled: true,
            outbound: Outbound.proxy,
            ruleSets: ['https://example.com/x.srs'],
          ),
        ],
      );
      await container
          .read(rulesNotifierProvider.notifier)
          .importRules(base64.encode(utf8.encode(jsonEncode(imported.writeToJson()))));
      expect(current(container), ['builtin:bypassLan on', 'builtin:bypassRegion on', 'a on', 'builtin:blockAds on']);
      final blockAds = container.read(rulesNotifierProvider).last;
      expect(blockAds.outbound, Outbound.block);
      expect(blockAds.ruleSets, BuiltinRule.blockAds.rule(Region.ir).ruleSets);
      expectSaved(container);
    });
  });

  test('the core gets each built-in rule in the shape it reads', () async {
    final container = await open();
    final json = RouteRule(rules: container.read(rulesNotifierProvider)).toProto3Json()! as Map<String, dynamic>;
    const geo = 'https://raw.githubusercontent.com/hiddify/hiddify-geo/rule-set';
    final rules = (json['rules'] as List).cast<Map<String, dynamic>>();

    expect(rules[0]['name'], 'builtin:bypassLan');
    expect(rules[0]['outbound'], 'direct');
    expect(rules[0]['ip_cidr'], contains('10.0.0.0/8'));

    expect(rules[1]['name'], 'builtin:blockAds');
    expect(rules[1]['outbound'], 'block');
    expect(rules[1]['rule_set'], contains('$geo/block/geosite-category-ads-all.srs'));

    // The Russian sites rule is inline and offline: no rule-set URL for the core to fetch.
    final russian = rules[2];
    expect(russian['name'], 'builtin:bypassRegion');
    expect(russian['outbound'], 'direct');
    expect(russian.containsKey('rule_set'), isFalse);
    expect(russian['domain_suffix'] as List, contains('ru'));
  });

  group('the routing page', () {
    Future<ProviderContainer> show(WidgetTester tester) async {
      final container = (await tester.runAsync(open))!;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: RoutingOptionsPage(routeRule: null)),
        ),
      );
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('marks each built-in rule and names the region rule after the region', (tester) async {
      await show(tester);
      expect(find.text('Built-in'), findsNWidgets(3));
      expect(find.byIcon(Icons.lock_outline_rounded), findsNWidgets(3));
      expect(find.text('Bypass LAN'), findsOneWidget);
      expect(find.text('Block ads and malware'), findsOneWidget);
      expect(find.text('Russian sites — direct'), findsOneWidget);
    });

    testWidgets('opens nothing on a tap or long press of a built-in rule', (tester) async {
      await show(tester);
      // without a router, an edit page or a delete dialog would throw
      await tester.tap(find.text('Bypass LAN'));
      await tester.longPress(find.text('Block ads and malware'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets("switches a built-in rule from its row's switch", (tester) async {
      final container = await show(tester);
      final row = find.ancestor(of: find.text('Russian sites — direct'), matching: find.byType(ListTile));
      await tester.tap(find.descendant(of: row, matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(container.read(rulesNotifierProvider).last.enabled, isFalse);
    });

    testWidgets('keeps the Russian sites rule whatever the region chip says', (tester) async {
      await show(tester);

      await tester.tap(find.text('Region'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Other').last);
      await tester.pumpAndSettle();
      expect(find.text('Russian sites — direct'), findsOneWidget);
      expect(find.text('Built-in'), findsNWidgets(3));

      await tester.tap(find.text('Region'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('China').last);
      await tester.pumpAndSettle();
      expect(find.text('Russian sites — direct'), findsOneWidget);
      expect(find.text('Built-in'), findsNWidgets(3));
    });
  });
}

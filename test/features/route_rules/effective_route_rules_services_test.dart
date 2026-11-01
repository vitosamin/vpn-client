import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/route_rules/data/bundled_service_rules.dart';
import 'package:hiddify/features/route_rules/data/effective_route_rules.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';

Rule _ru() => Rule(
  name: "builtin:bypassRegion",
  enabled: true,
  outbound: Outbound.direct,
  domains: ["ya.ru"],
);

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await BundledServiceRules.load();
  });

  test("the split preset goes after the app rules: services via VPN, everything else direct", () {
    final rules = effectiveRouteRules([_ru()], servicesOnly: true);
    final names = [for (final rule in rules) rule.name];

    expect(names.first, "builtin:bypassRegion");
    expect(names, contains("preset:svc:youtube"));
    expect(names, contains("preset:svc:telegram"));
    // the catch-alls are last, so every service rule wins first
    expect(names.sublist(names.length - 2), ["preset:direct-names", "preset:direct-ip"]);
    expect([for (final rule in rules) rule.listOrder], [for (var i = 0; i < rules.length; i++) i]);

    final youtube = rules.firstWhere((rule) => rule.name == "preset:svc:youtube");
    expect(youtube.outbound, Outbound.proxy);
    expect(youtube.domains, contains("youtube.com"));
    expect(youtube.domainSuffixes, contains("googlevideo.com"));

    final directNames = rules.firstWhere((rule) => rule.name == "preset:direct-names");
    expect(directNames.outbound, Outbound.direct);
    expect(directNames.domainRegexes, [".*"]);

    final directIp = rules.firstWhere((rule) => rule.name == "preset:direct-ip");
    expect(directIp.outbound, Outbound.direct);
    expect(directIp.ipCidrs, containsAll(["0.0.0.0/0", "::/0"]));
  });

  test("with the split off the preset is not added at all", () {
    final rules = effectiveRouteRules([_ru()]);
    expect([for (final rule in rules) rule.name], ["builtin:bypassRegion"]);
  });

  test("the bundled services are the router preset, with its own lists", () {
    final tags = [for (final rule in BundledServiceRules.rules) rule.name];
    expect(tags, contains("preset:svc:blocked"));
    expect(tags, contains("preset:svc:cloudflare"));
    expect(tags, contains("preset:svc:ai"));

    final blocked = BundledServiceRules.rules.firstWhere((rule) => rule.name == "preset:svc:blocked");
    expect(blocked.domains, contains("rutor.is"));
    expect(blocked.outbound, Outbound.proxy);

    final cloudflare = BundledServiceRules.rules.firstWhere((rule) => rule.name == "preset:svc:cloudflare");
    expect(cloudflare.ipCidrs, contains("131.0.72.0/22"));

    final telegram = BundledServiceRules.rules.firstWhere((rule) => rule.name == "preset:svc:telegram");
    expect(telegram.ipCidrs, contains("149.154.160.0/20"));
  });
}

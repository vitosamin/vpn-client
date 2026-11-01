import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:hiddify/hiddifycore/generated/v2/config/route_rule.pb.dart';

/// The services that go through the VPN while everything else goes direct, taken from the
/// router's Vitosamin preset: the geo categories of the panel's `vitosamin-full.json` plus the
/// owner's own lists (YouTube, Cloudflare, the blocked trackers, AI services).
///
/// The lists are bundled as ordinary domains, suffixes and CIDRs, so the core needs no network
/// and no GitHub: each service becomes a plain sing-box rule in the config the app builds.
class BundledServiceRules {
  const BundledServiceRules._();

  /// One rule per service, in the preset's order; empty until [load] ran.
  static List<Rule> rules = const [];

  static const _asset = 'assets/routing/services.json';

  static Future<void> load({AssetBundle? bundle}) async {
    final raw = await (bundle ?? rootBundle).loadString(_asset);
    final data = jsonDecode(raw) as Map<String, dynamic>;
    rules = [
      for (final item in (data["services"] as List).cast<Map<String, dynamic>>())
        Rule(
          name: "preset:svc:${item["tag"]}",
          enabled: true,
          outbound: Outbound.proxy,
          domains: (item["domains"] as List).cast<String>(),
          domainSuffixes: (item["suffixes"] as List).cast<String>(),
          ipCidrs: (item["cidrs"] as List).cast<String>(),
        ),
    ];
  }
}

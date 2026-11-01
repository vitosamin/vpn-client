import 'package:flutter/services.dart';

/// The country lists that ship inside the app, flattened from the hiddify-geo rule-sets by
/// `scripts/update-geo-rules.sh` (see `assets/geo/README.md`).
///
/// The region rule for Russia is built from them instead of a remote rule-set URL: the lists are
/// already in the app, nothing is downloaded and GitHub is not needed, so RU sites take the direct
/// outbound from the first connect. They end up as ordinary conditions of a sing-box rule
/// (domains, domain suffixes and IP ranges), not as a rule-set the core would fetch.
class BundledGeoRules {
  const BundledGeoRules({
    required this.domains,
    required this.domainSuffixes,
    required this.ipCidrs,
    required this.extraSuffixes,
  });

  /// What the rule has before [load] ran, or when loading failed: nothing at all.
  static const empty = BundledGeoRules(domains: [], domainSuffixes: [], ipCidrs: [], extraSuffixes: []);

  /// The lists loaded at startup, see `lazyBootstrap`. A blank instance means the region rule has
  /// to fall back to a remote rule-set (the app has no local data to build it from).
  static BundledGeoRules instance = empty;

  final List<String> domains;
  final List<String> domainSuffixes;
  final List<String> ipCidrs;

  /// Curated Russian services on non-`.ru` domains (see `assets/geo/ru_extra.txt`), matched as
  /// suffixes too: the country list does not carry every one of them.
  final List<String> extraSuffixes;

  bool get isEmpty => domains.isEmpty && domainSuffixes.isEmpty && ipCidrs.isEmpty && extraSuffixes.isEmpty;

  static const _assetDirectory = 'assets/geo';
  static const _domainsAsset = '$_assetDirectory/ru_domain.txt';
  static const _domainSuffixesAsset = '$_assetDirectory/ru_domain_suffix.txt';
  static const _ipCidrsAsset = '$_assetDirectory/ru_ip_cidr.txt';
  static const _extraAsset = '$_assetDirectory/ru_extra.txt';

  /// Reads the files into [instance], one list item per line, and returns them.
  ///
  /// Assets are plain text and loaded as such: 25 thousand prefixes read faster line by line than
  /// as a JSON array, and the files stay reviewable in a diff.
  static Future<BundledGeoRules> load({AssetBundle? bundle}) async {
    final assets = bundle ?? rootBundle;
    final contents = await Future.wait([
      assets.loadString(_domainsAsset),
      assets.loadString(_domainSuffixesAsset),
      assets.loadString(_ipCidrsAsset),
      assets.loadString(_extraAsset),
    ]);
    final rules = BundledGeoRules(
      domains: _parse(contents[0]),
      domainSuffixes: _parse(contents[1]),
      ipCidrs: _parse(contents[2]),
      extraSuffixes: _parse(contents[3]),
    );
    instance = rules;
    return rules;
  }

  static List<String> _parse(String content) => [
    for (final line in content.split('\n'))
      if (line.isNotEmpty) line,
  ];
}

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/app_update/data/github_release_parser.dart';

Map<String, dynamic> _release({List<Map<String, dynamic>>? assets}) => {
  "tag_name": "v1.0.2",
  "prerelease": false,
  "published_at": "2026-11-01T00:00:00Z",
  "html_url": "https://github.com/vitosamin/vpn-client/releases/tag/v1.0.2",
  "assets": assets,
};

Map<String, dynamic> _asset(String name) => {
  "name": name,
  "browser_download_url": "https://example.test/download/$name",
};

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group("version", () {
    test("reads the version out of the tag", () {
      final version = GithubReleaseParser.parse(_release());
      expect(version.version, "1.0.2");
      expect(version.releaseTag, "v1.0.2");
      expect(version.preRelease, isFalse);
      expect(version.flavor.name, "prod");
    });
  });

  group("download url on a phone", () {
    test("prefers the universal APK of the release", () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final version = GithubReleaseParser.parse(
        _release(assets: [_asset("vitosamin-1.0.2-release-arm64.apk"), _asset("vitosamin-1.0.2-release.apk")]),
      );
      expect(version.url, "https://example.test/download/vitosamin-1.0.2-release.apk");
    });

    test("falls back to the arm64 APK, then to the release page", () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var version = GithubReleaseParser.parse(_release(assets: [_asset("vitosamin-1.0.2-release-arm64.apk")]));
      expect(version.url, "https://example.test/download/vitosamin-1.0.2-release-arm64.apk");

      version = GithubReleaseParser.parse(_release(assets: [_asset("SHA256SUMS.txt")]));
      expect(version.url, "https://github.com/vitosamin/vpn-client/releases/tag/v1.0.2");
    });

    test("keeps the release page on desktop", () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final version = GithubReleaseParser.parse(_release(assets: [_asset("vitosamin-1.0.2-release.apk")]));
      expect(version.url, "https://github.com/vitosamin/vpn-client/releases/tag/v1.0.2");
    });
  });
}

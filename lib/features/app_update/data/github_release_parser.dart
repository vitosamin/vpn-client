import 'package:dartx/dartx.dart';
import 'package:flutter/foundation.dart';
import 'package:hiddify/core/model/environment.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';

abstract class GithubReleaseParser {
  static RemoteVersionEntity parse(Map<String, dynamic> json) {
    final fullTag = json['tag_name'] as String;
    final fullVersion = fullTag.removePrefix("v").split("-").first.split("+");
    var version = fullVersion.first;
    var buildNumber = fullVersion.elementAtOrElse(1, (index) => "");
    var flavor = Environment.prod;
    for (final env in Environment.values) {
      final suffix = ".${env.name}";
      if (version.endsWith(suffix)) {
        version = version.removeSuffix(suffix);
        flavor = env;
        break;
      } else if (buildNumber.endsWith(suffix)) {
        buildNumber = buildNumber.removeSuffix(suffix);
        flavor = env;
        break;
      }
    }
    final preRelease = json["prerelease"] as bool;
    final publishedAt = DateTime.parse(json["published_at"] as String);
    // On a phone "Update now" should download the APK, not open a page to scroll: take the
    // universal APK of the release when it is there, otherwise its arm64 build, otherwise the
    // release page. Other platforms keep the page, they do not install an APK.
    final assets = (json["assets"] as List?)?.whereType<Map<String, dynamic>>() ?? const [];
    String? universal;
    String? generic;
    String? arm64;
    for (final asset in assets) {
      final name = (asset["name"] as String? ?? "").toLowerCase();
      if (!name.endsWith(".apk")) continue;
      final url = asset["browser_download_url"] as String?;
      if (url == null) continue;
      if (name.contains("universal")) {
        universal ??= url;
      } else if (name.contains("arm64")) {
        arm64 ??= url;
      } else {
        generic ??= url;
      }
    }
    final apkUrl = universal ?? generic ?? arm64;
    final url = defaultTargetPlatform == TargetPlatform.android && apkUrl != null ? apkUrl : json["html_url"] as String;
    return RemoteVersionEntity(
      version: version,
      buildNumber: buildNumber,
      releaseTag: fullTag,
      preRelease: preRelease,
      url: url,
      publishedAt: publishedAt,
      flavor: flavor,
    );
  }
}

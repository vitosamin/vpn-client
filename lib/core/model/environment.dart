import 'package:dartx/dartx.dart';

enum Environment {
  prod,
  dev;

  static const sentryDSN = String.fromEnvironment("sentry_dsn");
  // This environment variable is set in the 'windows-release-zip' command
  static const isPortable = bool.fromEnvironment("portable");
}

enum Release {
  general("general"),
  // This environment variable is set in the 'android-release-aab' command
  googlePlay("google-play"),
  // This environment variable is set in the Mac App Store build (macos/scripts/dist.sh app-store)
  appStore("app-store");

  const Release(this.key);

  final String key;

  /// The fork has its own update channel: GitHub Releases of the Vitosamin repository
  /// (`Constants.githubReleasesApiUrl`). The app checks it on start and from About, and the
  /// release asset is a signed APK, so a phone updates without a store.
  bool get allowCustomUpdateChecker => true;

  static Release read() =>
      Release.values.firstOrNullWhere((e) => e.key == const String.fromEnvironment("release")) ?? Release.general;
}

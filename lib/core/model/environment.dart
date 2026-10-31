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

  /// Our fork has no update channel of its own, and the upstream appcast/github feeds would
  /// offer Hiddify releases (a newer version number and a different app). Off for every
  /// release until `Constants.appCastUrl`/`githubReleasesApiUrl` point at our own builds.
  bool get allowCustomUpdateChecker => false;

  static Release read() =>
      Release.values.firstOrNullWhere((e) => e.key == const String.fromEnvironment("release")) ?? Release.general;
}

import 'package:hiddify/core/app_info/app_info_provider.dart';
import 'package:hiddify/core/localization/locale_preferences.dart';
import 'package:hiddify/core/model/constants.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/core/utils/preferences_utils.dart';
import 'package:hiddify/features/app_update/data/app_update_data_providers.dart';
import 'package:hiddify/features/app_update/model/app_update_failure.dart';
import 'package:hiddify/features/app_update/model/remote_version_entity.dart';
import 'package:hiddify/features/app_update/notifier/app_update_state.dart';
import 'package:hiddify/utils/utils.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:upgrader/upgrader.dart';
import 'package:version/version.dart';

part 'app_update_notifier.g.dart';

@riverpod
Upgrader upgrader(Ref ref) => Upgrader(
  storeController: UpgraderStoreController(
    onAndroid: () => ref.read(appInfoProvider).requireValue.release.allowCustomUpdateChecker
        ? UpgraderAppcastStore(appcastURL: Constants.appCastUrl)
        : UpgraderPlayStore(),
    oniOS: () => UpgraderAppStore(),
    onLinux: () => UpgraderAppcastStore(appcastURL: Constants.appCastUrl),
    onWindows: () => UpgraderAppcastStore(appcastURL: Constants.appCastUrl),
    onMacOS: () => ref.read(appInfoProvider).requireValue.release.allowCustomUpdateChecker
        ? UpgraderAppcastStore(appcastURL: Constants.appCastUrl)
        : UpgraderAppStore(),
    onWeb: () => UpgraderAppcastStore(appcastURL: Constants.appCastUrl),
  ),
  // durationUntilAlertAgain: const Duration(hours: 12),
  messages: UpgraderMessages(code: ref.watch(localePreferencesProvider).languageCode),
);

@Riverpod(keepAlive: true)
class AppUpdateNotifier extends _$AppUpdateNotifier with AppLogger {
  @override
  AppUpdateState build() => const AppUpdateState.initial();

  /// How often the app checks on its own. A user tap in About always checks.
  static const autoCheckInterval = Duration(hours: 12);

  PreferencesEntry<String?, dynamic> get _ignoreReleasePref => PreferencesEntry(
    preferences: ref.read(sharedPreferencesProvider).requireValue,
    key: 'ignored_release_version',
    defaultValue: null,
  );

  PreferencesEntry<int?, dynamic> get _lastCheckPref => PreferencesEntry(
    preferences: ref.read(sharedPreferencesProvider).requireValue,
    key: 'last_update_check_ms',
    defaultValue: null,
  );

  /// [automatic] is the check the app makes on start: it is skipped if the last one was
  /// recent, so a phone that opens the app often does not ask GitHub on every launch.
  Future<AppUpdateState> check({bool automatic = false}) async {
    if (automatic) {
      final last = _lastCheckPref.read();
      final now = DateTime.now().millisecondsSinceEpoch;
      if (last != null && now - last < autoCheckInterval.inMilliseconds) {
        loggy.debug("update check skipped: already checked recently");
        return state;
      }
    }
    await _lastCheckPref.write(DateTime.now().millisecondsSinceEpoch);
    loggy.debug("checking for update");
    state = const AppUpdateState.checking();
    // The start-up check can run before the package info has loaded: wait for it.
    final appInfo = await ref.read(appInfoProvider.future);
    if (!appInfo.release.allowCustomUpdateChecker) {
      loggy.debug("custom update checkers are not allowed for [${appInfo.release.name}] release");
      return state = const AppUpdateState.disabled();
    }
    return ref
        .watch(appUpdateRepositoryProvider)
        .getLatestVersion()
        .match(
          (err) {
            loggy.warning("failed to get latest version", err);
            return state = AppUpdateState.error(err);
          },
          (remote) {
            try {
              final latestVersion = Version.parse(remote.version);
              final currentVersion = Version.parse(appInfo.version);
              if (latestVersion > currentVersion) {
                if (remote.version == _ignoreReleasePref.read()) {
                  loggy.debug("ignored release [${remote.version}]");
                  return state = AppUpdateStateIgnored(remote);
                }
                loggy.debug("new version available: $remote");
                return state = AppUpdateState.available(remote);
              }
              loggy.info("already using latest version[$currentVersion], remote: [${remote.version}]");
              return state = const AppUpdateState.notAvailable();
            } catch (error, stackTrace) {
              loggy.warning("error parsing versions", error, stackTrace);
              return state = AppUpdateState.error(AppUpdateFailure.unexpected(error, stackTrace));
            }
          },
        )
        .run();
  }

  Future<void> ignoreRelease(RemoteVersionEntity version) async {
    loggy.debug("ignoring release [${version.version}]");
    await _ignoreReleasePref.write(version.version);
    state = AppUpdateStateIgnored(version);
  }
}

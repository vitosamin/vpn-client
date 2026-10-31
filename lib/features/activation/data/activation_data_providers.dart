import 'package:hiddify/core/http_client/http_client_provider.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/activation/activation_constants.dart';
import 'package:hiddify/features/activation/data/activation_repository.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

part 'activation_data_providers.g.dart';

@Riverpod(keepAlive: true)
ActivationRepository activationRepository(Ref ref) {
  return ActivationRepositoryImpl(
    httpClient: ref.watch(httpClientProvider),
    baseUrl: ActivationConst.apiBaseUrl,
  );
}

/// A stable identifier of this installation, sent as `device_id` on activation.
///
/// The API binds a code to one device and treats a repeat from the same id as the same
/// activation (docs/activation-api.md §3), so the value must survive restarts: it is
/// generated once and kept in SharedPreferences. It is a random UUID, not a hardware id.
@Riverpod(keepAlive: true)
Future<String> deviceId(Ref ref) async {
  final preferences = await ref.watch(sharedPreferencesProvider.future);
  return readOrCreateDeviceId(preferences);
}

/// The raw preference behind [deviceId], split out so a test can drive it directly.
Future<String> readOrCreateDeviceId(SharedPreferences preferences) async {
  final saved = preferences.getString(ActivationConst.deviceIdKey);
  if (saved != null && saved.isNotEmpty) return saved;

  final generated = const Uuid().v4();
  await preferences.setString(ActivationConst.deviceIdKey, generated);
  appLogger('activation').info('generated a new device id');
  return generated;
}

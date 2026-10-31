import 'package:fpdart/fpdart.dart';
import 'package:hiddify/features/activation/activation_constants.dart';
import 'package:hiddify/features/activation/data/activation_data_providers.dart';
import 'package:hiddify/features/activation/model/activation_failure.dart';
import 'package:hiddify/features/activation/model/activation_result.dart';
import 'package:hiddify/features/profile/data/profile_data_providers.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';
import 'package:hiddify/utils/custom_loggers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'activation_notifier.g.dart';

/// Drives one activation: API request, then the profile it returns.
///
/// The state is `AsyncData(null)` while idle, `AsyncLoading` during the request and profile
/// import, `AsyncData(result)` once the profile is stored, and `AsyncError(failure)` otherwise.
/// Only a running activation (`409 activation_in_progress`) is retried by itself; every other
/// failure is the user's to retry, so a rejected code is never hammered.
@riverpod
class ActivationNotifier extends _$ActivationNotifier with AppLogger {
  bool _disposed = false;

  @override
  AsyncValue<ActivationResult?> build() {
    // riverpod 2 has no ref.mounted; a result that arrives after the page is gone is dropped
    ref.onDispose(() => _disposed = true);
    return const AsyncData(null);
  }

  Future<void> activate(String rawCode) async {
    if (state.isLoading) return;
    final code = rawCode.trim();
    state = const AsyncLoading();

    final apiOutcome = await _activateWithRetry(code);
    final outcome = await apiOutcome.match(
      (failure) => Future.value(left<ActivationFailure, ActivationResult>(failure)),
      (result) async => (await _storeProfile(result)).map((_) => result),
    );

    if (_disposed) return;
    state = outcome.fold(
      (failure) => AsyncError<ActivationResult?>(failure, StackTrace.current),
      (result) => AsyncData<ActivationResult?>(result),
    );
  }

  /// Clears a previous result or failure, e.g. when the user edits the code.
  void reset() {
    if (state is AsyncLoading) return;
    state = const AsyncData(null);
  }

  Future<Either<ActivationFailure, ActivationResult>> _activateWithRetry(String code) async {
    final device = await ref.read(deviceIdProvider.future);
    final repository = ref.read(activationRepositoryProvider);

    late Either<ActivationFailure, ActivationResult> outcome;
    for (var attempt = 1; attempt <= ActivationConst.maxAttempts; attempt++) {
      outcome = await repository.activate(code: code, deviceId: device).run();
      final failure = outcome.fold((failure) => failure, (_) => null);
      if (failure is! ActivationInProgressFailure || attempt == ActivationConst.maxAttempts) break;

      final seconds = failure.retryAfter.clamp(
        ActivationConst.inProgressRetryMin,
        ActivationConst.inProgressRetryMax,
      );
      loggy.info('activation is already running on the service, retrying in ${seconds}s');
      await Future<void>.delayed(Duration(seconds: seconds));
      if (_disposed) break;
    }
    return outcome;
  }

  /// Adds the returned subscription as a profile: the profile store marks it active, which is
  /// what connects the user afterwards (see profile_data_source.dart `insert`).
  Future<Either<ActivationFailure, Unit>> _storeProfile(ActivationResult result) async {
    try {
      final profiles = await ref.read(profileRepositoryProvider.future);
      final name = result.preferredName;
      final outcome = await profiles
          .upsertRemote(result.subUrl, userOverride: name.isEmpty ? null : UserOverride(name: name))
          .run();
      return outcome.fold(
        (failure) {
          loggy.warning('activation succeeded, but the profile could not be added');
          return left<ActivationFailure, Unit>(ActivationFailure.profileFailed(failure));
        },
        (_) {
          loggy.info('activation succeeded, the profile was added');
          return right(unit);
        },
      );
    } catch (error, stackTrace) {
      loggy.warning('activation succeeded, but the profile store failed', error, stackTrace);
      return left(ActivationFailure.profileFailed(error, stackTrace));
    }
  }
}

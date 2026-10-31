import 'package:dio/dio.dart';
import 'package:fpdart/fpdart.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/features/activation/model/activation_failure.dart';
import 'package:hiddify/features/activation/model/activation_result.dart';
import 'package:hiddify/utils/custom_loggers.dart';

/// Talks to `POST {base}/v1/activate` (docs/activation-api.md §3).
///
/// The code and the subscription link are secrets: nothing here logs either of them, only
/// the HTTP status and the machine error code.
abstract interface class ActivationRepository {
  /// One activation attempt, no retries: the caller decides when to repeat.
  TaskEither<ActivationFailure, ActivationResult> activate({required String code, required String deviceId});
}

class ActivationRepositoryImpl with InfraLogger implements ActivationRepository {
  ActivationRepositoryImpl({required DioHttpClient httpClient, required String baseUrl})
    : _httpClient = httpClient,
      _endpoint = '${baseUrl.replaceFirst(RegExp(r'/+$'), '')}/v1/activate';

  final DioHttpClient _httpClient;
  final String _endpoint;

  @override
  TaskEither<ActivationFailure, ActivationResult> activate({required String code, required String deviceId}) {
    return TaskEither.tryCatch(() async {
      final response = await _httpClient.post<Map<String, dynamic>>(
        _endpoint,
        data: {'code': code, 'device_id': deviceId},
      );
      final data = response.data;
      if (data == null) throw const ActivationFailure.unexpected('empty response body');
      return ActivationResult.fromJson(data);
    }, (error, stackTrace) => error is ActivationFailure ? error : _mapError(error, stackTrace));
  }

  ActivationFailure _mapError(Object error, StackTrace stackTrace) {
    if (error is! DioException) return ActivationFailure.unexpected(error, stackTrace);
    final response = error.response;
    if (response == null) {
      // no answer at all: offline, DNS, TLS, timeout — the user can retry as is
      loggy.warning('activation request failed: ${error.type}');
      return ActivationFailure.network(error, stackTrace);
    }

    final status = response.statusCode ?? 0;
    final machineCode = switch (response.data) {
      final Map data => data['error']?.toString(),
      _ => null,
    };
    final retryAfter = _retryAfter(response.headers);
    loggy.warning('activation request failed: $status $machineCode');

    return switch (status) {
      // 409 carries two different situations: an already used code and a running activation
      409 when machineCode == 'activation_in_progress' => ActivationFailure.activationInProgress(
        retryAfter: retryAfter ?? 5,
      ),
      409 => const ActivationFailure.codeAlreadyUsed(),
      400 || 413 => const ActivationFailure.invalidRequest(),
      403 => const ActivationFailure.codeRevoked(),
      404 => const ActivationFailure.codeNotFound(),
      410 => const ActivationFailure.codeExpired(),
      423 => const ActivationFailure.codeLocked(),
      429 => ActivationFailure.rateLimited(retryAfter: retryAfter ?? 60),
      502 => const ActivationFailure.panelUnavailable(),
      503 => const ActivationFailure.serviceUnavailable(),
      _ => ActivationFailure.unexpected(error, stackTrace),
    };
  }

  /// `Retry-After` is documented in seconds; anything else (a date, garbage) is ignored.
  int? _retryAfter(Headers headers) {
    final raw = headers.value('retry-after');
    if (raw == null) return null;
    final seconds = int.tryParse(raw.trim());
    if (seconds == null || seconds < 0) return null;
    return seconds;
  }
}

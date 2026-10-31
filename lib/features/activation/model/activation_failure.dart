import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hiddify/core/localization/translations.dart';
import 'package:hiddify/core/model/failures.dart';

part 'activation_failure.freezed.dart';

/// Why an activation request failed, as the app shows it to the user.
///
/// The names follow the machine `error` codes of `POST /v1/activate`
/// (docs/activation-api.md §3, §7): a stable code to branch on, plus a message the app
/// localises itself, so the server text never reaches the screen.
@freezed
sealed class ActivationFailure with _$ActivationFailure, Failure {
  const ActivationFailure._();

  @With<UnexpectedFailure>()
  const factory ActivationFailure.unexpected([Object? error, StackTrace? stackTrace]) = ActivationUnexpectedFailure;

  /// The request could not be sent or no answer came back (offline, DNS, TLS).
  const factory ActivationFailure.network([Object? error, StackTrace? stackTrace]) = ActivationNetworkFailure;

  /// `400` / `413` — the request itself was rejected (bad code characters, body too large).
  const factory ActivationFailure.invalidRequest() = ActivationInvalidRequestFailure;

  /// `404 code_not_found`.
  const factory ActivationFailure.codeNotFound() = ActivationCodeNotFoundFailure;

  /// `403 code_revoked`.
  const factory ActivationFailure.codeRevoked() = ActivationCodeRevokedFailure;

  /// `410 code_expired`.
  const factory ActivationFailure.codeExpired() = ActivationCodeExpiredFailure;

  /// `409 code_already_used`.
  const factory ActivationFailure.codeAlreadyUsed() = ActivationCodeAlreadyUsedFailure;

  /// `423 code_locked` — too many attempts from other devices.
  const factory ActivationFailure.codeLocked() = ActivationCodeLockedFailure;

  /// `409 activation_in_progress`; [retryAfter] seconds, from the `Retry-After` header.
  const factory ActivationFailure.activationInProgress({@Default(5) int retryAfter}) =
      ActivationInProgressFailure;

  /// `429 rate_limited`; [retryAfter] seconds, from the `Retry-After` header.
  const factory ActivationFailure.rateLimited({@Default(60) int retryAfter}) = ActivationRateLimitedFailure;

  /// `502 panel_unavailable` — the 3x-ui panel behind the service does not answer.
  const factory ActivationFailure.panelUnavailable() = ActivationPanelUnavailableFailure;

  /// `503` — the activation service is disabled or not configured.
  const factory ActivationFailure.serviceUnavailable() = ActivationServiceUnavailableFailure;

  /// The API accepted the code, but adding the subscription as a profile failed.
  const factory ActivationFailure.profileFailed([Object? error, StackTrace? stackTrace]) = ActivationProfileFailure;

  @override
  ({String type, String? message}) present(TranslationsEn t) {
    return switch (this) {
      ActivationUnexpectedFailure() => (type: t.errors.activation.unexpected, message: null),
      ActivationNetworkFailure() => (type: t.errors.activation.network, message: null),
      ActivationInvalidRequestFailure() => (type: t.errors.activation.invalidRequest, message: null),
      ActivationCodeNotFoundFailure() => (type: t.errors.activation.codeNotFound, message: null),
      ActivationCodeRevokedFailure() => (type: t.errors.activation.codeRevoked, message: null),
      ActivationCodeExpiredFailure() => (type: t.errors.activation.codeExpired, message: null),
      ActivationCodeAlreadyUsedFailure() => (type: t.errors.activation.codeAlreadyUsed, message: null),
      ActivationCodeLockedFailure() => (type: t.errors.activation.codeLocked, message: null),
      ActivationInProgressFailure() => (type: t.errors.activation.activationInProgress, message: null),
      ActivationRateLimitedFailure() => (type: t.errors.activation.rateLimited, message: null),
      ActivationPanelUnavailableFailure() => (type: t.errors.activation.panelUnavailable, message: null),
      ActivationServiceUnavailableFailure() => (type: t.errors.activation.serviceUnavailable, message: null),
      ActivationProfileFailure() => (type: t.errors.activation.profileFailed, message: null),
    };
  }
}

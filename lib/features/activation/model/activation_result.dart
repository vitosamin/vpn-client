import 'package:freezed_annotation/freezed_annotation.dart';

part 'activation_result.freezed.dart';
part 'activation_result.g.dart';

/// The answer of `POST /v1/activate`: everything the app needs to add the profile.
///
/// [subUrl] is a secret (it is the subscription token): it is never logged, and it is only
/// handed to the profile store. The rest is shown on the success screen, and traffic numbers
/// will be replaced by the subscription's own `subscription-userinfo` header on the first update.
@freezed
class ActivationResult with _$ActivationResult {
  const ActivationResult._();

  const factory ActivationResult({
    @JsonKey(name: 'sub_url') required String subUrl,
    @JsonKey(name: 'profile_name') String? profileName,
    @JsonKey(name: 'expire') String? expire,
    @JsonKey(name: 'expire_unix') int? expireUnix,
    @JsonKey(name: 'traffic') ActivationTraffic? traffic,
    @JsonKey(name: 'client_uuid') String? clientUuid,
    @JsonKey(name: 'idempotent') @Default(false) bool idempotent,
    @JsonKey(name: 'activated_at') String? activatedAt,
  }) = _ActivationResult;

  factory ActivationResult.fromJson(Map<String, dynamic> json) => _$ActivationResultFromJson(json);

  /// The profile name to store: the API's name, otherwise the subscription host.
  String get preferredName {
    final name = profileName?.trim();
    if (name != null && name.isNotEmpty) return name;
    return Uri.tryParse(subUrl)?.host ?? '';
  }

  DateTime? get expireDate {
    if (expireUnix case final unix? when unix > 0) {
      return DateTime.fromMillisecondsSinceEpoch(unix * 1000, isUtc: true);
    }
    final iso = expire;
    if (iso == null || iso.isEmpty) return null;
    return DateTime.tryParse(iso);
  }
}

/// The traffic snapshot returned with the activation. `totalBytes == 0` with
/// [unlimited] means no limit is set for the client.
@freezed
class ActivationTraffic with _$ActivationTraffic {
  const ActivationTraffic._();

  const factory ActivationTraffic({
    @JsonKey(name: 'up_bytes') @Default(0) int upBytes,
    @JsonKey(name: 'down_bytes') @Default(0) int downBytes,
    @JsonKey(name: 'used_bytes') int? usedBytes,
    @JsonKey(name: 'total_bytes') @Default(0) int totalBytes,
    @JsonKey(name: 'remaining_bytes') int? remainingBytes,
    @JsonKey(name: 'unlimited') @Default(false) bool unlimited,
  }) = _ActivationTraffic;

  factory ActivationTraffic.fromJson(Map<String, dynamic> json) => _$ActivationTrafficFromJson(json);

  bool get isUnlimited => unlimited || totalBytes <= 0;

  /// Bytes left, or null when the plan is unlimited / the field is missing.
  int? get remaining {
    if (isUnlimited) return null;
    if (remainingBytes case final remaining?) return remaining < 0 ? 0 : remaining;
    final used = usedBytes ?? (upBytes + downBytes);
    final left = totalBytes - used;
    return left < 0 ? 0 : left;
  }
}

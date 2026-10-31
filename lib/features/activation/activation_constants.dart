/// Settings of the activation feature.
///
/// The API base URL is a build-time define, because it differs per environment and no real
/// domain exists yet:
///
///     flutter build apk --debug --dart-define=activation_api=http://10.0.2.2:8089
///
/// The default is a placeholder under the reserved `.invalid` TLD, so a build without the
/// define can never reach a real service by accident; the screen then shows the network error.
/// For a physical test device pass the API host reachable from that device, e.g.
/// `http://192.168.35.30:8089`.
abstract class ActivationConst {
  static const apiBaseUrl = String.fromEnvironment(
    'activation_api',
    defaultValue: 'https://activation.invalid',
  );

  /// SharedPreferences key of the installation id (`device_id` in the API).
  static const deviceIdKey = 'activation_device_id';

  /// The API accepts 8–256 characters of `[A-Za-z0-9_-]` (secrets.token_urlsafe).
  static final codePattern = RegExp(r'^[A-Za-z0-9_-]{8,256}$');

  /// A running activation is retried once after this many seconds (the API answers
  /// `409 activation_in_progress` with `Retry-After: 5` while it provisions the client).
  static const inProgressRetryFallback = 5;

  /// Bounds for a `Retry-After`-driven retry, so a large header value cannot freeze the screen.
  static const inProgressRetryMin = 3;
  static const inProgressRetryMax = 15;

  /// How many times one user tap may repeat the request. Only `activation_in_progress` is
  /// retried automatically; every other failure goes back to the user.
  static const maxAttempts = 2;
}

/// The activation deep link: `vpn://activate?code=<code>`.
///
/// The scheme is registered in the Android manifest and the iOS Info.plist. The router accepts
/// only this host: a link with any other host is dropped, so the scheme cannot be used to open
/// arbitrary in-app routes (the same reason subscription links are confirmed before use).
abstract class ActivationLink {
  static const scheme = 'vpn';
  static const activateHost = 'activate';
}

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/http_client/dio_http_client.dart';
import 'package:hiddify/core/model/region.dart';
import 'package:hiddify/core/preferences/preferences_provider.dart';
import 'package:hiddify/features/activation/data/activation_data_providers.dart';
import 'package:hiddify/features/activation/data/activation_repository.dart';
import 'package:hiddify/features/activation/model/activation_failure.dart';
import 'package:hiddify/features/settings/data/config_option_repository.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A [DioHttpClient] whose one POST answers with [handler] — or throws, for the error cases.
class _FakeHttpClient extends DioHttpClient {
  _FakeHttpClient(this.handler)
    : super(timeout: const Duration(seconds: 1), userAgent: 'hiddify-test', debug: false);

  final Future<Response<Map<String, dynamic>>> Function() handler;

  String? lastUrl;
  Object? lastData;

  @override
  Future<Response<T>> post<T>(
    String url, {
    Object? data,
    Map<String, dynamic>? headers,
    CancelToken? cancelToken,
    String? userAgent,
    bool proxyOnly = false,
  }) async {
    lastUrl = url;
    lastData = data;
    return await handler() as Response<T>;
  }
}

Response<Map<String, dynamic>> _ok(Map<String, dynamic> body) => Response<Map<String, dynamic>>(
  requestOptions: RequestOptions(path: '/v1/activate'),
  statusCode: 200,
  data: body,
);

DioException _badResponse(
  int status, {
  Map<String, dynamic>? body,
  Map<String, List<String>>? headers,
}) => DioException(
  requestOptions: RequestOptions(path: '/v1/activate'),
  type: DioExceptionType.badResponse,
  response: Response<Map<String, dynamic>>(
    requestOptions: RequestOptions(path: '/v1/activate'),
    statusCode: status,
    data: body,
    headers: headers == null ? null : Headers.fromMap(headers),
  ),
);

/// A network failure: no response at all.
DioException _networkError() => DioException(
  requestOptions: RequestOptions(path: '/v1/activate'),
  type: DioExceptionType.connectionError,
);

void main() {
  group('ActivationRepository', () {
    Future<ActivationRepositoryImpl> repositoryWith(_FakeHttpClient client) async =>
        ActivationRepositoryImpl(httpClient: client, baseUrl: 'http://127.0.0.1:8089/');

    test('sends the code and the device id to /v1/activate and parses the answer', () async {
      final client = _FakeHttpClient(
        () async => _ok({
          'sub_url': 'https://vpn.example.com/sub/abc',
          'profile_name': 'client@example.com',
          'expire': '2026-12-01T00:00:00Z',
          'expire_unix': 1796083200,
          'traffic': {
            'up_bytes': 10,
            'down_bytes': 20,
            'total_bytes': 1000,
            'remaining_bytes': 970,
            'unlimited': false,
          },
          'client_uuid': 'e18c9a96-71bf-48d4-933f-8b9a46d4290c',
          'idempotent': false,
          'activated_at': '2026-11-01T00:00:00Z',
        }),
      );

      final result = await (await repositoryWith(client)).activate(code: ' ABCD_1234 ', deviceId: 'device-1').run();

      expect(result.isRight(), isTrue);
      final value = result.getOrElse((_) => throw StateError('expected a result'));
      expect(value.subUrl, 'https://vpn.example.com/sub/abc');
      expect(value.preferredName, 'client@example.com');
      expect(value.expireDate, DateTime.utc(2026, 12));
      expect(value.traffic?.remaining, 970);
      expect(value.traffic?.isUnlimited, isFalse);
      // the repository trims the trailing slash of the base URL, the code goes as typed
      expect(client.lastUrl, 'http://127.0.0.1:8089/v1/activate');
      expect(client.lastData, {'code': ' ABCD_1234 ', 'device_id': 'device-1'});
    });

    test('falls back to the subscription host as the profile name', () async {
      final client = _FakeHttpClient(() async => _ok({'sub_url': 'https://sub.example.com:2096/path/token'}));
      final result = await (await repositoryWith(client)).activate(code: 'ABCD1234', deviceId: 'd').run();
      final value = result.getOrElse((_) => throw StateError('expected a result'));
      expect(value.preferredName, 'sub.example.com');
      expect(value.expireDate, isNull);
      expect(value.traffic, isNull);
    });

    test('an unlimited plan reports no remaining traffic', () async {
      final client = _FakeHttpClient(
        () async => _ok({
          'sub_url': 'https://sub.example.com/sub/token',
          'traffic': {'total_bytes': 0, 'unlimited': true},
        }),
      );
      final result = await (await repositoryWith(client)).activate(code: 'ABCD1234', deviceId: 'd').run();
      final traffic = result.getOrElse((_) => throw StateError('expected a result')).traffic!;
      expect(traffic.isUnlimited, isTrue);
      expect(traffic.remaining, isNull);
    });

    Future<ActivationFailure> failureFor(DioException error) async {
      final client = _FakeHttpClient(() async => throw error);
      final result = await (await repositoryWith(client)).activate(code: 'ABCD1234', deviceId: 'd').run();
      expect(result.isLeft(), isTrue, reason: 'expected a failure for ${error.response?.statusCode}');
      return result.getLeft().toNullable()!;
    }

    test('maps the machine error codes of the API (§3, §7)', () async {
      expect(await failureFor(_badResponse(404, body: {'error': 'code_not_found'})), isA<ActivationCodeNotFoundFailure>());
      expect(await failureFor(_badResponse(403, body: {'error': 'code_revoked'})), isA<ActivationCodeRevokedFailure>());
      expect(await failureFor(_badResponse(410, body: {'error': 'code_expired'})), isA<ActivationCodeExpiredFailure>());
      expect(await failureFor(_badResponse(423, body: {'error': 'code_locked'})), isA<ActivationCodeLockedFailure>());
      expect(await failureFor(_badResponse(400)), isA<ActivationInvalidRequestFailure>());
      expect(await failureFor(_badResponse(502, body: {'error': 'panel_unavailable'})), isA<ActivationPanelUnavailableFailure>());
      expect(await failureFor(_badResponse(503, body: {'error': 'admin_disabled'})), isA<ActivationServiceUnavailableFailure>());
    });

    test('409 tells an already used code from a running activation', () async {
      final used = await failureFor(_badResponse(409, body: {'error': 'code_already_used'}));
      expect(used, isA<ActivationCodeAlreadyUsedFailure>());

      final running = await failureFor(_badResponse(409, body: {'error': 'activation_in_progress'}));
      expect(running, isA<ActivationInProgressFailure>());
      expect((running as ActivationInProgressFailure).retryAfter, 5, reason: 'the fallback when no header is sent');
    });

    test('reads Retry-After from the response of 409 and 429', () async {
      final running = await failureFor(
        _badResponse(409, body: {'error': 'activation_in_progress'}, headers: {'retry-after': ['7']}),
      );
      expect((running as ActivationInProgressFailure).retryAfter, 7);

      final limited = await failureFor(_badResponse(429, body: {'error': 'rate_limited'}, headers: {'retry-after': ['42']}));
      expect((limited as ActivationRateLimitedFailure).retryAfter, 42);
      expect(await failureFor(_badResponse(429)), isA<ActivationRateLimitedFailure>());
    });

    test('a request without an answer is a network failure', () async {
      expect(await failureFor(_networkError()), isA<ActivationNetworkFailure>());
    });
  });

  group('device id', () {
    test('is generated once and then reused', () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();

      final first = await readOrCreateDeviceId(preferences);
      final second = await readOrCreateDeviceId(preferences);

      expect(first, isNotEmpty);
      expect(second, first);
      expect(
        RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$').hasMatch(first),
        isTrue,
        reason: 'a random v4 UUID, not a hardware id',
      );
    });
  });

  group('RU → direct defaults', () {
    test('a new install starts with the Russian region', () async {
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container.read(sharedPreferencesProvider.future);

      expect(container.read(ConfigOptions.region), Region.ru);
    });

  });
}

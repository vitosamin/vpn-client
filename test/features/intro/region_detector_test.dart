import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/intro/widget/intro_page.dart';

void main() {
  group('the timezone region', () {
    test('names a country when the zone does', () {
      expect(RegionDetector.detect(timeZoneName: 'MSK', timeZoneOffsetMinutes: 180, localeName: 'ru_RU'), 'RU');
      expect(
        RegionDetector.detect(timeZoneName: 'Europe/Moscow', timeZoneOffsetMinutes: 180, localeName: 'ru_RU'),
        'RU',
      );
      expect(RegionDetector.detect(timeZoneName: 'CST', timeZoneOffsetMinutes: 480, localeName: 'zh_CN'), 'CN');
      expect(RegionDetector.detect(timeZoneName: 'BRT', timeZoneOffsetMinutes: -180, localeName: 'pt_BR'), 'BR');
      expect(RegionDetector.detect(timeZoneName: 'IRST', timeZoneOffsetMinutes: 210, localeName: 'fa_IR'), 'IR');
      expect(RegionDetector.detect(timeZoneName: 'CET', timeZoneOffsetMinutes: 60, localeName: 'de_DE'), isNull);
    });

    test('uses the offset and the locale when the name alone is not enough', () {
      expect(RegionDetector.detect(timeZoneName: 'UTC+03', timeZoneOffsetMinutes: 180, localeName: 'ru_RU'), 'RU');
      expect(RegionDetector.detect(timeZoneName: 'CET', timeZoneOffsetMinutes: 270, localeName: 'fa_AF'), 'AF');
    });

    test('says nothing for a zone that names no country, so the region default stays', () {
      // an unknown zone must not be guessed as a foreign country: that used to reset the region to
      // "Other" and drop the region rule for a user in Russia without a network
      expect(RegionDetector.detect(timeZoneName: 'UTC', timeZoneOffsetMinutes: 0, localeName: 'en_US'), isNull);
      expect(RegionDetector.detect(timeZoneName: '', timeZoneOffsetMinutes: 0, localeName: 'en_US'), isNull);
      expect(RegionDetector.detect(timeZoneName: 'CET', timeZoneOffsetMinutes: 60, localeName: 'en_US'), isNull);
    });
  });
}

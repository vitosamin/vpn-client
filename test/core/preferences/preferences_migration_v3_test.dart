import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/core/preferences/preferences_migration.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferences> _prefs(Map<String, Object> values) async {
  SharedPreferences.setMockInitialValues(values);
  return SharedPreferences.getInstance();
}

void main() {
  test("moves an old 'other' region and the old direct DNS back to Russia", () async {
    final prefs = await _prefs({"region": "other", "direct-dns-address": "udp://1.1.1.1"});
    await PreferencesVersion3Migration(prefs).migrate();
    expect(prefs.getString("region"), "ru");
    expect(prefs.getString("direct-dns-address"), "udp://77.88.8.8");
  });

  test("keeps a chosen region and a chosen resolver", () async {
    final prefs = await _prefs({"region": "ir", "direct-dns-address": "udp://1.1.1.1"});
    await PreferencesVersion3Migration(prefs).migrate();
    expect(prefs.getString("region"), "ir");
    expect(prefs.getString("direct-dns-address"), "udp://1.1.1.1");
  });

  test("keeps a resolver the user picked for Russia", () async {
    final prefs = await _prefs({"region": "ru", "direct-dns-address": "udp://8.8.8.8"});
    await PreferencesVersion3Migration(prefs).migrate();
    expect(prefs.getString("direct-dns-address"), "udp://8.8.8.8");
  });
}

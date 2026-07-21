import 'dart:convert';
import 'package:http/http.dart' as http;

class UpdateInfo {
  final int buildNumber;
  final String releaseUrl;
  const UpdateInfo({required this.buildNumber, required this.releaseUrl});
}

// APK, GitHub Actions içinde her main'e push'ta build numarasıyla
// (--dart-define=APP_BUILD_NUMBER) derlenip aynı numarayla etiketlenmiş bir
// GitHub Release'e yükleniyor (bkz. .github/workflows/build.yml). Bu sabit,
// süresi dolmayan, herkese açık bir indirme linki veriyor (Actions
// artifact'larının aksine 30 günde silinmiyor ve kimlik doğrulama
// gerektirmiyor). Uygulama açılışta kendi build numarasını buradaki en
// güncel sürümle karşılaştırır.
class UpdateService {
  static const String _apiUrl = 'https://api.github.com/repos/yusufbas34/UZAKDUR/releases/latest';
  static const int currentBuild = int.fromEnvironment('APP_BUILD_NUMBER', defaultValue: 0);

  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final res = await http.get(Uri.parse(_apiUrl)).timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final tag = (data['tag_name'] as String?) ?? '';
      final match = RegExp(r'build-(\d+)').firstMatch(tag);
      if (match == null) return null;
      final remoteBuild = int.parse(match.group(1)!);
      if (currentBuild <= 0 || remoteBuild <= currentBuild) return null;
      return UpdateInfo(buildNumber: remoteBuild, releaseUrl: (data['html_url'] as String?) ?? '');
    } catch (_) {
      return null;
    }
  }
}

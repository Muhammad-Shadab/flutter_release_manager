import 'dart:convert';
import 'dart:io';

class ConfigStore {
  final String _path;

  ConfigStore(String appDir)
      : _path = '$appDir/.flutter_build_release_config.json';

  String get path => _path;

  Map<String, dynamic> load() {
    final file = File(_path);
    if (!file.existsSync()) return {};
    try {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  void save(Map<String, dynamic> values) {
    try {
      File(_path).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(values),
      );
    } catch (_) {}
  }
}

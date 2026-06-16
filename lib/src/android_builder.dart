import 'dart:io';
import 'config.dart';
import 'drive_uploader.dart';
import 'logger.dart';
import 'process_utils.dart';

class AndroidBuilder {
  final Config config;

  AndroidBuilder(this.config);

  Future<String?> build() async {
    final now = DateTime.now();
    final dateLabel =
        '${now.year}-${_pad(now.month)}-${_pad(now.day)}_${_pad(now.hour)}-${_pad(now.minute)}';

    final apkDir =
        Directory('${config.appDir}/build/app/outputs/flutter-apk');

    if (apkDir.existsSync()) {
      Logger.header('Cleaning Android build output');
      Logger.step('Removing old APKs from: ${apkDir.path}');
      for (final f in apkDir.listSync().whereType<File>()) {
        if (f.path.endsWith('.apk')) f.deleteSync();
      }
      Logger.ok('Old APKs deleted');
    }

    Logger.header('Android APK  ($dateLabel)');
    Logger.step('Running: flutter build apk --split-per-abi');

    final code = await runLive(
      'flutter',
      ['build', 'apk', '--split-per-abi'],
      workingDirectory: config.appDir,
    );
    if (code != 0) {
      Logger.error('Android build failed (exit $code)');
      exit(code);
    }

    stdout.writeln('\n  Output APKs:');
    for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
      final f = File('${apkDir.path}/app-$abi-release.apk');
      if (f.existsSync()) {
        Logger.ok('app-$abi-release.apk  (${_fileSize(f)})');
      } else {
        Logger.skip('app-$abi-release.apk not found');
      }
    }

    if (config.uploadDrive) {
      final apkFile = _findApk(apkDir.path);
      return await DriveUploader(config).upload(apkFile);
    }
    return null;
  }

  // Prefers arm64-v8a (all modern devices); falls back to armeabi-v7a.
  File _findApk(String dir) {
    for (final abi in ['arm64-v8a', 'armeabi-v7a']) {
      final f = File('$dir/app-$abi-release.apk');
      if (f.existsSync()) return f;
    }
    return File('$dir/app-armeabi-v7a-release.apk');
  }

  String _fileSize(File f) {
    final bytes = f.lengthSync();
    return bytes < 1024 * 1024
        ? '${(bytes / 1024).toStringAsFixed(1)} KB'
        : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');
}

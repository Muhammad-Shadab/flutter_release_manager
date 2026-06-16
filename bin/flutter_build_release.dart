import 'dart:io';

import 'package:flutter_build_release/src/android_builder.dart';
import 'package:flutter_build_release/src/ios_builder.dart';
import 'package:flutter_build_release/src/logger.dart';
import 'package:flutter_build_release/src/wizard.dart';

Future<void> main(List<String> args) async {
  final config = await Wizard().run(args);

  String? driveUrl;
  String? diawiUrl;

  if (config.buildAndroid) driveUrl = await AndroidBuilder(config).build();
  if (config.buildIos) diawiUrl = await IosBuilder(config).build();

  Logger.header('Build complete');

  if (driveUrl != null || diawiUrl != null) {
    stdout.writeln('');
    if (driveUrl != null) {
      stdout.writeln('  Android APK:');
      stdout.writeln('  $driveUrl');
      stdout.writeln('');
    }
    if (diawiUrl != null) {
      stdout.writeln('  iOS IPA (Diawi):');
      stdout.writeln('  $diawiUrl');
      stdout.writeln('');
    }
  }
}

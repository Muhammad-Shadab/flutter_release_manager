import 'dart:io';

import 'package:args/args.dart';

import 'config.dart';
import 'config_store.dart';
import 'logger.dart';
import 'project_detector.dart';

class Wizard {
  Map<String, dynamic> _saved = {};
  ConfigStore? _store;

  Future<Config> run(List<String> cliArgs) async {
    final parser = _buildParser();

    ArgResults args;
    try {
      args = parser.parse(cliArgs);
    } catch (e) {
      stderr.writeln('Error: $e\n');
      _printUsage(parser);
      exit(1);
    }

    if (args['help'] as bool) {
      _printUsage(parser);
      exit(0);
    }

    _printWelcome();

    // ── 1. Resolve app directory ──────────────────────────────────────────────
    final appDir = await _resolveAppDir(args['app-dir'] as String?);

    // ── 2. Load saved config for this project ─────────────────────────────────
    _store = ConfigStore(appDir);
    _saved = _store!.load();

    // ── 3. Platform ───────────────────────────────────────────────────────────
    final platform = args['platform'] as String? ?? await _pickPlatform();
    final buildAndroid = platform == 'android' || platform == 'both';
    final buildIos = platform == 'ios' || platform == 'both';

    // ── 4. App name ───────────────────────────────────────────────────────────
    final appName = args['app-name'] as String? ?? await _resolveAppName(appDir);

    // ── 5. Android: Drive upload ──────────────────────────────────────────────
    bool uploadDrive = args['upload-drive'] as bool;
    String? driveFolderId = args['drive-folder-id'] as String?;
    String? flavour = args['flavour'] as String?;

    if (buildAndroid && !uploadDrive) {
      _printSection('Google Drive Upload');
      _printHints([
        'APKs will be organized by flavour, year, and month inside your Drive folder.',
        'Requires rclone installed and configured. Run "rclone config" to set it up.',
        'Skip this and the APK will stay on your machine.',
      ]);
      uploadDrive = await _confirm('Upload APK to Google Drive after building?');
    }

    if (uploadDrive) {
      driveFolderId ??= await _askDriveFolderId();
      flavour ??= await _pickFlavour();
    }

    // ── 6. Advanced options: CLI flag → saved config → hardcoded default ──────
    final rcloneRemote = args.wasParsed('rclone-remote')
        ? args['rclone-remote'] as String
        : (_saved['rcloneRemote'] as String? ?? 'gdrive');
    final scheme = args.wasParsed('scheme')
        ? args['scheme'] as String
        : (_saved['scheme'] as String? ?? 'Runner');
    final exportMethod = args.wasParsed('export-method')
        ? args['export-method'] as String
        : (_saved['exportMethod'] as String? ?? 'development');

    // ── 7. iOS options ────────────────────────────────────────────────────────
    String? teamId = args['team-id'] as String?;
    String? diawiToken = args['diawi-token'] as String?;

    if (buildIos) {
      teamId ??= await _askTeamId();

      if (diawiToken == null) {
        _printSection('Diawi Upload (iOS)');
        _printHints([
          'Diawi gives testers a simple install link without needing the App Store.',
          'Create a free account at diawi.com, then go to Account → API Access Tokens.',
          'Skip this to keep the IPA local — you can distribute it manually.',
        ]);
        if (await _confirm('Upload IPA to Diawi?')) {
          diawiToken = await _askDiawiToken();
        }
      }
    }

    // ── 8. Pre-flight environment checks ─────────────────────────────────────
    _checkPrerequisites(needsDrive: uploadDrive, needsIos: buildIos);

    // ── 9. Pre-build summary ──────────────────────────────────────────────────
    _printSummary(
      platform: platform,
      appDir: appDir,
      appName: appName,
      uploadDrive: uploadDrive,
      driveFolderId: driveFolderId,
      flavour: flavour,
      rcloneRemote: rcloneRemote,
      teamId: teamId,
      scheme: scheme,
      exportMethod: exportMethod,
      diawiToken: diawiToken,
    );

    stdout.write('  Press Enter to start the build, or Ctrl+C to cancel... ');
    stdin.readLineSync();
    stdout.writeln('');

    // ── 10. Persist answers for next run ──────────────────────────────────────
    final savingNewToken = diawiToken != null && _saved['diawiToken'] == null;
    _store!.save({
      'platform': platform,
      'appName': appName,
      if (driveFolderId != null) 'driveFolderId': driveFolderId,
      if (flavour != null) 'flavour': flavour,
      'rcloneRemote': rcloneRemote,
      if (teamId != null) 'teamId': teamId,
      'scheme': scheme,
      'exportMethod': exportMethod,
      if (diawiToken != null) 'diawiToken': diawiToken,
    });
    if (savingNewToken) {
      Logger.skip(
        'Diawi token saved to ${_store!.path} — add this file to .gitignore.',
      );
    }

    return Config(
      platform: platform,
      appDir: appDir,
      appName: appName,
      flavour: flavour,
      uploadDrive: uploadDrive,
      rcloneRemote: rcloneRemote,
      driveFolderId: driveFolderId,
      teamId: teamId,
      scheme: scheme,
      exportMethod: exportMethod,
      diawiToken: diawiToken,
    );
  }

  // ── App directory ─────────────────────────────────────────────────────────

  Future<String> _resolveAppDir(String? cliValue) async {
    if (cliValue != null) {
      _assertAppDir(cliValue);
      return cliValue;
    }

    final detected = ProjectDetector.detectAppDir();
    if (detected != null) {
      Logger.ok('Flutter project detected: $detected');
      return detected;
    }

    return _ask(
      label: 'Flutter app directory',
      hints: [
        'This is the folder that contains your pubspec.yaml file.',
        'To find it: open a terminal in your project folder and run: pwd',
        'Example: /Users/john/projects/my_project/apps/my_app',
      ],
      missing: 'Flutter app directory path',
      reason:
          'The build process needs to know where your Flutter project lives on disk.',
      fix: 'Enter the full path to the folder that contains pubspec.yaml.',
      examples: ['/Users/john/projects/my_app'],
      validate: (v) {
        if (!Directory(v).existsSync()) {
          return 'Directory not found: $v';
        }
        if (!File('$v/pubspec.yaml').existsSync()) {
          return 'No pubspec.yaml found in: $v\n'
              '  Make sure this is the root of a Flutter project.';
        }
        return null;
      },
    );
  }

  void _assertAppDir(String dir) {
    if (!Directory(dir).existsSync()) {
      _printError(
        missing: 'Flutter app directory',
        reason: 'The path "$dir" does not exist on disk.',
        fix: 'Check the --app-dir flag value and make sure the directory exists.',
      );
      exit(1);
    }
    if (!File('$dir/pubspec.yaml').existsSync()) {
      _printError(
        missing: 'pubspec.yaml in $dir',
        reason:
            'The directory must be the root of a Flutter project (it must contain pubspec.yaml).',
        fix: 'Make sure --app-dir points to the folder that contains pubspec.yaml.',
      );
      exit(1);
    }
  }

  // ── App name ──────────────────────────────────────────────────────────────

  Future<String> _resolveAppName(String appDir) async {
    final savedName = _saved['appName'] as String?;
    final detectedName = ProjectDetector.readAppName(appDir);
    final defaultName = savedName ?? detectedName;

    final sourceNote = savedName != null
        ? 'Saved from last run: $savedName'
        : detectedName != null
            ? 'Detected from pubspec.yaml: $detectedName'
            : null;

    return _ask(
      label: 'App name',
      defaultValue: defaultName,
      hints: [
        'Used as a prefix in the output file name — not your bundle ID.',
        'No spaces allowed. Use CamelCase or underscores.',
        if (sourceNote != null) '$sourceNote — press Enter to accept.',
        if (defaultName == null) 'Example: MyApp → MyApp_June_2026_03-45-PM.apk',
      ],
      missing: 'App name',
      reason: 'The name is used to label the output APK and IPA files.',
      fix: 'Enter a short name with no spaces.',
      examples: ['MyApp', 'my_app', 'MyCompanyApp'],
      validate: (v) {
        if (v.contains(' ')) {
          return 'App name cannot contain spaces. '
              'Try: ${v.replaceAll(' ', '_')}';
        }
        return null;
      },
    );
  }

  // ── Google Drive folder ID ────────────────────────────────────────────────

  Future<String> _askDriveFolderId() => _ask(
        label: 'Google Drive folder ID',
        defaultValue: _saved['driveFolderId'] as String?,
        hints: [
          'Open the destination folder in Google Drive in your browser.',
          'The folder ID is the string after /folders/ in the URL.',
          'Example URL: drive.google.com/drive/folders/1wP7TZvEoOOo2W_GPV...',
          '                                              ^ copy this part',
          'Tip: Create a dedicated folder like "App Builds" in Drive first.',
        ],
        missing: 'Google Drive folder ID',
        reason:
            'rclone needs this ID to upload files into the correct Drive folder.',
        fix: 'Open the folder in drive.google.com and copy the ID from the URL.',
        examples: ['1wP7TZvEoOOo2W_GPVabcDEFghijklm'],
      );

  // ── Apple Team ID ─────────────────────────────────────────────────────────

  Future<String> _askTeamId() => _ask(
        label: 'Apple Developer Team ID',
        defaultValue: _saved['teamId'] as String?,
        hints: [
          'Sign in at developer.apple.com',
          'Click your name in the top-right corner → Membership details',
          'Copy the Team ID — it is 10 uppercase alphanumeric characters.',
          'You must be enrolled in the Apple Developer Program.',
        ],
        missing: 'Apple Developer Team ID',
        reason: 'xcodebuild needs your Team ID to sign the app during archiving.',
        fix: 'Find it at developer.apple.com → your name → Membership details.',
        examples: ['UC2HYA24R2', 'ABCD1234EF'],
        validate: (v) {
          if (v.length != 10 || !RegExp(r'^[A-Z0-9]+$').hasMatch(v)) {
            return 'Team ID must be exactly 10 uppercase letters and digits.\n'
                '  Example: UC2HYA24R2\n'
                '  Check developer.apple.com → your name → Membership details.';
          }
          return null;
        },
      );

  // ── Diawi token ───────────────────────────────────────────────────────────

  Future<String> _askDiawiToken() => _ask(
        label: 'Diawi API token',
        defaultValue: _saved['diawiToken'] as String?,
        hints: [
          'Sign in at diawi.com',
          'Go to Account → API Access Tokens → create a new token',
          'Copy the token and paste it here.',
        ],
        missing: 'Diawi API token',
        reason: 'The Diawi API requires a token to authenticate your upload.',
        fix: 'Go to diawi.com → Account → API Access Tokens and create one.',
      );

  // ── Platform picker ───────────────────────────────────────────────────────

  Future<String> _pickPlatform() async {
    final savedPlatform = _saved['platform'] as String?;
    final savedChoice = switch (savedPlatform) {
      'android' => '1',
      'ios' => '2',
      'both' => '3',
      _ => null,
    };

    _printSection('Platform');
    stdout.writeln('');
    stdout.writeln('  What do you want to build?');
    stdout.writeln('  1) Android only  — generates APK');
    stdout.writeln('  2) iOS only      — generates IPA');
    stdout.writeln('  3) Both          — APK + IPA');
    stdout.writeln('');

    while (true) {
      if (savedChoice != null) {
        stdout.write('  Enter choice [1/2/3] (last: $savedChoice): ');
      } else {
        stdout.write('  Enter choice [1/2/3]: ');
      }

      final raw = stdin.readLineSync()?.trim() ?? '';
      final choice =
          (raw.isEmpty && savedChoice != null) ? savedChoice : raw;

      switch (choice) {
        case '1':
          return 'android';
        case '2':
          return 'ios';
        case '3':
          return 'both';
        default:
          _printError(
            missing: 'Platform selection',
            reason:
                'The build process needs to know which platform to target.',
            fix: 'Enter 1 for Android, 2 for iOS, or 3 for both.',
          );
      }
    }
  }

  // ── Flavour picker ────────────────────────────────────────────────────────

  Future<String> _pickFlavour() async {
    final savedFlavour = _saved['flavour'] as String?;
    final savedChoice = switch (savedFlavour) {
      'dev' => '1',
      'prod' => '2',
      'uat' => '3',
      _ => null,
    };

    _printSection('Build flavour');
    _printHints([
      'Flavour sets the top-level folder name inside your Google Drive folder.',
      'dev  → development and testing builds',
      'prod → production / release builds',
      'uat  → user acceptance testing builds',
    ]);
    stdout.writeln('  1) dev');
    stdout.writeln('  2) prod');
    stdout.writeln('  3) uat');
    stdout.writeln('');

    while (true) {
      if (savedChoice != null) {
        stdout.write('  Enter choice [1/2/3] (last: $savedChoice): ');
      } else {
        stdout.write('  Enter choice [1/2/3]: ');
      }

      final raw = stdin.readLineSync()?.trim() ?? '';
      final choice =
          (raw.isEmpty && savedChoice != null) ? savedChoice : raw;

      switch (choice) {
        case '1':
          return 'dev';
        case '2':
          return 'prod';
        case '3':
          return 'uat';
        default:
          _printError(
            missing: 'Build flavour',
            reason:
                'The flavour determines which folder the APK is uploaded to in Drive.',
            fix: 'Enter 1 for dev, 2 for prod, or 3 for uat.',
          );
      }
    }
  }

  // ── Confirm prompt ────────────────────────────────────────────────────────

  Future<bool> _confirm(String question) async {
    stdout.write('  $question [y/N]: ');
    final answer = stdin.readLineSync()?.trim().toLowerCase() ?? '';
    return answer == 'y' || answer == 'yes';
  }

  // ── Generic text prompt with retry ────────────────────────────────────────

  Future<String> _ask({
    required String label,
    String? defaultValue,
    List<String> hints = const [],
    required String missing,
    required String reason,
    required String fix,
    List<String> examples = const [],
    String? Function(String value)? validate,
  }) async {
    _printSection(label);
    if (hints.isNotEmpty) _printHints(hints);

    while (true) {
      if (defaultValue != null) {
        stdout.write('  $label [$defaultValue]: ');
      } else {
        stdout.write('  $label: ');
      }

      final raw = stdin.readLineSync()?.trim() ?? '';
      final value =
          (raw.isEmpty && defaultValue != null) ? defaultValue : raw;

      if (value.isEmpty) {
        _printError(
          missing: missing,
          reason: reason,
          fix: fix,
          examples: examples,
        );
        continue;
      }

      if (validate != null) {
        final error = validate(value);
        if (error != null) {
          stderr.writeln('');
          stderr.writeln('  ❌  $error');
          stderr.writeln('');
          continue;
        }
      }

      return value;
    }
  }

  // ── Pre-flight environment checks ─────────────────────────────────────────

  void _checkPrerequisites({required bool needsDrive, required bool needsIos}) {
    if (Process.runSync('which', ['flutter']).exitCode != 0) {
      _printError(
        missing: 'flutter command',
        reason: 'flutter is required to build the app.',
        fix: 'Install Flutter: flutter.dev/docs/get-started/install',
      );
      exit(1);
    }
    if (needsDrive && Process.runSync('which', ['rclone']).exitCode != 0) {
      _printError(
        missing: 'rclone command',
        reason: 'rclone is required to upload APKs to Google Drive.',
        fix: 'Install with: brew install rclone\n  Then configure: rclone config',
      );
      exit(1);
    }
    if (needsIos && Process.runSync('which', ['xcodebuild']).exitCode != 0) {
      _printError(
        missing: 'xcodebuild command',
        reason: 'xcodebuild is required to build and archive iOS apps.',
        fix: 'Install Xcode command-line tools: xcode-select --install',
      );
      exit(1);
    }
  }

  // ── Pre-build summary ─────────────────────────────────────────────────────

  void _printSummary({
    required String platform,
    required String appDir,
    required String appName,
    required bool uploadDrive,
    required String? driveFolderId,
    required String? flavour,
    required String rcloneRemote,
    required String? teamId,
    required String scheme,
    required String exportMethod,
    required String? diawiToken,
  }) {
    final platformLabel = switch (platform) {
      'android' => 'Android',
      'ios' => 'iOS',
      _ => 'Android + iOS',
    };

    stdout.writeln('');
    stdout.writeln('╔══════════════════════════════════════════════╗');
    stdout.writeln('  Build Summary');
    stdout.writeln('╚══════════════════════════════════════════════╝');
    stdout.writeln('');
    stdout.writeln('  Platform      $platformLabel');
    stdout.writeln('  App dir       $appDir');
    stdout.writeln('  App name      $appName');

    if (platform == 'android' || platform == 'both') {
      stdout.writeln('');
      stdout.writeln('  Android');
      if (uploadDrive) {
        stdout.writeln('    Drive upload  Yes');
        stdout.writeln('    Flavour       $flavour');
        stdout.writeln('    Remote        $rcloneRemote');
        stdout.writeln('    Folder ID     $driveFolderId');
      } else {
        stdout.writeln('    Drive upload  No — APK stays local');
      }
    }

    if (platform == 'ios' || platform == 'both') {
      stdout.writeln('');
      stdout.writeln('  iOS');
      stdout.writeln('    Team ID       $teamId');
      stdout.writeln('    Scheme        $scheme');
      stdout.writeln('    Export        $exportMethod');
      stdout.writeln(
          '    Diawi upload  ${diawiToken != null ? 'Yes' : 'No — IPA stays local'}');
    }

    stdout.writeln('');
  }

  // ── Error display ─────────────────────────────────────────────────────────

  void _printError({
    required String missing,
    required String reason,
    required String fix,
    List<String> examples = const [],
  }) {
    stderr.writeln('');
    stderr.writeln('  ❌  Missing: $missing');
    stderr.writeln('  ❌  Reason:  $reason');
    if (examples.isNotEmpty) {
      stderr.writeln('  ❌  Example${examples.length > 1 ? 's' : ''}:');
      for (final e in examples) {
        stderr.writeln('      $e');
      }
    }
    if (fix.isNotEmpty) {
      stderr.writeln('  ❌  Fix:     $fix');
    }
    stderr.writeln('');
  }

  // ── UI helpers ────────────────────────────────────────────────────────────

  void _printWelcome() {
    stdout.writeln('');
    stdout.writeln('╔══════════════════════════════════════════════╗');
    stdout.writeln('  flutter_build_release');
    stdout.writeln('  Build · Archive · Distribute');
    stdout.writeln('╚══════════════════════════════════════════════╝');
    stdout.writeln('');
    stdout.writeln('  This tool will ask a few questions,');
    stdout.writeln('  then build and upload your app automatically.');
    stdout.writeln('');
  }

  void _printSection(String title) {
    final pad = title.length < 42 ? '─' * (42 - title.length) : '';
    stdout.writeln('');
    stdout.writeln('  ─── $title $pad');
  }

  void _printHints(List<String> hints) {
    stdout.writeln('');
    for (final h in hints) {
      stdout.writeln('  \x1B[0;36mℹ\x1B[0m  $h');
    }
    stdout.writeln('');
  }

  void _printUsage(ArgParser parser) {
    stdout.writeln('''
flutter_build_release — Build and distribute Flutter apps

Run without flags for guided interactive mode:
  flutter_build_release

Or pass flags directly (useful for CI/scripts):
  flutter_build_release --platform <android|ios|both> --app-dir <path> --app-name <name> [options]

${parser.usage}
''');
  }

  ArgParser _buildParser() => ArgParser()
    ..addOption('platform',
        abbr: 'p',
        help: 'Target platform: android | ios | both',
        allowed: ['android', 'ios', 'both'])
    ..addOption('app-dir',
        abbr: 'd', help: 'Path to the Flutter app directory.')
    ..addOption('app-name',
        abbr: 'n', help: 'App name used in output file names.')
    ..addFlag('upload-drive',
        help: 'Upload the APK to Google Drive after build.',
        negatable: false)
    ..addOption('rclone-remote',
        help: 'rclone remote name.', defaultsTo: 'gdrive')
    ..addOption('drive-folder-id', help: 'Google Drive root folder ID.')
    ..addOption('flavour',
        abbr: 'f',
        help: 'dev | prod | uat — top-level Drive folder.',
        allowed: ['dev', 'prod', 'uat'])
    ..addOption('team-id',
        abbr: 't', help: 'Apple Developer Team ID (iOS only).')
    ..addOption('scheme',
        help: 'Xcode scheme name.', defaultsTo: 'Runner')
    ..addOption('export-method',
        help: 'development | release-testing | app-store',
        allowed: ['development', 'release-testing', 'app-store'],
        defaultsTo: 'development')
    ..addOption('diawi-token', help: 'Diawi API token for IPA upload.')
    ..addFlag('help', abbr: 'h', help: 'Print this help.', negatable: false);
}

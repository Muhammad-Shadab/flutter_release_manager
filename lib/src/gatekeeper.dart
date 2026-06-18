import 'dart:io';

import 'app_config.dart';
import 'logger.dart';

/// macOS Gatekeeper helpers.
///
/// On first use, macOS asks the user to approve execution of unsigned
/// or internet-downloaded binaries (flutter, rclone, dart tools).
/// If the user clicks Cancel the subprocess is killed and the build fails.
///
/// This class:
///   - Shows a one-time security notice before the first build
///   - Detects Gatekeeper failure patterns in process output
///   - Prints actionable recovery guidance when a build fails
class GatekeeperGuard {
  static const _noticeKey = 'macosGatekeeperNoticeSeen';

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Shows the macOS Security Notice once, then never again.
  /// No-op on Linux and Windows.
  static void showNoticeIfNeeded() {
    if (!Platform.isMacOS) return;
    final seen = AppConfig.load()[_noticeKey] as bool? ?? false;
    if (seen) return;
    _printNotice();
    AppConfig.save({_noticeKey: true});
  }

  /// Resets the notice flag so it shows again on the next run.
  /// Used by `flutter_release_manager config reset`.
  static void resetNotice() => AppConfig.save({_noticeKey: false});

  /// Returns true if [output] and [exitCode] suggest Gatekeeper blocked
  /// the process. Only ever returns true on macOS.
  static bool isGatekeeperError(String output, int exitCode) {
    if (!Platform.isMacOS) return false;
    if (exitCode == 0) return false;

    final lower = output.toLowerCase();
    return lower.contains('operation not permitted') ||
        lower.contains('cannot be opened') ||
        lower.contains('apple cannot verify') ||
        lower.contains('downloaded from the internet') ||
        lower.contains('malicious software') ||
        lower.contains('developer cannot be verified') ||
        lower.contains('quarantine') ||
        lower.contains('code signature') ||
        // Exit 126 = permission denied running the binary
        (exitCode == 126 && lower.contains('permission')) ||
        // Exit 137 = SIGKILL — OS terminated the process
        exitCode == 137;
  }

  /// Prints recovery steps after a Gatekeeper-blocked failure.
  static void showGatekeeperGuidance(String failedCommand) {
    if (!Platform.isMacOS) return;
    stderr.writeln('');
    stderr.writeln(
      '  ═══════════════════════════════════════════════════',
    );
    stderr.writeln('  macOS blocked "$failedCommand"');
    stderr.writeln(
      '  ═══════════════════════════════════════════════════',
    );
    stderr.writeln('');
    stderr.writeln('  macOS Gatekeeper prevented the tool from running.');
    stderr.writeln('  This happens once on first use of a new binary.');
    stderr.writeln('');
    stderr.writeln('  How to allow it:');
    stderr.writeln('');
    stderr.writeln('  Option 1 — System Settings (recommended):');
    stderr.writeln('    1. Open: Apple menu → System Settings');
    stderr.writeln('    2. Go to: Privacy & Security');
    stderr.writeln('    3. Scroll down to the Security section');
    stderr.writeln(
      '    4. Look for "$failedCommand was blocked" and click Allow Anyway',
    );
    stderr.writeln('    5. Re-run: flutter_release_manager');
    stderr.writeln('');
    stderr.writeln('  Option 2 — Terminal (one command):');
    stderr.writeln(
      '    xattr -d com.apple.quarantine \$(which $failedCommand)',
    );
    stderr.writeln('    Then re-run: flutter_release_manager');
    stderr.writeln('');
    stderr.writeln('  Tip: run flutter_release_manager doctor to');
    stderr.writeln('  check which tools are quarantined.');
    stderr.writeln('');
  }

  /// Used by doctor to check if key binaries are quarantined.
  /// Returns the list of binary names that carry the quarantine attribute.
  static List<String> quarantinedBinaries(List<String> commands) {
    if (!Platform.isMacOS) return [];
    final blocked = <String>[];
    for (final cmd in commands) {
      final which = Process.runSync('which', [cmd], runInShell: true);
      if (which.exitCode != 0) continue;
      final binPath = (which.stdout as String).trim();
      if (binPath.isEmpty) continue;
      final xattr = Process.runSync(
        'xattr',
        ['-p', 'com.apple.quarantine', binPath],
        runInShell: true,
      );
      if (xattr.exitCode == 0) blocked.add(cmd);
    }
    return blocked;
  }

  // ── Notice UI ──────────────────────────────────────────────────────────────

  static void _printNotice() {
    stdout.writeln('');
    stdout.writeln(
      '  ═══════════════════════════════════════════════════',
    );
    stdout.writeln('  macOS Security Notice');
    stdout.writeln(
      '  ═══════════════════════════════════════════════════',
    );
    stdout.writeln('');
    stdout.writeln(
      '  On first use, macOS may ask permission to run',
    );
    stdout.writeln('  Dart Runtime or Flutter tools.');
    stdout.writeln('');
    stdout.writeln('  If a security dialog appears:');
    stdout.writeln('');
    stdout.writeln('    ✓  Click Open');
    stdout.writeln('    ✓  Click Allow');
    stdout.writeln('    ✗  Do NOT click Cancel or Move to Trash');
    stdout.writeln('');
    stdout.writeln('  This approval is required only once per tool.');
    stdout.writeln('  After approval, all future runs are instant.');
    stdout.writeln('');
    stdout.writeln(
      '  If a prompt appears in System Settings instead:',
    );
    stdout.writeln('    Privacy & Security → scroll to Security');
    stdout.writeln('    → click Allow Anyway');
    stdout.writeln('');
    stdout.write('  Press Enter to continue. ');
    stdin.readLineSync();
    stdout.writeln('');
  }
}

/// A helper that wraps `GatekeeperGuard` for use in build pipelines.
/// Call [check] after any subprocess failure to apply Gatekeeper heuristics.
class GatekeeperBuildGuard {
  final String commandName;

  const GatekeeperBuildGuard(this.commandName);

  /// If [output]/[exitCode] match Gatekeeper patterns, print guidance
  /// and return true. Otherwise return false.
  bool handleFailure(String output, int exitCode) {
    if (!GatekeeperGuard.isGatekeeperError(output, exitCode)) return false;
    Logger.skip('Possible macOS Gatekeeper issue detected.');
    GatekeeperGuard.showGatekeeperGuidance(commandName);
    return true;
  }
}

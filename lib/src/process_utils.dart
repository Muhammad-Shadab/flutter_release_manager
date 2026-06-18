import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Runs [executable] with [args], streaming stdout/stderr live.
/// Kills the process and throws [TimeoutException] if it exceeds [timeout].
/// Returns the exit code on success.
Future<int> runLive(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Duration timeout = const Duration(minutes: 20),
}) async {
  final process = await Process.start(
    executable,
    args,
    workingDirectory: workingDirectory,
  );

  // Pipe output without blocking — exitCode drives the await.
  process.stdout.listen(stdout.add);
  process.stderr.listen(stderr.add);

  try {
    return await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill(ProcessSignal.sigterm);
    await Future<void>.delayed(const Duration(seconds: 3));
    process.kill(ProcessSignal.sigkill);
    throw TimeoutException(
      '$executable timed out after ${timeout.inMinutes} minutes and was killed.',
    );
  }
}

/// Like [runLive] but also returns the combined stdout+stderr as a string.
/// Useful for detecting failure patterns (e.g. Gatekeeper errors) after
/// a non-zero exit.
Future<(int, String)> runLiveCapturing(
  String executable,
  List<String> args, {
  String? workingDirectory,
  Duration timeout = const Duration(minutes: 20),
}) async {
  final process = await Process.start(
    executable,
    args,
    workingDirectory: workingDirectory,
  );

  final buffer = StringBuffer();

  process.stdout.listen((data) {
    stdout.add(data);
    buffer.write(utf8.decode(data, allowMalformed: true));
  });
  process.stderr.listen((data) {
    stderr.add(data);
    buffer.write(utf8.decode(data, allowMalformed: true));
  });

  try {
    final code = await process.exitCode.timeout(timeout);
    return (code, buffer.toString());
  } on TimeoutException {
    process.kill(ProcessSignal.sigterm);
    await Future<void>.delayed(const Duration(seconds: 3));
    process.kill(ProcessSignal.sigkill);
    throw TimeoutException(
      '$executable timed out after ${timeout.inMinutes} minutes and was killed.',
    );
  }
}

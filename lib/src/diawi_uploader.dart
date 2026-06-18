import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'config.dart';
import 'logger.dart';

class DiawiUploader {
  final Config config;

  DiawiUploader(this.config);

  Future<String?> upload(File ipaFile) async {
    Logger.header('Uploading IPA to Diawi');

    if (!ipaFile.existsSync()) {
      Logger.error('IPA not found: ${ipaFile.path}');
      return null;
    }

    final name = ipaFile.uri.pathSegments.last;
    final totalBytes = ipaFile.lengthSync();
    Logger.info('$name  (${_fileSize(ipaFile)})');
    stdout.writeln('');

    // ── Upload phase ──────────────────────────────────────────────────────────
    final uploadStart = DateTime.now();
    final jobToken = await _uploadWithRetry(ipaFile, totalBytes);
    if (jobToken == null) return null;

    final uploadSecs = DateTime.now().difference(uploadStart).inSeconds;
    final avgSpeed =
        uploadSecs > 0 ? totalBytes / uploadSecs : totalBytes.toDouble();

    stdout.writeln('');
    Logger.ok(
      'Upload completed in ${_fmt(uploadSecs)}'
      '  ·  avg ${_speedLabel(avgSpeed)}',
    );

    // ── Processing phase ──────────────────────────────────────────────────────
    stdout.writeln('');
    Logger.step('Waiting for Diawi to process the IPA...');
    final processStart = DateTime.now();
    final diawiHash = await _pollForCompletion(jobToken);
    if (diawiHash == null) return null;

    final processSecs = DateTime.now().difference(processStart).inSeconds;
    final totalSecs = DateTime.now().difference(uploadStart).inSeconds;

    // ── Result banner ─────────────────────────────────────────────────────────
    final url = 'https://i.diawi.com/$diawiHash';

    stdout.writeln('');
    stdout.writeln('╔══════════════════════════════════════════════╗');
    stdout.writeln('  Diawi Upload Complete');
    stdout.writeln('╚══════════════════════════════════════════════╝');
    stdout.writeln('');
    _row('IPA', name);
    stdout.writeln('');
    _row('Upload time', _fmt(uploadSecs));
    _row('Average speed', _speedLabel(avgSpeed));
    _row('Processing', _fmt(processSecs));
    _row('Total time', _fmt(totalSecs));
    stdout.writeln('');
    stdout.writeln('  Diawi Link:');
    stdout.writeln('  $url');
    stdout.writeln('');

    if (Platform.isMacOS) {
      final proc = await Process.start('pbcopy', []);
      proc.stdin.add(url.codeUnits);
      await proc.stdin.close();
      await proc.exitCode;
      Logger.ok('Link copied to clipboard');
    }

    return url;
  }

  // ── Upload with retry ─────────────────────────────────────────────────────

  Future<String?> _uploadWithRetry(File ipaFile, int totalBytes) async {
    const maxAttempts = 3;
    Exception? lastError;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        Logger.step(
          'Uploading to Diawi'
          '${maxAttempts > 1 ? " (attempt $attempt/$maxAttempts)" : ""}...',
        );
        final token = await _uploadWithProgress(ipaFile, totalBytes);
        if (token != null) return token;
        throw Exception('No job token in Diawi response');
      } on Exception catch (e) {
        lastError = e;
        if (attempt < maxAttempts) {
          final delay = attempt * 3;
          stdout.writeln('');
          Logger.skip('Upload failed: $e');
          Logger.step('Retrying in ${delay}s...');
          await Future<void>.delayed(Duration(seconds: delay));
        }
      }
    }

    Logger.error('All upload attempts failed: $lastError');
    return null;
  }

  // ── Core upload with timer-driven single-line progress ────────────────────

  Future<String?> _uploadWithProgress(File ipaFile, int totalBytes) async {
    // Per-attempt counters — captured by closure, isolated from retries.
    var bytesSent = 0;
    final startTime = DateTime.now();

    Timer? timer;
    try {
      timer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _writeProgress(bytesSent, totalBytes, startTime),
      );

      final token = await _doUpload(
        ipaFile,
        totalBytes,
        (n) => bytesSent += n,
      );

      // Pin to 100 % before the finally block clears the line.
      _writeProgress(totalBytes, totalBytes, startTime);
      return token;
    } finally {
      timer?.cancel();
      stdout.write('\r\x1B[K');
    }
  }

  Future<String?> _doUpload(
    File ipaFile,
    int totalBytes,
    void Function(int) onBytes,
  ) async {
    const boundary = 'flutter_release_manager';

    final fieldPart = '--$boundary\r\n'
        'Content-Disposition: form-data; name="token"\r\n\r\n'
        '${config.diawiToken!}\r\n';
    final filePart = '--$boundary\r\n'
        'Content-Disposition: form-data; name="file"; '
        'filename="${ipaFile.uri.pathSegments.last}"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n';
    const closing = '\r\n--flutter_release_manager--\r\n';

    final fieldBytes = utf8.encode(fieldPart);
    final fileBytes = utf8.encode(filePart);
    final closingBytes = utf8.encode(closing);
    final contentLength =
        fieldBytes.length + fileBytes.length + totalBytes + closingBytes.length;

    final request =
        http.StreamedRequest('POST', Uri.parse('https://upload.diawi.com/'))
          ..headers['Content-Type'] = 'multipart/form-data; boundary=$boundary'
          ..contentLength = contentLength;

    // Stream the multipart body in the background so request.send() can
    // run concurrently and apply TCP backpressure.
    unawaited(
      _streamBody(
          request.sink, ipaFile, fieldBytes, fileBytes, closingBytes, onBytes),
    );

    late final http.StreamedResponse streamed;
    try {
      streamed = await request.send().timeout(const Duration(minutes: 20));
    } on TimeoutException {
      throw Exception('Upload timed out after 20 minutes.');
    } on SocketException catch (e) {
      throw Exception('No internet connection: ${e.message}');
    }

    final body = await streamed.stream.bytesToString();

    switch (streamed.statusCode) {
      case 200:
        break;
      case 401:
        throw Exception(
          'Invalid Diawi token (401). '
          'Update it with: flutter_release_manager config',
        );
      case 413:
        throw Exception(
          'File too large for your Diawi plan (413). '
          '${_fileSize(ipaFile)} — check your account limits at diawi.com.',
        );
      default:
        throw Exception(
            'Diawi server error (HTTP ${streamed.statusCode}): $body');
    }

    final data = jsonDecode(body) as Map<String, dynamic>;
    return data['job'] as String?;
  }

  // Streams the multipart body to [sink], counting bytes via [onBytes].
  // Runs via unawaited — errors are absorbed so the HTTP response drive.
  Future<void> _streamBody(
    StreamSink<List<int>> sink,
    File ipaFile,
    List<int> fieldBytes,
    List<int> fileBytes,
    List<int> closingBytes,
    void Function(int) onBytes,
  ) async {
    try {
      sink.add(fieldBytes);
      sink.add(fileBytes);
      await for (final chunk in ipaFile.openRead()) {
        onBytes(chunk.length);
        sink.add(chunk);
      }
      sink.add(closingBytes);
    } finally {
      try {
        await sink.close();
      } catch (_) {}
    }
  }

  // ── Single-line progress bar ──────────────────────────────────────────────

  void _writeProgress(int sent, int total, DateTime startTime) {
    if (total <= 0) return;

    final elapsed = DateTime.now().difference(startTime).inSeconds;
    final pct = (sent / total * 100).clamp(0.0, 100.0);
    final speed = elapsed > 0 ? sent / elapsed : 0.0;
    final etaSecs =
        (speed > 0 && sent < total) ? ((total - sent) / speed).round() : 0;
    final eta = sent >= total
        ? 'done'
        : etaSecs > 0
            ? _fmt(etaSecs)
            : '...';

    const barWidth = 20;
    final filled = (pct / 100 * barWidth).round().clamp(0, barWidth);
    final bar = '${'█' * filled}${'░' * (barWidth - filled)}';

    stdout.write(
      '\r\x1B[K'
      '  [$bar] ${pct.toStringAsFixed(1)}%'
      '  ${_bytesLabel(sent)} / ${_bytesLabel(total)}'
      '  ${_speedLabel(speed)}'
      '  ETA: $eta',
    );
  }

  // ── Diawi status polling ──────────────────────────────────────────────────

  Future<String?> _pollForCompletion(String jobToken) async {
    const maxAttempts = 40; // 40 × 3 s = 2 min ceiling
    const interval = Duration(seconds: 3);

    var lastStatus = '';

    for (var i = 0; i < maxAttempts; i++) {
      await Future<void>.delayed(interval);

      try {
        final uri = Uri.parse('https://upload.diawi.com/status').replace(
          queryParameters: {'token': config.diawiToken, 'job': jobToken},
        );

        final res = await http.get(uri).timeout(
              const Duration(seconds: 15),
              onTimeout: () =>
                  throw TimeoutException('Status check timed out.'),
            );

        switch (res.statusCode) {
          case 401:
            Logger.error(
                'Invalid Diawi token during processing — update via config.');
            return null;
          case 200:
            break;
          default:
            throw Exception('HTTP ${res.statusCode}');
        }

        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final status = data['status'] as int?;
        final message = (data['message'] as String?)?.trim() ?? '';

        if (status == 2000) {
          Logger.ok('Diawi link generated');
          return data['hash'] as String?;
        }

        if (status == 4000) {
          Logger.error(
            'Diawi processing failed: '
            '${message.isNotEmpty ? message : "unknown error"}',
          );
          return null;
        }

        // Emit a status line only when the message changes — no log spam.
        final statusText = message.isNotEmpty ? message : 'Processing';
        if (statusText != lastStatus) {
          Logger.step('Status: $statusText');
          lastStatus = statusText;
        }
      } on TimeoutException {
        if (i > 0) Logger.skip('Status check timed out — retrying...');
      } on SocketException {
        if (i > 0) Logger.skip('Network error — retrying status check...');
      } catch (e) {
        if (i > 0) Logger.skip('Status check error (attempt ${i + 1}): $e');
      }
    }

    Logger.error('Diawi processing timed out after ${maxAttempts * 3}s.');
    return null;
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _row(String label, String value) {
    stdout.writeln('  ${label.padRight(16)}$value');
  }

  String _bytesLabel(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _speedLabel(double bps) {
    if (bps < 1024) return '${bps.toStringAsFixed(0)} B/s';
    if (bps < 1024 * 1024) return '${(bps / 1024).toStringAsFixed(1)} KB/s';
    return '${(bps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  String _fileSize(File file) {
    final bytes = file.lengthSync();
    return bytes < 1024 * 1024
        ? '${(bytes / 1024).toStringAsFixed(1)} KB'
        : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  String _fmt(int secs) {
    if (secs < 60) return '${secs}s';
    return '${secs ~/ 60}m ${secs % 60}s';
  }
}

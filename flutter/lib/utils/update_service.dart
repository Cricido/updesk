import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

const _kManifestUrl =
    'https://updesk.uptimeservice.it/api/v1/update/stable.json';
const _kUpdateTempDir = 'updesk-update';

// Stato globale osservabile dalla UI
final updateNotifier = ValueNotifier<UpdateInfo?>(null);

class UpdateInfo {
  final String channel;
  final String version;
  final String url;
  final String sha256;
  final bool force;
  final String minSupported;
  final String notes;
  final File installerFile;

  UpdateInfo({
    required this.channel,
    required this.version,
    required this.url,
    required this.sha256,
    required this.force,
    required this.minSupported,
    required this.notes,
    required this.installerFile,
  });
}

class UpdateService {
  static Timer? _timer;
  static bool _running = false;

  static void start() {
    if (_timer != null) return;
    _checkAndDownload();
    _timer = Timer.periodic(const Duration(hours: 8), (_) => _checkAndDownload());
  }

  static void stop() {
    _timer?.cancel();
    _timer = null;
  }

  static Future<void> _checkAndDownload() async {
    if (_running) return;
    _running = true;
    try {
      await _run();
    } catch (e) {
      debugPrint('UpDesk update check failed: $e');
    } finally {
      _running = false;
    }
  }

  static Future<void> _run() async {
    final manifest = await _fetchManifest();
    if (manifest == null) return;

    final currentVersion = await _currentVersion();
    final version = (manifest['version'] as String? ?? '').trim();
    if (version.isEmpty || !_isNewer(version, currentVersion)) {
      updateNotifier.value = null;
      return;
    }

    final channel = (manifest['channel'] as String? ?? 'stable').trim();
    final url = (manifest['url'] as String? ?? '').trim();
    if (url.isEmpty) return;
    final sha256hash = (manifest['sha256'] as String? ?? '').toLowerCase();
    final mandatory = manifest['mandatory'] as bool? ?? false;
    final minSupported = (manifest['min_supported'] as String? ?? '').trim();
    final force = mandatory || _isOlder(currentVersion, minSupported);
    final notes = manifest['changelog'] as String? ??
        manifest['notes_it'] as String? ??
        manifest['notes'] as String? ??
        '';

    final destFile = await _resolveTargetFile(version, url);
    debugPrint('UpDesk update available: local=$currentVersion remote=$version mandatory=$force');

    // Se già scaricato e verificato, notifica subito
    if (await destFile.exists()) {
      if (await _verify(destFile, sha256hash)) {
        updateNotifier.value = UpdateInfo(
          channel: channel,
          version: version,
          url: url,
          sha256: sha256hash,
          force: force,
          minSupported: minSupported,
          notes: notes,
          installerFile: destFile,
        );
        return;
      } else {
        await destFile.delete();
      }
    }

    // Download silenzioso
    await _download(url, destFile);

    // Verifica integrità
    if (!await _verify(destFile, sha256hash)) {
      await destFile.delete();
      return;
    }

    // Notifica UI
    updateNotifier.value = UpdateInfo(
      channel: channel,
      version: version,
      url: url,
      sha256: sha256hash,
      force: force,
      minSupported: minSupported,
      notes: notes,
      installerFile: destFile,
    );
  }

  static Future<Map<String, dynamic>?> _fetchManifest() async {
    try {
      final response = await http
          .get(Uri.parse(_kManifestUrl))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      return jsonDecode(response.body) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('UpDesk manifest fetch failed: $e');
      return null;
    }
  }

  static Future<File> _resolveTargetFile(String version, String url) async {
    final tempDir = Directory(p.join(Directory.systemTemp.path, _kUpdateTempDir));
    if (!await tempDir.exists()) {
      await tempDir.create(recursive: true);
    }
    final filename = Uri.parse(url).pathSegments.isNotEmpty
        ? Uri.parse(url).pathSegments.last
        : 'updesk-$version.exe';
    return File(p.join(tempDir.path, filename));
  }

  static Future<void> _download(String url, File dest) async {
    final client = http.Client();
    try {
      debugPrint('UpDesk update download started: $url -> ${dest.path}');
      final request = http.Request('GET', Uri.parse(url));
      final response = await client.send(request);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode} while downloading update');
      }
      final sink = dest.openWrite();
      await response.stream.pipe(sink);
      await sink.close();
      debugPrint('UpDesk update download completed: ${dest.path}');
    } finally {
      client.close();
    }
  }

  static Future<bool> _verify(File file, String expectedSha256) async {
    if (expectedSha256.isEmpty) return true;
    final bytes = await file.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    final ok = digest == expectedSha256;
    debugPrint('UpDesk update sha256 ${ok ? "ok" : "mismatch"}: ${file.path}');
    return ok;
  }

  // Installa in background e riapre l'app
  static Future<void> installAndRestart(UpdateInfo info) async {
    final installer = info.installerFile.path;
    final appExe = Platform.resolvedExecutable;
    if (Platform.isWindows) {
      final updaterExe = p.join(p.dirname(appExe), 'updesk_updater.exe');
      if (await File(updaterExe).exists()) {
        debugPrint('Launching UpDesk updater helper: $updaterExe');
        await Process.start(
          updaterExe,
          ['--file', installer, '--pid', '$pid', '--restart', appExe],
          mode: ProcessStartMode.detached,
        );
        return;
      }
    }

    final scriptPath = p.join(Directory.systemTemp.path, 'ud_update_runner.bat');
    final script = '@echo off\r\n'
        'timeout /t 3 /nobreak >nul\r\n'
        '"$installer" /VERYSILENT /NORESTART /CLOSEAPPLICATIONS\r\n'
        'start "" "$appExe"\r\n'
        'del "%~f0"\r\n';

    await File(scriptPath).writeAsString(script);
    debugPrint('Launching legacy update runner: $scriptPath');
    await Process.start('cmd.exe', ['/C', scriptPath], mode: ProcessStartMode.detached);
  }

  static Future<String> _currentVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return info.version;
    } catch (_) {
      return '1.0.2';
    }
  }

  static bool _isNewer(String remote, String current) {
    final r = _parse(remote);
    final c = _parse(current);
    for (int i = 0; i < 3; i++) {
      if (r[i] > c[i]) return true;
      if (r[i] < c[i]) return false;
    }
    return false;
  }

  static bool _isOlder(String current, String minimum) {
    if (minimum.isEmpty) return false;
    final c = _parse(current);
    final m = _parse(minimum);
    for (int i = 0; i < 3; i++) {
      if (c[i] < m[i]) return true;
      if (c[i] > m[i]) return false;
    }
    return false;
  }

  static List<int> _parse(String v) {
    final parts = v.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    while (parts.length < 3) parts.add(0);
    return parts;
  }
}

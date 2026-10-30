import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../data/api_client.dart';

/// Result files a user can save or share (C4 / FR-C4).
enum ExportFile {
  video('Annotated video (MP4)', 'annotated.mp4'),
  summary('Summary (JSON)', 'summary.json'),
  hitsCsv('Hits (CSV)', 'hits.csv'),
  ralliesCsv('Rallies (CSV)', 'rallies.csv');

  const ExportFile(this.label, this.fileName);

  final String label;
  final String fileName;

  String url(ApiClient api, String jobId) => switch (this) {
    ExportFile.video => api.videoUrl(jobId),
    ExportFile.summary => api.summaryUrl(jobId),
    ExportFile.hitsCsv => api.hitsCsvUrl(jobId),
    ExportFile.ralliesCsv => api.ralliesCsvUrl(jobId),
  };
}

/// How a platform hands a file to the user.
enum SaveMethod { browser, saveDialog, share }

SaveMethod defaultSaveMethod() {
  if (kIsWeb) return SaveMethod.browser;
  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) return SaveMethod.saveDialog;
  return SaveMethod.share;
}

/// Platform pieces behind an interface so widget tests can replace them.
class SaveTargets {
  const SaveTargets();

  Future<void> openInBrowser(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  /// Save dialog; returns the chosen file path (created empty), or null when cancelled.
  /// The download then streams into it instead of passing the whole file through memory.
  Future<String?> pickSavePath(String fileName) async {
    final uri = await FilePicker.saveFile(
      dialogTitle: 'Save $fileName',
      fileName: fileName,
      bytes: Uint8List(0),
    );
    if (uri == null || uri.scheme != 'file') return null; // desktop dialogs give files
    return uri.toFilePath();
  }

  Future<String> tempPath(String fileName) async =>
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}$fileName';

  Future<void> share(String path, String fileName) =>
      SharePlus.instance.share(ShareParams(files: [XFile(path)], subject: fileName));
}

/// Saves [file] for [jobId]: the browser downloads it on web, a save dialog picks the
/// destination on desktop (the file downloads straight there), and phones download to a
/// temp file and open the share sheet.
/// Returns where the file went (null when cancelled or handed to the browser).
Future<String?> saveExport(
  ApiClient api,
  String jobId,
  ExportFile file, {
  SaveMethod? method,
  SaveTargets targets = const SaveTargets(),
  void Function(double fraction)? onProgress,
}) async {
  final url = file.url(api, jobId);
  final name = '${jobId}_${file.fileName}';
  void progress(int received, int total) {
    if (total > 0) onProgress?.call(received / total);
  }

  switch (method ?? defaultSaveMethod()) {
    case SaveMethod.browser:
      await targets.openInBrowser(url);
      return null;
    case SaveMethod.saveDialog:
      final path = await targets.pickSavePath(name);
      if (path == null) return null;
      try {
        await api.download(url, path, onProgress: progress);
      } catch (_) {
        final partial = File(path); // no half-written file left where the user saved
        if (partial.existsSync()) partial.deleteSync();
        rethrow;
      }
      return path;
    case SaveMethod.share:
      final path = await targets.tempPath(name);
      await api.download(url, path, onProgress: progress);
      await targets.share(path, name);
      return path;
  }
}

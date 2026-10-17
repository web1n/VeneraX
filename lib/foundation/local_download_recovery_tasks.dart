import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/appdata.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/import_comic.dart';
import 'package:venera/utils/local_comic_scanner.dart';
import 'package:venera/utils/translations.dart';

enum LocalDownloadRecoveryStatus { running, completed, canceled, failed }

class LocalDownloadRecoveryTask {
  LocalDownloadRecoveryTask({required this.id, required this.createdAt});

  final String id;
  final DateTime createdAt;
  DateTime? finishedAt;
  LocalDownloadRecoveryStatus status = LocalDownloadRecoveryStatus.running;
  String phase = 'Checking local files';
  int checked = 0;
  int total = 0;
  int imported = 0;
  String? currentTitle;
  String? error;
  bool cancelRequested = false;

  bool get isRunning => status == LocalDownloadRecoveryStatus.running;
  double get progress => total == 0
      ? (status == LocalDownloadRecoveryStatus.completed ? 1 : 0)
      : checked / total;

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'status': status.name,
    'phase': phase,
    'checked': checked,
    'total': total,
    'imported': imported,
    'error': error,
  };

  factory LocalDownloadRecoveryTask.fromJson(Map<String, dynamic> json) =>
      LocalDownloadRecoveryTask(
        id: json['id'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String),
      )
        ..finishedAt = DateTime.tryParse(json['finishedAt'] as String? ?? '')
        ..status = LocalDownloadRecoveryStatus.values.firstWhere(
          (value) => value.name == json['status'],
          orElse: () => LocalDownloadRecoveryStatus.failed,
        )
        ..phase = json['phase'] as String? ?? 'Importing'
        ..checked = (json['checked'] as num?)?.toInt() ?? 0
        ..total = (json['total'] as num?)?.toInt() ?? 0
        ..imported = (json['imported'] as num?)?.toInt() ?? 0
        ..error = json['error'] as String?;
}

/// Owns recovery across dialog dismissal; only one recovery runs at a time.
class LocalDownloadRecoveryTaskManager with ChangeNotifier {
  LocalDownloadRecoveryTaskManager._() {
    try {
      final data = appdata.implicitData['local_download_recovery_history'];
      if (data is List) {
        historyTasks.addAll(data.whereType<Map>().map((value) =>
            LocalDownloadRecoveryTask.fromJson(Map<String, dynamic>.from(value))));
      }
    } catch (e, s) {
      Log.error('Restore Local Downloads', e, s);
    }
  }

  static final instance = LocalDownloadRecoveryTaskManager._();
  static const _keepAliveTag = BackgroundKeepAlive.tagLocalDownloadRecovery;
  final currentTasks = <LocalDownloadRecoveryTask>[];
  final historyTasks = <LocalDownloadRecoveryTask>[];
  LocalDownloadRecoveryScan? _scan;

  LocalDownloadRecoveryTask start({required bool refreshDownloading}) {
    if (currentTasks.firstOrNull case final existing?) return existing;
    final task = LocalDownloadRecoveryTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt: DateTime.now(),
    );
    currentTasks.add(task);
    notifyListeners();
    unawaited(_run(task, refreshDownloading));
    return task;
  }

  void cancel(String id) {
    final task = currentTasks.firstOrNull;
    if (task == null || task.id != id || task.cancelRequested) return;
    task.cancelRequested = true;
    _scan?.cancel();
    notifyListeners();
  }

  Future<void> _run(LocalDownloadRecoveryTask task, bool refreshDownloading) async {
    final manager = LocalManager();
    final generation = manager.availabilityGeneration;
    bool shouldCancel() => task.cancelRequested || !manager.isInitialized ||
        generation != manager.availabilityGeneration;
    final scan = _scan = LocalDownloadRecoveryScan();
    var lastNotification = DateTime.fromMillisecondsSinceEpoch(0);
    void publish() {
      final now = DateTime.now();
      if (now.difference(lastNotification).inMilliseconds >= 200) {
        lastNotification = now;
        BackgroundKeepAlive.instance.update(_keepAliveTag, formatTaskStatus(
          title: 'Restore local downloads'.tl,
          detail: '${task.phase.tl} ${task.checked}/${task.total}',
        ));
      }
      notifyListeners();
    }

    try {
      publish();
      task.imported = await ImportComic(refreshDownloading: refreshDownloading)
          .localDownloads(
        scan: scan,
        shouldCancel: shouldCancel,
        onProgress: (phase, checked, total, title, imported) {
          task.phase = phase;
          task.checked = checked;
          task.total = total;
          task.currentTitle = title;
          task.imported = imported;
          publish();
          // Stop an active scan too if the storage path changed.
          if (shouldCancel()) scan.cancel();
        },
      );
      task.status = shouldCancel()
          ? LocalDownloadRecoveryStatus.canceled
          : LocalDownloadRecoveryStatus.completed;
    } catch (e, s) {
      task.status = shouldCancel()
          ? LocalDownloadRecoveryStatus.canceled
          : LocalDownloadRecoveryStatus.failed;
      if (!shouldCancel()) task.error = e.toString();
      Log.error('Restore Local Downloads', e, s);
    } finally {
      _scan = null;
      task.currentTitle = null;
      task.finishedAt = DateTime.now();
      currentTasks.remove(task);
      historyTasks.insert(0, task);
      if (historyTasks.length > 50) historyTasks.removeRange(50, historyTasks.length);
      _saveHistory();
      BackgroundKeepAlive.instance.remove(_keepAliveTag);
      notifyListeners();
    }
  }

  void _saveHistory() {
    appdata.implicitData['local_download_recovery_history'] =
        historyTasks.map((task) => task.toJson()).toList();
    appdata.writeImplicitData();
  }

  void clearHistory() {
    historyTasks.clear();
    _saveHistory();
    notifyListeners();
  }

  void removeTask(String id) {
    historyTasks.removeWhere((task) => task.id == id);
    _saveHistory();
    notifyListeners();
  }
}

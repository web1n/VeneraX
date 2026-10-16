import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:venera/foundation/background_keepalive.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

enum LocalLibraryRefreshStatus { running, completed, canceled, failed }

class LocalLibraryRefreshTask {
  LocalLibraryRefreshTask({required this.id, required this.createdAt});

  final String id;
  final DateTime createdAt;
  DateTime? finishedAt;
  LocalLibraryRefreshStatus status = LocalLibraryRefreshStatus.running;
  int total = 0;
  int checked = 0;
  int downloaded = 0;
  int missing = 0;
  int failed = 0;
  String? currentTitle;
  String? error;

  bool get isRunning => status == LocalLibraryRefreshStatus.running;
  double get progress => total == 0 ? 0 : checked / total;

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'status': status.name,
    'total': total,
    'checked': checked,
    'downloaded': downloaded,
    'missing': missing,
    'failed': failed,
    'error': error,
  };

  factory LocalLibraryRefreshTask.fromJson(Map<String, dynamic> json) {
    return LocalLibraryRefreshTask(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['createdAt'] as String),
    )
      ..finishedAt = DateTime.tryParse(json['finishedAt'] as String? ?? '')
      ..status = LocalLibraryRefreshStatus.values.firstWhere(
        (status) => status.name == json['status'],
        orElse: () => LocalLibraryRefreshStatus.failed,
      )
      ..total = (json['total'] as num?)?.toInt() ?? 0
      ..checked = (json['checked'] as num?)?.toInt() ?? 0
      ..downloaded = (json['downloaded'] as num?)?.toInt() ?? 0
      ..missing = (json['missing'] as num?)?.toInt() ?? 0
      ..failed = (json['failed'] as num?)?.toInt() ?? 0
      ..error = json['error'] as String?;
  }
}

class LocalLibraryRefreshTaskManager with ChangeNotifier {
  LocalLibraryRefreshTaskManager._() {
    try {
      historyTasks.addAll(LocalManager().availabilityStore.loadHistory()
          .map(LocalLibraryRefreshTask.fromJson));
    } catch (e, s) {
      Log.error('Local Library Refresh', e, s);
    }
  }

  static final instance = LocalLibraryRefreshTaskManager._();
  final currentTasks = <LocalLibraryRefreshTask>[];
  final historyTasks = <LocalLibraryRefreshTask>[];
  Isolate? _worker;
  ReceivePort? _port;
  bool _cancelRequested = false;

  LocalLibraryRefreshTask? get _currentTask => currentTasks.firstOrNull;

  LocalLibraryRefreshTask start() {
    if (_currentTask case final existing?) return existing;
    final task = LocalLibraryRefreshTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      createdAt: DateTime.now(),
    );
    _cancelRequested = false;
    currentTasks.add(task);
    notifyListeners();
    unawaited(_run(task));
    return task;
  }

  void cancel(String id) {
    if (_currentTask?.id != id) return;
    _cancelRequested = true;
    _worker?.kill(priority: Isolate.immediate);
    _port?.close();
    notifyListeners();
  }

  Future<void> _run(LocalLibraryRefreshTask task) async {
    final manager = LocalManager();
    final generation = manager.availabilityGeneration;
    final entries = <(LocalComic, String, int)>[];
    final pending = <(LocalComic, String, int, bool)>[];
    var lastPublish = DateTime.now();

    void publish() {
      if (manager.isInitialized &&
          generation == manager.availabilityGeneration) {
        manager.availabilityStore.batch(() {
          for (final (comic, path, version, available) in pending) {
            // A download/delete/import or storage change that happened after
            // this snapshot takes precedence over its scan result.
            if (manager.availabilityVersion(comic.id, comic.comicType) != version ||
                manager.isDownloading(comic.id, comic.comicType)) continue;
            final current = manager.find(comic.id, comic.comicType);
            if (current == null || current.baseDir != path) continue;
            manager.availabilityStore.set(
              comic.id, comic.comicType.value, path, available,
            );
          }
        });
        if (pending.isNotEmpty) manager.publishAvailabilityChanges();
      }
      pending.clear();
      lastPublish = DateTime.now();
      if (task.isRunning && !_cancelRequested && task.total > 0) {
        BackgroundKeepAlive.instance.update(
          BackgroundKeepAlive.tagLocalLibraryRefresh,
          formatTaskStatus(
            title: 'Refresh Local Status'.tl,
            detail: 'Checked @checked/@total'.tlParams({
              'checked': task.checked, 'total': task.total,
            }),
          ),
        );
      }
      notifyListeners();
    }

    try {
      for (final comic in manager.getComics(LocalSortType.defaultSort)) {
        if (comic.directory.isEmpty ||
            manager.isDownloading(comic.id, comic.comicType)) continue;
        entries.add((comic, comic.baseDir,
            manager.availabilityVersion(comic.id, comic.comicType)));
      }
      task.total = entries.length;
      if (entries.isNotEmpty) {
        publish();
        final port = _port = ReceivePort();
        final worker = await Isolate.spawn(
          _scanLibraryDirectories,
          (port.sendPort, entries.map((entry) => entry.$2).toList()),
          onError: port.sendPort,
          onExit: port.sendPort,
          errorsAreFatal: true,
        );
        _worker = worker;
        if (_cancelRequested) worker.kill(priority: Isolate.immediate);
        if (!_cancelRequested) {
          await for (final message in port) {
            if (_cancelRequested || !manager.isInitialized ||
                generation != manager.availabilityGeneration) break;
            if (message == null) break;
            if (message is List) {
              task.error = message.first.toString();
              throw StateError(task.error!);
            }
            final result = message as Map;
            final index = result['index'] as int;
            final (comic, path, version) = entries[index];
            task.currentTitle = comic.title;
            task.checked++;
            final available = result['available'] as bool?;
            if (available == null) {
              task.failed++;
              task.error ??= '${comic.title}: ${result['error']}';
            } else {
              if (available) {
                task.downloaded++;
              } else {
                task.missing++;
              }
              pending.add((comic, path, version, available));
            }
            if (task.checked == task.total ||
                DateTime.now().difference(lastPublish).inMilliseconds >= 150) {
              publish();
            }
          }
        }
      }
      if (_cancelRequested || generation != manager.availabilityGeneration) {
        task.status = LocalLibraryRefreshStatus.canceled;
      } else if (task.failed > 0 || task.checked != task.total) {
        task.status = LocalLibraryRefreshStatus.failed;
      } else {
        task.status = LocalLibraryRefreshStatus.completed;
      }
    } catch (e, s) {
      task.status = _cancelRequested
          ? LocalLibraryRefreshStatus.canceled
          : LocalLibraryRefreshStatus.failed;
      task.error = e.toString();
      Log.error('Local Library Refresh', e, s);
    } finally {
      _worker?.kill(priority: Isolate.immediate);
      _port?.close();
      _worker = null;
      _port = null;
      try {
        publish();
      } catch (e, s) {
        task.status = LocalLibraryRefreshStatus.failed;
        task.error = e.toString();
        Log.error('Local Library Refresh', e, s);
      }
      task.currentTitle = null;
      task.finishedAt = DateTime.now();
      currentTasks.remove(task);
      historyTasks.insert(0, task);
      if (historyTasks.length > 50) historyTasks.removeRange(50, historyTasks.length);
      _saveHistory();
      BackgroundKeepAlive.instance.remove(
        BackgroundKeepAlive.tagLocalLibraryRefresh,
      );
      notifyListeners();
    }
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

  void _saveHistory() {
    try {
      LocalManager().availabilityStore.saveHistory(historyTasks.map((task) => task.toJson()));
    } catch (e, s) {
      Log.error('Local Library Refresh', e, s);
    }
  }
}

/// Only paths and primitive results cross the isolate boundary. The worker
/// never opens a database or holds the UI's LocalManager/SQLite connection.
void _scanLibraryDirectories((SendPort, List<String>) request) {
  final (port, paths) = request;
  overrideIO(() {
    for (var i = 0; i < paths.length; i++) {
      try {
        final dir = Directory(paths[i]);
        final available = dir.existsSync() && dir.listSync().any((entity) =>
            entity is File ||
            (entity is Directory && entity.listSync().isNotEmpty));
        port.send({'index': i, 'available': available});
      } catch (e) {
        // Permission/storage failures are not proof that files were deleted.
        port.send({'index': i, 'available': null, 'error': e.toString()});
      }
    }
  });
}

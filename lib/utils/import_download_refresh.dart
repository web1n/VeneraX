import 'dart:isolate';

import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/io.dart';

/// Import-only opt-in. Only explicitly paused, untouched tasks are eligible;
/// running tasks and tasks waiting for an automatic queue slot are left alone.
class ImportDownloadRefresh {
  ImportDownloadRefresh() {
    final manager = LocalManager();
    generation = manager.availabilityGeneration;
    candidates = manager.downloadingTasks.whereType<ImagesDownloadTask>()
        .where((task) => task.isPaused && task.userPaused &&
            manager.canRefreshUnstartedDownload(task)).toList();
  }

  late final int generation;
  late final List<ImagesDownloadTask> candidates;

  Future<LocalComic?> refresh(
    LocalComic imported, {bool Function()? shouldCancel}
  ) async {
    if (shouldCancel?.call() == true) return null;
    final manager = LocalManager();
    if (!manager.isInitialized || generation != manager.availabilityGeneration) return null;
    final folder = Directory(imported.baseDir).name;
    final matches = candidates.where((task) {
      final title = task.comic?.title ?? task.comicTitle;
      final taskFolder = task.path == null ? null : Directory(task.path!).name;
      return (title != null && title == imported.title) || taskFolder == folder;
    }).toList();
    // A name shared by several source tasks is ambiguous; ordinary import
    // still works, but no queue entry is changed.
    if (matches.length != 1) return null;
    final task = matches.single;
    if (!task.isPaused || !task.userPaused ||
        !manager.canRefreshUnstartedDownload(task) ||
        !manager.downloadingTasks.any((item) => identical(item, task))) return null;
    final originalPath = task.path;
    final version = manager.availabilityVersion(task.id, task.comicType);
    try {
      var details = task.comic;
      if (details == null) {
        final loadInfo = task.source.loadComicInfo;
        if (loadInfo == null) return null;
        final result = await loadInfo(task.comicId);
        if (result.error) return null;
        details = result.data;
      }
      final ids = details.chapters == null ? <String>['']
          : details.chapters!.ids.where((id) =>
              task.chapters == null || task.chapters!.contains(id)).toList();
      final (found, bodyImage) = await _findImportedChapters(
        originalPath, imported.baseDir, ids,
      );
      if (shouldCancel?.call() == true || !manager.isInitialized ||
          generation != manager.availabilityGeneration || task.path != originalPath ||
          manager.availabilityVersion(task.id, task.comicType) != version ||
          found.isEmpty) return null;
      final count = manager.refreshUnstartedDownload(
        task,
        storagePath: imported.baseDir,
        details: details,
        foundChapters: found,
        bodyImage: bodyImage,
      );
      if (count == 0) return null;
      candidates.remove(task);
      await manager.saveCurrentDownloadingTasks();
      return manager.find(task.id, task.comicType);
    } catch (error, stack) {
      Log.error('Import Download Refresh', error, stack);
      return null;
    }
  }
}

Future<(List<String>, String?)> _findImportedChapters(
  String? originalPath, String importedPath, List<String> chapterIds,
) {
  return Isolate.run(() => overrideIO(() {
    String? bodyImage(String path) {
      final dir = Directory(path);
      if (!dir.existsSync()) return null;
      for (final file in dir.listSync().whereType<File>()) {
        if (!file.name.toLowerCase().startsWith('cover') &&
            const {'jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe', 'avif', 'bmp'}
                .contains(file.extension.toLowerCase())) return file.name;
      }
      return null;
    }

    // Progress can still be zero after an out-of-order page completed before
    // an app restart. Existing body files in the original path exclude it too.
    if (originalPath != null) {
      if (bodyImage(originalPath) != null) return (<String>[], null);
      final original = Directory(originalPath);
      if (original.existsSync()) {
        for (final child in original.listSync().whereType<Directory>()) {
          if (bodyImage(child.path) != null) return (<String>[], null);
        }
      }
    }
    final found = <String>[];
    String? firstImage;
    for (final id in chapterIds) {
      final chapter = id.isEmpty ? '' : LocalManager.getChapterDirectoryName(id);
      final image = bodyImage(chapter.isEmpty ? importedPath
          : FilePath.join(importedPath, chapter));
      if (image == null) continue;
      found.add(id);
      firstImage ??= chapter.isEmpty ? image : FilePath.join(chapter, image);
    }
    return (found, firstImage);
  }));
}

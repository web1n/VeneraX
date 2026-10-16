import 'dart:isolate';

import 'package:flutter_saf/flutter_saf.dart';
import 'package:venera/foundation/comic_source/comic_source.dart';
import 'package:venera/foundation/comic_type.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/foundation/log.dart';
import 'package:venera/utils/comic_metadata_resolver.dart';
import 'package:venera/utils/io.dart';

const _localComicImageExtensions = {'jpg', 'jpeg', 'png', 'webp', 'gif', 'jpe'};

/// Owns a single recovery scan. Only directory discovery/metadata parsing run
/// here; application databases remain on their existing owning isolate.
class LocalDownloadRecoveryScan {
  Isolate? _worker;
  SendPort? _cancelPort;
  bool _canceled = false;

  void cancel() {
    _canceled = true;
    _cancelPort?.send(true);
  }

  Future<List<LocalComic>> scan(
    String path,
    Set<String> knownNames,
    Set<String> knownPaths, {
    required void Function(int checked, int total) onProgress,
  }) async {
    final port = ReceivePort();
    final comics = <LocalComic>[];
    var finished = false;
    try {
      final worker = await Isolate.spawn(
        _scanRecoverableDownloads,
        (port.sendPort, path, knownNames, knownPaths),
        onError: port.sendPort,
        onExit: port.sendPort,
        errorsAreFatal: true,
      );
      _worker = worker;
      await for (final message in port) {
        if (message == null) break;
        if (message is List) throw StateError(message.first.toString());
        final result = message as Map;
        if (result['control'] case final SendPort control) {
          _cancelPort = control;
          if (_canceled) control.send(true);
          continue;
        }
        if (result['done'] == true) {
          finished = true;
          break;
        }
        if (_canceled) continue;
        if (result['comic'] case final LocalComic comic) comics.add(comic);
        onProgress(result['checked'] as int, result['total'] as int);
      }
      if (!finished && !_canceled) {
        throw StateError('Local download recovery scan stopped unexpectedly');
      }
      return comics;
    } finally {
      _worker?.kill(priority: Isolate.immediate);
      port.close();
      _worker = null;
      _cancelPort = null;
    }
  }
}

Future<void> _scanRecoverableDownloads(
  (SendPort, String, Set<String>, Set<String>) request,
) async {
  final (port, path, knownNames, knownPaths) = request;
  final control = ReceivePort();
  var canceled = false;
  control.listen((_) => canceled = true);
  port.send({'control': control.sendPort});
  final saf = Platform.isAndroid ? SAFTaskWorker() : null;
  try {
    if (saf != null) await saf.init();
    await overrideIO(() async {
      final directories = (await Directory(path).list().toList())
          .whereType<Directory>().toList();
      var checked = 0;
      for (final directory in directories) {
        if (canceled) break;
        LocalComic? comic;
        if (!knownPaths.contains(directory.path)) {
          var createTime = DateTime.now();
          try {
            createTime = (await directory.stat()).modified;
          } on UnimplementedError {
            // Android SAF directories do not expose file timestamps.
          }
          comic = await scanLocalComicDirectory(
            directory,
            createTime: createTime,
            useRelativePath: true,
            rejectExisting: false,
          );
          if (comic != null && knownNames.contains(comic.title)) comic = null;
        }
        checked++;
        port.send({'comic': comic, 'checked': checked, 'total': directories.length});
      }
    });
  } finally {
    saf?.dispose();
    control.close();
  }
  // Signal completion after disposing the SAF child worker, including cancel.
  port.send({'done': true});
}

bool _isLocalComicImage(File file) {
  final name = file.name.toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot >= 0 &&
      _localComicImageExtensions.contains(name.substring(dot + 1));
}

/// Scans a local comic directory without writing any application state.
///
/// Passing [previous] refreshes an existing comic: stable identity and storage
/// fields are preserved while metadata, cover, and chapters come from disk.
Future<LocalComic?> scanLocalComicDirectory(
  Directory directory, {
  LocalComic? previous,
  String? id,
  String? title,
  String? subtitle,
  List<String>? tags,
  DateTime? createTime,
  bool useRelativePath = false,
  bool rejectExisting = true,
}) async {
  if (!await directory.exists()) return null;

  final metadata = resolveMetadataOrNull(directory);
  final resolvedTitle =
      title ??
      ((metadata?.title.isNotEmpty ?? false)
          ? metadata!.title
          : previous?.title ?? directory.name);
  if (previous == null &&
      rejectExisting &&
      LocalManager().findByName(resolvedTitle) != null) {
    Log.info('Import Comic', 'Comic already exists: $resolvedTitle');
    return null;
  }

  final chapterDirectories = <Directory>[];
  final rootImages = <File>[];
  await for (final entry in directory.list()) {
    if (entry is Directory) {
      await for (final child in entry.list()) {
        if (child is Directory) {
          Log.info(
            'Import Comic',
            'Invalid Chapter: ${entry.name}\nA directory is found in the chapter directory.',
          );
          return null;
        }
      }
      chapterDirectories.add(entry);
    } else if (entry is File && _isLocalComicImage(entry)) {
      rootImages.add(entry);
    }
  }

  chapterDirectories.sort((a, b) => a.name.compareTo(b.name));
  rootImages.sort((a, b) => a.name.compareTo(b.name));

  String? coverPath;
  for (final image in rootImages) {
    if (image.name.toLowerCase().startsWith('cover')) {
      coverPath = image.name;
      break;
    }
  }
  coverPath ??= rootImages.isEmpty ? null : rootImages.first.name;

  if (coverPath == null && chapterDirectories.isNotEmpty) {
    for (final chapterDirectory in chapterDirectories) {
      final chapterImages = <File>[];
      await for (final entry in chapterDirectory.list()) {
        if (entry is File && _isLocalComicImage(entry)) {
          chapterImages.add(entry);
        }
      }
      chapterImages.sort((a, b) => a.name.compareTo(b.name));
      if (chapterImages.isNotEmpty) {
        coverPath = FilePath.join(
          chapterDirectory.name,
          chapterImages.first.name,
        );
        break;
      }
    }
  }

  if (coverPath == null) {
    Log.info(
      'Import Comic',
      'Invalid Comic: $resolvedTitle\nNo cover image found.',
    );
    return null;
  }

  final chapterNames = chapterDirectories.map((dir) => dir.name).toList();
  final resolvedSubtitle = (subtitle?.isNotEmpty ?? false)
      ? subtitle!
      : metadata != null
      ? (metadata.author.isNotEmpty ? metadata.author : metadata.artist)
      : previous?.subtitle ?? '';
  final resolvedTags = (tags?.isNotEmpty ?? false)
      ? List<String>.from(tags!)
      : metadata != null
      ? List<String>.from(metadata.tags)
      : List<String>.from(previous?.tags ?? const []);
  final storedDirectory =
      previous?.directory ??
      (useRelativePath ? directory.name : directory.path);

  return LocalComic(
    id: id ?? previous?.id ?? '0',
    title: resolvedTitle,
    subtitle: resolvedSubtitle,
    tags: resolvedTags,
    directory: storedDirectory,
    chapters: chapterNames.isEmpty
        ? null
        : ComicChapters(Map.fromIterables(chapterNames, chapterNames)),
    cover: coverPath,
    comicType: previous?.comicType ?? ComicType.local,
    downloadedChapters: chapterNames,
    createdAt: createTime ?? previous?.createdAt ?? DateTime.now(),
    description: metadata?.description ?? previous?.description ?? '',
  );
}

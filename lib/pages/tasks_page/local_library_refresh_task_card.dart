part of '../tasks_page.dart';

mixin _LocalLibraryRefreshTaskCard on _TaskCardCommon {
  LocalLibraryRefreshTaskManager get localLibraryRefreshManager;

  Widget buildLocalLibraryRefreshTaskCard(
    LocalLibraryRefreshTask task, {
    required bool expanded,
  }) {
    final status = switch (task.status) {
      LocalLibraryRefreshStatus.running => "Running".tl,
      LocalLibraryRefreshStatus.completed => "Completed".tl,
      LocalLibraryRefreshStatus.canceled => "Canceled".tl,
      LocalLibraryRefreshStatus.failed => "Failed".tl,
    };
    final progressText =
        "${(task.progress * 100).clamp(0, 100).toStringAsFixed(0)}%";
    final card = Card(
      elevation: 0,
      color: context.colorScheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: _TaskExpansionTile(
        initiallyExpanded: expanded,
        leading: _wrapIconWithRotation(
          getTaskIcon(
            'local_library_refresh',
            task.isRunning,
            status: task.status.name,
          ),
          task.isRunning,
          task.status.name,
        ),
        title: Text(getTaskTitle('local_library_refresh', {})),
        subtitle: buildTaskSubtitle(
          [status, '${task.checked}/${task.total}', progressText],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: task.isRunning
            ? TextButton(
                onPressed: () => localLibraryRefreshManager.cancel(task.id),
                child: Text("Cancel".tl),
              )
            : null,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: LinearProgressIndicator(
              value: task.isRunning && task.total == 0 ? null : task.progress,
            ),
          ),
          const SizedBox(height: 8),
          buildSourceBox(
            title: "Details".tl,
            children: [
              Text(
                "Total: @total  Checked: @checked  Downloaded: @downloaded  Missing: @missing  Failed: @failed"
                    .tlParams({
                      'total': task.total,
                      'checked': task.checked,
                      'downloaded': task.downloaded,
                      'missing': task.missing,
                      'failed': task.failed,
                    }),
                style: ts.s14,
              ),
              if (task.isRunning && task.currentTitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  task.currentTitle!,
                  style: ts.s14,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (task.error != null) ...[
                const SizedBox(height: 2),
                Text(
                  task.error!,
                  style: ts.s14.withColor(context.colorScheme.error),
                ),
              ],
            ],
          ),
        ],
      ),
    );
    return _wrapHistoryCard(
      card,
      'local_library_refresh',
      task.id,
      task.isRunning,
    );
  }
}

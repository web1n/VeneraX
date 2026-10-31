part of '../tasks_page.dart';

mixin _LocalDownloadRecoveryTaskCard on _TaskCardCommon {
  LocalDownloadRecoveryTaskManager get localDownloadRecoveryManager;

  Widget buildLocalDownloadRecoveryTaskCard(LocalDownloadRecoveryTask task) {
    final status = switch (task.status) {
      LocalDownloadRecoveryStatus.running =>
        task.cancelRequested ? 'Canceling'.tl : task.phase.tl,
      LocalDownloadRecoveryStatus.completed => 'Completed'.tl,
      LocalDownloadRecoveryStatus.canceled => 'Canceled'.tl,
      LocalDownloadRecoveryStatus.failed => 'Failed'.tl,
    };
    final card = Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      child: _TaskExpansionTile(
        initiallyExpanded: task.id == widget.initialExpandedTaskId,
        leading: Icon(
          getTaskIcon(
            'local_download_recovery',
            task.isRunning,
            status: task.status.name,
          ),
        ),
        title: Text('Restore local downloads'.tl),
        subtitle: buildTaskSubtitle(
          [status, '${task.checked}/${task.total}'],
          task.createdAt,
          task.finishedAt,
        ),
        trailing: task.isRunning
            ? TextButton(
                onPressed: task.cancelRequested
                    ? null
                    : () => localDownloadRecoveryManager.cancel(task.id),
                child: Text('Cancel'.tl),
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
            title: 'Details'.tl,
            children: [
              Text('Imported @a comics'.tlParams({'a': task.imported})),
              if (task.currentTitle != null) Text(task.currentTitle!),
              if (task.error != null)
                Text(
                  task.error!,
                  style: TextStyle(color: context.colorScheme.error),
                ),
            ],
          ),
        ],
      ),
    );
    return _wrapHistoryCard(
      card,
      'local_download_recovery',
      task.id,
      task.isRunning,
    );
  }
}

import 'dart:async';

import 'package:cake_wallet/entities/hop_step.dart';
import 'package:cake_wallet/entities/hop_task.dart';
import 'package:cw_core/utils/print_verbose.dart';

/// Outcome of executing a single hop step.
class HopExecutionResult {
  HopExecutionResult.ok(this.txHash) : success = true, error = null;
  HopExecutionResult.failed(this.error) : success = false, txHash = null;

  final bool success;
  final String? txHash;
  final String? error;
}

/// Pluggable per-step executor. The engine owns scheduling + persistence; the
/// executor owns the actual value transfer (send / bridge / exchange).
abstract class HopExecutor {
  /// Execute one hop step. Must be idempotent-ish: if it throws the engine
  /// keeps the step pending and retries on the next tick.
  Future<HopExecutionResult> execute(HopTask task, HopStep step);
}

/// Persistent chain-hopping scheduler.
///
/// A single instance drives every active task. It is intended to be started
/// once in the foreground and lightly ticked from the native background entry
/// point (`backgroundSync` in main.dart). Everything it needs lives in SQLite,
/// so an app restart or a background wake resumes exactly where it left off.
class HopEngine {
  HopEngine(this._executor);

  final HopExecutor _executor;

  Timer? _timer;
  bool _busy = false;

  /// Guards against two overlapping runs (e.g. foreground timer + bg wake).
  bool get isBusy => _busy;

  /// How often the foreground loop checks for due steps.
  static const tickInterval = Duration(seconds: 30);

  /// A step is "due" once its scheduled wall-clock time has passed.
  static const lateGrace = Duration(hours: 6);

  /// Start the foreground loop. Safe to call multiple times.
  void start() {
    _timer?.cancel();
    _timer = Timer.periodic(tickInterval, (_) => runOnce());
    // Fire immediately so a task whose window already opened catches up.
    unawaited(runOnce());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void dispose() => stop();

  /// One scheduling pass. Picks the single most-due pending step across all
  /// active tasks and executes it. Re-entrant calls are dropped.
  Future<void> runOnce() async {
    if (_busy) return;
    _busy = true;
    try {
      final tasks = await HopTask.selectActive();
      if (tasks.isEmpty) return;

      for (final task in tasks) {
        if (!task.isActive) continue;

        final now = DateTime.now();
        if (now.isBefore(task.startAt)) continue;

        if (task.status == HopTaskStatus.pending) {
          task.status = HopTaskStatus.running;
          task.updatedAt = now;
          await HopTask.update(task);
        }

        final steps = await HopStep.forTask(task.id);
        if (steps.isEmpty) continue;

        final pending = steps.where((s) => s.status == HopStepStatus.pending).toList()
          ..sort((a, b) => a.stepIndex.compareTo(b.stepIndex));
        if (pending.isEmpty) {
          await _finalizeIfDone(task, steps);
          continue;
        }

        // Wait until the task's end window too, so hops are spread, not burst.
        final next = pending.first;
        final dueAt = task.startAt.add(Duration(seconds: next.delaySeconds));
        if (now.isBefore(dueAt)) continue;

        // Relay gate: a hop may only fire once the previous hop settled. This
        // is what turns a fan-out into a real chain.
        final previous = _previousStep(steps, next);
        if (previous != null && previous.status != HopStepStatus.completed) {
          if (previous.status == HopStepStatus.failed) {
            next.status = HopStepStatus.failed;
            next.errorMessage = 'Previous hop failed';
            next.executedAt = now;
            await HopStep.update(next);
          }
          continue;
        }

        // Too late to safely execute? Mark failed rather than fire stale hops.
        if (now.difference(dueAt) > lateGrace) {
          next.status = HopStepStatus.failed;
          next.errorMessage = 'Missed execution window';
          next.executedAt = now;
          await HopStep.update(next);
          continue;
        }

        if (previous != null && previous.settledAt == null) {
          previous.settledAt = now;
          await HopStep.update(previous);
        }

        await _executeStep(task, next);
        // One step per tick keeps ordering deterministic and avoids a burst.
        return;
      }
    } catch (e, st) {
      printV('HopEngine.runOnce error: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  HopStep? _previousStep(List<HopStep> steps, HopStep current) {
    for (final s in steps) {
      if (s.stepIndex == current.stepIndex - 1) return s;
    }
    return null;
  }

  Future<void> _executeStep(HopTask task, HopStep step) async {
    // A step left in `running` from a previous crash is retried from scratch.
    if (step.status != HopStepStatus.running) {
      step.status = HopStepStatus.running;
      await HopStep.update(step);
    } else {
      step.status = HopStepStatus.pending;
      step.errorMessage = 'Recovered stale running step';
      await HopStep.update(step);
      step.status = HopStepStatus.running;
      await HopStep.update(step);
    }

    try {
      final result = await _executor.execute(task, step);
      if (result.success) {
        step.status = HopStepStatus.completed;
        step.txHash = result.txHash;
        step.executedAt = DateTime.now();
        step.errorMessage = null;
      } else {
        step.status = HopStepStatus.pending; // retry next tick
        step.errorMessage = result.error;
        step.executedAt = null;
      }
    } catch (e) {
      step.status = HopStepStatus.pending;
      step.errorMessage = e.toString();
      step.executedAt = null;
    }
    await HopStep.update(step);

    if (step.status == HopStepStatus.completed) {
      final steps = await HopStep.forTask(task.id);
      await _finalizeIfDone(task, steps);
    }
  }

  Future<void> _finalizeIfDone(HopTask task, List<HopStep> steps) async {
    if (steps.isEmpty) return;
    final anyPending = steps.any((s) => !s.isSettled);
    if (anyPending) return;

    final anyFailed = steps.any((s) => s.status == HopStepStatus.failed);
    task.status = anyFailed ? HopTaskStatus.failed : HopTaskStatus.completed;
    task.updatedAt = DateTime.now();
    if (anyFailed) {
      task.errorMessage = steps
          .firstWhere((s) => s.status == HopStepStatus.failed)
          .errorMessage;
    }
    await HopTask.update(task);
  }

  /// Cancel a task: stop scheduling and clear remaining pending steps.
  Future<void> cancel(String taskId) async {
    final task = await HopTask.getById(taskId);
    if (task == null) return;
    task.status = HopTaskStatus.cancelled;
    task.updatedAt = DateTime.now();
    await HopTask.update(task);

    final steps = await HopStep.forTask(taskId);
    for (final step in steps) {
      if (step.status == HopStepStatus.pending || step.status == HopStepStatus.running) {
        step.status = HopStepStatus.failed;
        step.errorMessage = 'Cancelled by user';
        await HopStep.update(step);
      }
    }
  }
}

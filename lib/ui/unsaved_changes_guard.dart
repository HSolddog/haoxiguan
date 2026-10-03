import 'package:flutter/material.dart';

/// Keeps a draft on screen until the user explicitly discards it.
/// Route gestures and explicit cancel buttons must call [leave].
class UnsavedChangesGuard extends StatefulWidget {
  const UnsavedChangesGuard({
    super.key,
    required this.dirty,
    required this.saving,
    required this.child,
    this.isDirty,
    this.isSaving,
  });

  final bool dirty;
  final bool Function()? isDirty;
  final bool Function()? isSaving;
  final bool saving;
  final Widget child;

  @override
  State<UnsavedChangesGuard> createState() => UnsavedChangesGuardState();
}

class UnsavedChangesGuardState extends State<UnsavedChangesGuard> {
  bool _asking = false;

  Future<bool> requestLeave() async {
    if ((widget.isSaving?.call() ?? widget.saving) || _asking) return false;
    if (!(widget.isDirty?.call() ?? widget.dirty)) return true;
    _asking = true;
    var answered = false;
    void answer(BuildContext dialogContext, bool discard) {
      if (answered ||
          !dialogContext.mounted ||
          ModalRoute.of(dialogContext)?.isCurrent != true) {
        return;
      }
      answered = true;
      Navigator.pop(dialogContext, discard);
    }

    try {
      return await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('保留未保存的修改？'),
              content: const Text('继续编辑会保留当前输入。放弃修改后，本次输入不会保存。'),
              actions: [
                TextButton(
                  key: const Key('keep-editing-button'),
                  onPressed: () => answer(context, false),
                  child: const Text('继续编辑'),
                ),
                TextButton(
                  key: const Key('discard-changes-button'),
                  onPressed: () => answer(context, true),
                  child: const Text('放弃修改'),
                ),
              ],
            ),
          ) ??
          false;
    } finally {
      _asking = false;
    }
  }

  Future<void> leave() async {
    final route = ModalRoute.of(context);
    final discard = await requestLeave();
    if (mounted &&
        discard &&
        route?.isCurrent == true &&
        !(widget.isSaving?.call() ?? widget.saving)) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) => PopScope<void>(
    // Inspect the live draft even when a back event arrives before the next
    // frame has rebuilt this widget following an input event.
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) leave();
    },
    child: widget.child,
  );
}

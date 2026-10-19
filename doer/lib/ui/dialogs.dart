import 'package:flutter/material.dart';

Future<bool> confirmAction(BuildContext context, String message) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    ) ??
    false;

Future<T> withProgress<T>(
  BuildContext context,
  Future<T> Function() action, {
  String label = 'Planning your week…',
}) async {
  final navigator = Navigator.of(context, rootNavigator: true);
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        constraints: const BoxConstraints(maxWidth: 360),
        title: Text(label),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('This usually takes 5–30 seconds.'),
            SizedBox(height: 24),
            LinearProgressIndicator(),
          ],
        ),
      ),
    ),
  );
  navigator.push(route);
  try {
    return await action();
  } finally {
    navigator.removeRoute(route);
  }
}

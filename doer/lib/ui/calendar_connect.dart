import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_services.dart';
import 'widgets.dart';

Future<void> connectCalendar(
  BuildContext context,
  AppServices services,
  String app,
) async {
  final url = await services.connected!.connectUrl(app);
  if (!await launchUrl(url, webOnlyWindowName: '_blank')) {
    throw Exception(
      'Could not open calendar connection. Allow pop-ups and try again.',
    );
  }
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          "Finish in the new tab, then come back — we'll refresh automatically.",
        ),
      ),
    );
  }
}

Future<void> showCalendarConnect(
  BuildContext context,
  AppServices services, {
  bool notConfigured = false,
  bool initialLink = false,
}) async {
  final subscription = TextEditingController();

  var link = initialLink;
  var busy = false;
  String? error;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    constraints: const BoxConstraints(maxWidth: 720),
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, update) {
        Future<void> run(Future<void> Function() action) async {
          update(() {
            busy = true;
            error = null;
          });
          try {
            await action();
            if (sheetContext.mounted) Navigator.pop(sheetContext);
          } catch (e) {
            if (sheetContext.mounted) {
              update(() {
                error = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
                if (error ==
                    'Calendar connections are not configured on this server') {
                  error = "Calendar connections aren't set up on this server.";
                  notConfigured = true;
                }
                busy = false;
              });
            }
          }
        }

        Future<void> addLink() => run(() async {
          await services.connected!.addIcsUrl(subscription.text);
          subscription.clear();
        });

        return SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              20,
              8,
              20,
              24 + MediaQuery.viewInsetsOf(context).bottom,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Connect a calendar',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  if (busy) const LinearProgressIndicator(),
                  if (error != null) Notice(error!, error: !notConfigured),
                  ListTile(
                    leading: const Icon(Icons.calendar_month),
                    title: const Text('Google Calendar'),
                    subtitle: notConfigured
                        ? const Text('Not set up on this server')
                        : null,
                    trailing: const Icon(Icons.chevron_right),
                    enabled: !busy && !notConfigured,
                    onTap: () => run(
                      () =>
                          connectCalendar(context, services, 'google_calendar'),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.calendar_today),
                    title: const Text('Outlook / Microsoft 365'),
                    subtitle: notConfigured
                        ? const Text('Not set up on this server')
                        : null,
                    trailing: const Icon(Icons.chevron_right),
                    enabled: !busy && !notConfigured,
                    onTap: () => run(
                      () => connectCalendar(
                        context,
                        services,
                        'microsoft_outlook_calendar',
                      ),
                    ),
                  ),
                  ListTile(
                    leading: const Icon(Icons.link),
                    title: const Text(
                      'Any calendar by link (iCloud, Fastmail, Proton…)',
                    ),
                    trailing: Icon(
                      link ? Icons.expand_less : Icons.expand_more,
                    ),
                    enabled: !busy,
                    onTap: () => update(() => link = !link),
                  ),
                  if (link) ...[
                    const SizedBox(height: 16),
                    TextField(
                      controller: subscription,
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) {
                        if (!busy) addLink();
                      },
                      enabled: !busy,
                      decoration: const InputDecoration(
                        labelText: 'Calendar URL',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'iCloud: Calendar app → Share calendar → Public Calendar → copy link.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: busy ? null : addLink,
                      child: const Text('Add'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
  subscription.dispose();
}

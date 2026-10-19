import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import 'app_services.dart';
import 'ui/onboarding_screen.dart';
import 'ui/tab_location.dart';
import 'ui/agenda/agenda_screen.dart';
import 'ui/theme.dart';
import 'ui/goals/goals_screen.dart';
import 'ui/settings/settings_screen.dart';

Future<void> main() async {
  installTabRouting();
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.load();
  runApp(MyApp(services: services));
}

class MyApp extends StatelessWidget {
  final AppServices services;
  const MyApp({super.key, required this.services});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Doer',
    initialRoute: '/',
    debugShowCheckedModeBanner: false,
    theme: doerTheme(Brightness.light),
    darkTheme: doerTheme(Brightness.dark),
    themeMode: ThemeMode.system,
    home: AppShell(services: services),
  );
}

class AppShell extends StatefulWidget {
  final AppServices services;
  const AppShell({super.key, required this.services});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _tab = 0;
  bool? _onboarding;
  DateTime? _agendaDay;
  late final void Function() _stopListening;
  void _selectTab(int tab) {
    ScaffoldMessenger.of(context).clearSnackBars();
    setState(() => _tab = tab);
    writeTab(tab);
  }

  void _planned(DateTime? day, String? message) {
    setState(() {
      _onboarding = false;
      _agendaDay = day;
      _tab = 0;
    });
    writeTab(0);
    if (message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  @override
  void dispose() {
    _stopListening();
    super.dispose();
  }

  bool _demoExhausted = false;

  @override
  void initState() {
    super.initState();
    _tab = readTab();
    _stopListening = listenTab((tab) {
      if (mounted && tab != _tab) setState(() => _tab = tab);
    });
    widget.services.needsOnboarding().then((value) {
      if (mounted) setState(() => _onboarding = value);
    });
    if (kIsWeb &&
        (Uri.base.queryParameters.containsKey('connected') ||
            Uri.base.queryParameters.containsKey('connect_error'))) {
      _tab = 2;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.services.calendarError != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(widget.services.calendarError!)));
      }
    });
  }

  Future<void> _onProviderError(Object error) async {
    final demoMode = await widget.services.config.getMode() == 'demo';
    if (mounted && isDemoExhausted(error, demoMode)) {
      setState(() => _demoExhausted = true);
    }
  }

  @override
  Widget build(BuildContext context) => _onboarding == null
      ? const Scaffold(body: Center(child: CircularProgressIndicator()))
      : _onboarding!
      ? OnboardingScreen(services: widget.services, onFinished: _planned)
      : LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 840;
            return Scaffold(
              body: Row(
                children: [
                  if (wide)
                    NavigationRail(
                      extended: true,
                      selectedIndex: _tab,
                      onDestinationSelected: _selectTab,
                      leading: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 24, 16, 32),
                        child: Row(
                          children: [
                            Icon(
                              Icons.check_circle,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'Doer',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                          ],
                        ),
                      ),
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.today_outlined),
                          selectedIcon: Icon(Icons.today),
                          label: Text('Agenda'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.flag_outlined),
                          selectedIcon: Icon(Icons.flag),
                          label: Text('Goals'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.tune),
                          label: Text('Settings'),
                        ),
                      ],
                    ),
                  Expanded(
                    child: SafeArea(
                      child: Column(
                        children: [
                          if (_demoExhausted)
                            MaterialBanner(
                              backgroundColor: Theme.of(context)
                                  .colorScheme
                                  .tertiaryContainer,
                              leading: const Icon(
                                Icons.account_balance_wallet_outlined,
                              ),
                              content: const Text(freePlanningUnavailable),
                              actions: [
                                TextButton(
                                  onPressed: () => _selectTab(2),
                                  child: const Text('Open Settings'),
                                ),
                                TextButton(
                                  onPressed: () =>
                                      setState(() => _demoExhausted = false),
                                  child: const Text('Dismiss'),
                                ),
                              ],
                            ),
                          Expanded(
                            child: switch (_tab) {
                              0 => AgendaScreen(
                                initialDay: _agendaDay,
                                services: widget.services,
                                onProviderError: _onProviderError,
                                onAddGoal: () => _selectTab(1),
                              ),
                              1 => GoalsScreen(
                                onPlanned: _planned,
                                services: widget.services,
                                onProviderError: _onProviderError,
                              ),
                              _ => SettingsScreen(services: widget.services),
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              bottomNavigationBar: wide
                  ? null
                  : NavigationBar(
                      selectedIndex: _tab,
                      onDestinationSelected: _selectTab,
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.today_outlined),
                          selectedIcon: Icon(Icons.today),
                          label: 'Agenda',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.flag_outlined),
                          selectedIcon: Icon(Icons.flag),
                          label: 'Goals',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.tune),
                          label: 'Settings',
                        ),
                      ],
                    ),
            );
          },
        );
}

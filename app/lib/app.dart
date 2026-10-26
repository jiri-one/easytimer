import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'l10n/app_localizations.dart';
import 'ui/settings_screen.dart';
import 'ui/timer_screen.dart';
import 'workout_controller.dart';

class EasyTimerApp extends StatefulWidget {
  const EasyTimerApp({
    super.key,
    required this.controller,
    this.locale,
    this.themeMode = ThemeMode.system,
  });

  final WorkoutController controller;
  final Locale? locale;
  final ThemeMode themeMode;

  @override
  State<EasyTimerApp> createState() => _EasyTimerAppState();
}

class _EasyTimerAppState extends State<EasyTimerApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      widget.controller.refresh(recoverWakeLock: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: dark
          ? const Color(0xff303030)
          : const Color(0xfffafafa),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff1a9f0b),
        brightness: brightness,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
    debugShowCheckedModeBanner: false,
    locale: widget.locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: widget.themeMode,
    themeAnimationDuration: Duration.zero,
    scrollBehavior: const MaterialScrollBehavior().copyWith(
      scrollbars: false,
      overscroll: false,
    ),
    home: ValueListenableBuilder<bool>(
      valueListenable: widget.controller.showingTimer,
      builder: (context, showingTimer, _) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): () {
            if (widget.controller.showingTimer.value) {
              widget.controller.togglePause();
            } else {
              widget.controller.start(widget.controller.settings.options);
            }
          },
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (widget.controller.showingTimer.value) widget.controller.stop();
          },
          if (showingTimer) ...{
            const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                widget.controller.stepVolume(5),
            const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                widget.controller.stepVolume(-5),
          },
        },
        child: Focus(
          autofocus: true,
          child: PopScope(
            canPop: !showingTimer,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop && widget.controller.showingTimer.value) {
                widget.controller.stop();
              }
            },
            child: Scaffold(
              body: SafeArea(
                child: showingTimer
                    ? TimerScreen(controller: widget.controller)
                    : SettingsScreen(controller: widget.controller),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

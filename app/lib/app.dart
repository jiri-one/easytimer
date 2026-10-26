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
  final _settingsKey = GlobalKey<SettingsScreenState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.controller.refresh();
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
      fontFamily: 'DroidSansMono',
      scaffoldBackgroundColor: dark
          ? const Color(0xff303030)
          : const Color(0xfffafafa),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff1a9f0b),
        brightness: brightness,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
      hoverColor: Colors.transparent,
      shadowColor: Colors.transparent,
      iconTheme: IconThemeData(
        color: dark ? const Color(0xffc1c1c1) : const Color(0xff6f6f6f),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: _InstantPageTransition(),
          TargetPlatform.linux: _InstantPageTransition(),
        },
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: dark ? Colors.white : Colors.black,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'EasyTimer',
    debugShowCheckedModeBanner: false,
    locale: widget.locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: const [
      Locale('en'),
      Locale('cs'),
      Locale('ca'),
      Locale('es'),
      Locale('fr'),
    ],
    theme: _theme(Brightness.light),
    darkTheme: _theme(Brightness.dark),
    themeMode: widget.themeMode,
    themeAnimationDuration: Duration.zero,
    home: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): () {
            if (widget.controller.showingTimer) {
              widget.controller.togglePause();
            } else {
              _settingsKey.currentState?.start();
            }
          },
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (widget.controller.showingTimer) widget.controller.stop();
          },
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              widget.controller.changeVolume(widget.controller.volume + .05),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              widget.controller.changeVolume(widget.controller.volume - .05),
        },
        child: Focus(
          autofocus: true,
          child: PopScope(
            canPop: !widget.controller.showingTimer,
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop && widget.controller.showingTimer) {
                widget.controller.stop();
              }
            },
            child: Scaffold(
              body: SafeArea(
                child: widget.controller.showingTimer
                    ? TimerScreen(controller: widget.controller)
                    : SettingsScreen(
                        key: _settingsKey,
                        controller: widget.controller,
                      ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _InstantPageTransition extends PageTransitionsBuilder {
  const _InstantPageTransition();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => child;
}

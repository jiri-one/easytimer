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
    HardwareKeyboard.instance.addHandler(_unlockOnKeyEvent);
  }

  bool _unlockOnKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      widget.controller.platform.unlock();
    }
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) widget.controller.refresh();
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_unlockOnKeyEvent);
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
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: dark ? Colors.white : Colors.black,
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
    builder: (context, child) => Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => widget.controller.platform.unlock(),
      child: child,
    ),
    home: ValueListenableBuilder<bool>(
      valueListenable: widget.controller.showingTimer,
      builder: (context, showingTimer, _) => CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.space): () {
            if (widget.controller.showingTimer.value) {
              widget.controller.togglePause();
            } else {
              _settingsKey.currentState?.start();
            }
          },
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (widget.controller.showingTimer.value) widget.controller.stop();
          },
          const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
              widget.controller.stepVolume(5),
          const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
              widget.controller.stepVolume(-5),
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

// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Catalan Valencian (`ca`).
class AppLocalizationsCa extends AppLocalizations {
  AppLocalizationsCa([String locale = 'ca']) : super(locale);

  @override
  String get appTitle => 'EasyTimer';

  @override
  String get activeTimeLabel => 'Esforç';

  @override
  String get restTimeLabel => 'Descans';

  @override
  String get prepareTimeLabel => 'Llesti?';

  @override
  String get setsLabel => 'Repeticions';

  @override
  String get setLabel => 'REPETICIÓ';

  @override
  String get start => 'Començar';

  @override
  String get pause => 'Pausar';

  @override
  String get resume => 'Reprendre';

  @override
  String get stop => 'Acabar';

  @override
  String get settings => 'Configuració';

  @override
  String get decreaseActiveTime => 'Abaixa Temps de Esforç';

  @override
  String get increaseActiveTime => 'Apujar Temps de Esforç';

  @override
  String get decreaseRestTime => 'Abaixa Temps de Descans';

  @override
  String get increaseRestTime => 'Apujar Temps de Descans';

  @override
  String get decreaseSets => 'Abaixa Repeticions';

  @override
  String get increaseSets => 'Apujar Repeticions';

  @override
  String get volume => 'Volum';

  @override
  String setCount(int set) {
    return '$set';
  }

  @override
  String get unlimited => 'Sense límit';
}

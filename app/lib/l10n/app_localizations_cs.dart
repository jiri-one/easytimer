// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Czech (`cs`).
class AppLocalizationsCs extends AppLocalizations {
  AppLocalizationsCs([String locale = 'cs']) : super(locale);

  @override
  String get appTitle => 'EasyTimer';

  @override
  String get activeTimeLabel => 'Aktivita';

  @override
  String get restTimeLabel => 'Odpočinek';

  @override
  String get prepareTimeLabel => 'Připravit';

  @override
  String get setsLabel => 'Sety';

  @override
  String get setLabel => 'SET';

  @override
  String get start => 'Start';

  @override
  String get pause => 'Pauza';

  @override
  String get resume => 'Pokračovat';

  @override
  String get stop => 'Stop';

  @override
  String get settings => 'Nastavení';

  @override
  String get decreaseActiveTime => 'Zkrácení času aktivity';

  @override
  String get increaseActiveTime => 'Prodloužení času aktivity';

  @override
  String get decreaseRestTime => 'Zkrácení času odpočinku';

  @override
  String get increaseRestTime => 'Prodloužení času odpočinku';

  @override
  String get decreaseSets => 'Snížení setů';

  @override
  String get increaseSets => 'Zvýšení setů';

  @override
  String get volume => 'Hlasitost';

  @override
  String setCount(int set) {
    return '$set';
  }

  @override
  String get unlimited => 'Neomezeně';
}

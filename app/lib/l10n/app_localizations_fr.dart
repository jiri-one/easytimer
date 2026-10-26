// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class AppLocalizationsFr extends AppLocalizations {
  AppLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get appTitle => 'EasyTimer';

  @override
  String get activeTimeLabel => 'Effort';

  @override
  String get restTimeLabel => 'Repos';

  @override
  String get prepareTimeLabel => 'Prêt·e?';

  @override
  String get setsLabel => 'Répétitions';

  @override
  String get setLabel => 'RÉPÉTITIONS';

  @override
  String get start => 'Départ';

  @override
  String get pause => 'Pause';

  @override
  String get resume => 'Reprendre';

  @override
  String get stop => 'Arrêt';

  @override
  String get settings => 'Configuration';

  @override
  String get decreaseActiveTime => 'Diminuer Temps Effort';

  @override
  String get increaseActiveTime => 'Augmenter Temps Effort';

  @override
  String get decreaseRestTime => 'Diminuer Temps Repos';

  @override
  String get increaseRestTime => 'Augmenter Temps Repos';

  @override
  String get decreaseSets => 'Diminuer Répétitions';

  @override
  String get increaseSets => 'Augmenter Répétitions';

  @override
  String get volume => 'Volume';

  @override
  String setCount(int set) {
    return '$set';
  }

  @override
  String get unlimited => 'Illimité';
}

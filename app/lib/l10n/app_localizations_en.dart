// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'EasyTimer';

  @override
  String get activeTimeLabel => 'Active';

  @override
  String get restTimeLabel => 'Rest';

  @override
  String get prepareTimeLabel => 'Prepare';

  @override
  String get setsLabel => 'Sets';

  @override
  String get setLabel => 'SET';

  @override
  String get start => 'Start';

  @override
  String get pause => 'Pause';

  @override
  String get resume => 'Resume';

  @override
  String get stop => 'Stop';

  @override
  String get decreaseActiveTime => 'Decrease Active Time';

  @override
  String get increaseActiveTime => 'Increase Active Time';

  @override
  String get decreaseRestTime => 'Decrease Rest Time';

  @override
  String get increaseRestTime => 'Increase Rest Time';

  @override
  String get decreaseSets => 'Decrease Sets';

  @override
  String get increaseSets => 'Increase Sets';

  @override
  String get volume => 'Volume';

  @override
  String get unlimited => 'Unlimited';
}

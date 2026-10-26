// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class AppLocalizationsEs extends AppLocalizations {
  AppLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get appTitle => 'EasyTimer';

  @override
  String get activeTimeLabel => 'Trabajo';

  @override
  String get restTimeLabel => 'Descanso';

  @override
  String get prepareTimeLabel => 'Preparado';

  @override
  String get setsLabel => 'Repeticiones';

  @override
  String get setLabel => 'REPETICIÓN';

  @override
  String get start => 'Comenzar';

  @override
  String get pause => 'Pausar';

  @override
  String get resume => 'Continuar';

  @override
  String get stop => 'Parar';

  @override
  String get decreaseActiveTime => 'Decrementar Tiempo Trabajo';

  @override
  String get increaseActiveTime => 'Incrementar Tiempo Trabajo';

  @override
  String get decreaseRestTime => 'Decrementar Tiempo Descanso';

  @override
  String get increaseRestTime => 'Incrementar Tiempo Descanso';

  @override
  String get decreaseSets => 'Decrementar Repeticiones';

  @override
  String get increaseSets => 'Incrementar Repeticiones';

  @override
  String get volume => 'Volumen';

  @override
  String get unlimited => 'Sin límite';
}

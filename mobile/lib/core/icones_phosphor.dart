import 'package:flutter/widgets.dart';

/// Les quelques icônes Phosphor (poids « fill », licence MIT) de la carte de
/// suivi, tirées de la police embarquée (pubspec : PhosphorFill).
///
/// Pas le paquet phosphor_flutter : abandonné depuis 2024, il étend
/// IconData, que Flutter 3.47 interdit d'étendre — l'app ne compilait plus.
abstract final class Phosphor {
  static const _police = 'PhosphorFill';

  static const moped = IconData(0xe824, fontFamily: _police);
  static const storefront = IconData(0xe470, fontFamily: _police);
  static const houseSimple = IconData(0xe2c6, fontFamily: _police);
  static const package = IconData(0xe390, fontFamily: _police);
  static const mapPin = IconData(0xe316, fontFamily: _police);
  static const caretLeft = IconData(0xe138, fontFamily: _police);
  static const navigationArrow = IconData(0xeade, fontFamily: _police);
}

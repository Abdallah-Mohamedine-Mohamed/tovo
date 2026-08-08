import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Le filtre de saisie du champ téléphone.
///
/// Un antislash perdu dans `[\d+ ]` donne `[d+ ]` : la classe n'autorise
/// plus que la lettre d, le plus et l'espace. Le champ refuse alors tout
/// chiffre — personne ne peut se connecter, et rien ne le signale à la
/// compilation. C'est arrivé, d'où ce test.
void main() {
  final filtre = FilteringTextInputFormatter.allow(RegExp(r'[\d+ ]'));

  TextEditingValue saisir(String texte) => filtre.formatEditUpdate(
        TextEditingValue.empty,
        TextEditingValue(text: texte),
      );

  group('champ du numéro de téléphone', () {
    test('accepte les chiffres', () {
      expect(saisir('90123456').text, '90123456');
    });

    test('accepte un numéro international complet', () {
      expect(saisir('+227 90 12 34 56').text, '+227 90 12 34 56');
    });

    test('refuse les lettres, y compris « d »', () {
      // « d » est le piège précis : c'est ce que laisse passer une classe
      // dont l'antislash a sauté.
      expect(saisir('d').text, '');
      expect(saisir('abc').text, '');
      expect(saisir('+227d90').text, '+22790');
    });

    test('un numéro nigérien reste saisissable en entier', () {
      expect(saisir('+22786967908').text, '+22786967908');
    });
  });
}

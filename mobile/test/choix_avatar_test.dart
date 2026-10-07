import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tovo/features/carte/avatar.dart';
import 'package:tovo/features/carte/choix_avatar.dart';

void main() {
  testWidgets('le client choisit son avatar : Femme par défaut, un toucher suffit', (t) async {
    SharedPreferences.setMockInitialValues({});
    expect(await ImagesAvatar.choisi(), 'femme');
    await t.pumpWidget(const MaterialApp(home: ChoixAvatar()));
    await t.pump();
    for (final nom in ['Femme', 'Capuche', 'Aventurier', 'Homme']) {
      expect(find.text(nom), findsOneWidget);
    }
    await t.tap(find.text('Capuche'));
    await t.pump();
    expect(await ImagesAvatar.choisi(), 'capuche');
    expect((await SharedPreferences.getInstance()).getString('avatar'), 'capuche');
  });

  test('un choix inconnu (ancienne version) retombe sur Femme', () async {
    SharedPreferences.setMockInitialValues({'avatar': 'robot'});
    expect(await ImagesAvatar.choisi(), 'femme');
  });
}

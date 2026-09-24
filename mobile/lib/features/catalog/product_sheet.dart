import 'package:flutter/material.dart';

import '../../core/api.dart';
import 'product_screen.dart';

/// Comment la fiche s'est refermée, quand un article a été ajouté.
enum IssueFiche {
  /// « Ajouter » : le client continue ses achats.
  ajoute,

  /// « Commander » : l'article est au panier, on ouvre tout de suite la
  /// commande. Un seul article ne doit pas obliger à passer par le panier.
  commander,
}

Future<IssueFiche?> showProductSheet(
  BuildContext context, {
  required TovoApi api,
  required String productId,
  Map<String, dynamic> initialProduct = const {},
}) => showModalBottomSheet<IssueFiche>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: Colors.transparent,
  barrierColor: Colors.black38,
  builder: (sheetContext) => Padding(
    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
    child: Material(
      color: Colors.white,
      elevation: 8,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.78,
        ),
        child: SingleChildScrollView(
          child: ProductScreen(
            api: api,
            productId: productId,
            initialProduct: initialProduct,
            embedded: true,
            onClose: () => Navigator.pop(sheetContext),
            onAdded: () => Navigator.pop(sheetContext, IssueFiche.ajoute),
            onOrder: () => Navigator.pop(sheetContext, IssueFiche.commander),
          ),
        ),
      ),
    ),
  ),
);

import 'package:flutter/material.dart';

import '../../core/api.dart';
import 'product_screen.dart';

Future<bool?> showProductSheet(
  BuildContext context, {
  required TovoApi api,
  required String productId,
  Map<String, dynamic> initialProduct = const {},
}) => showModalBottomSheet<bool>(
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
            onClose: () => Navigator.pop(sheetContext, false),
            onAdded: () => Navigator.pop(sheetContext, true),
          ),
        ),
      ),
    ),
  ),
);

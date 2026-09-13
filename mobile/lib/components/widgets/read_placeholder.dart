import 'package:flutter/material.dart';

class ReadPlaceholder extends StatelessWidget {
  const ReadPlaceholder({super.key, this.rows = 3});
  final int rows;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Chargement du contenu',
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        children: [
          for (var row = 0; row < rows; row++)
            const Padding(
              padding: EdgeInsets.only(bottom: 20),
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    height: 64,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Color(0xFFF1F2F0),
                        borderRadius: BorderRadius.all(Radius.circular(12)),
                      ),
                    ),
                  ),
                  SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FractionallySizedBox(
                          widthFactor: .7,
                          child: SizedBox(
                            height: 12,
                            child: ColoredBox(color: Color(0xFFF1F2F0)),
                          ),
                        ),
                        SizedBox(height: 12),
                        FractionallySizedBox(
                          widthFactor: .45,
                          child: SizedBox(
                            height: 10,
                            child: ColoredBox(color: Color(0xFFF1F2F0)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

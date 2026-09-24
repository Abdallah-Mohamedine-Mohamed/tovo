import 'package:flutter/material.dart';

import '../../core/theme.dart';

class PhoneCountry {
  const PhoneCountry(
    this.name,
    this.isoCode,
    this.dialCode, {
    this.nationalLength,
    this.removeTrunkZero = false,
  });

  final String name;
  final String isoCode;
  final String dialCode;
  final int? nationalLength;
  final bool removeTrunkZero;

  String get flag => String.fromCharCodes(
    isoCode.toUpperCase().codeUnits.map((letter) => letter + 127397),
  );

  String fullNumber(String localNumber) {
    var digits = localNumber.replaceAll(RegExp(r'\D'), '');
    if (removeTrunkZero && digits.startsWith('0')) {
      digits = digits.substring(1);
    }
    return '$dialCode$digits';
  }

  bool accepts(String localNumber) {
    final digits = fullNumber(localNumber).substring(dialCode.length);
    if (nationalLength != null && digits.length != nationalLength) {
      return false;
    }
    return digits.length >= 7 &&
        digits.length <= 12 &&
        fullNumber(localNumber).length <= 16;
  }
}

const phoneCountries = <PhoneCountry>[
  PhoneCountry('Niger', 'NE', '+227', nationalLength: 8),
  PhoneCountry('Afrique du Sud', 'ZA', '+27'),
  PhoneCountry('Algérie', 'DZ', '+213', removeTrunkZero: true),
  PhoneCountry('Allemagne', 'DE', '+49', removeTrunkZero: true),
  PhoneCountry('Arabie saoudite', 'SA', '+966', removeTrunkZero: true),
  PhoneCountry('Argentine', 'AR', '+54'),
  PhoneCountry('Australie', 'AU', '+61', removeTrunkZero: true),
  PhoneCountry('Autriche', 'AT', '+43', removeTrunkZero: true),
  PhoneCountry('Belgique', 'BE', '+32', removeTrunkZero: true),
  PhoneCountry('Bénin', 'BJ', '+229'),
  PhoneCountry('Brésil', 'BR', '+55'),
  PhoneCountry('Burkina Faso', 'BF', '+226'),
  PhoneCountry('Cameroun', 'CM', '+237'),
  PhoneCountry('Canada', 'CA', '+1'),
  PhoneCountry('Cap-Vert', 'CV', '+238'),
  PhoneCountry('Chine', 'CN', '+86'),
  PhoneCountry('Congo', 'CG', '+242'),
  PhoneCountry('Côte d’Ivoire', 'CI', '+225'),
  PhoneCountry('Danemark', 'DK', '+45'),
  PhoneCountry('Égypte', 'EG', '+20', removeTrunkZero: true),
  PhoneCountry('Émirats arabes unis', 'AE', '+971', removeTrunkZero: true),
  PhoneCountry('Espagne', 'ES', '+34'),
  PhoneCountry('États-Unis', 'US', '+1'),
  PhoneCountry('Éthiopie', 'ET', '+251', removeTrunkZero: true),
  PhoneCountry('France', 'FR', '+33', removeTrunkZero: true),
  PhoneCountry('Gabon', 'GA', '+241'),
  PhoneCountry('Gambie', 'GM', '+220'),
  PhoneCountry('Ghana', 'GH', '+233', removeTrunkZero: true),
  PhoneCountry('Guinée', 'GN', '+224'),
  PhoneCountry('Guinée-Bissau', 'GW', '+245'),
  PhoneCountry('Guinée équatoriale', 'GQ', '+240'),
  PhoneCountry('Inde', 'IN', '+91'),
  PhoneCountry('Indonésie', 'ID', '+62', removeTrunkZero: true),
  PhoneCountry('Irlande', 'IE', '+353', removeTrunkZero: true),
  PhoneCountry('Israël', 'IL', '+972', removeTrunkZero: true),
  PhoneCountry('Italie', 'IT', '+39'),
  PhoneCountry('Japon', 'JP', '+81', removeTrunkZero: true),
  PhoneCountry('Kenya', 'KE', '+254', removeTrunkZero: true),
  PhoneCountry('Liban', 'LB', '+961', removeTrunkZero: true),
  PhoneCountry('Libéria', 'LR', '+231'),
  PhoneCountry('Libye', 'LY', '+218', removeTrunkZero: true),
  PhoneCountry('Luxembourg', 'LU', '+352'),
  PhoneCountry('Madagascar', 'MG', '+261', removeTrunkZero: true),
  PhoneCountry('Mali', 'ML', '+223'),
  PhoneCountry('Maroc', 'MA', '+212', removeTrunkZero: true),
  PhoneCountry('Mauritanie', 'MR', '+222'),
  PhoneCountry('Nigeria', 'NG', '+234', removeTrunkZero: true),
  PhoneCountry('Norvège', 'NO', '+47'),
  PhoneCountry('Ouganda', 'UG', '+256', removeTrunkZero: true),
  PhoneCountry('Pakistan', 'PK', '+92', removeTrunkZero: true),
  PhoneCountry('Pays-Bas', 'NL', '+31', removeTrunkZero: true),
  PhoneCountry('Portugal', 'PT', '+351'),
  PhoneCountry('Qatar', 'QA', '+974'),
  PhoneCountry('Royaume-Uni', 'GB', '+44', removeTrunkZero: true),
  PhoneCountry('Rwanda', 'RW', '+250', removeTrunkZero: true),
  PhoneCountry('Sénégal', 'SN', '+221'),
  PhoneCountry('Sierra Leone', 'SL', '+232'),
  PhoneCountry('Soudan', 'SD', '+249', removeTrunkZero: true),
  PhoneCountry('Suisse', 'CH', '+41', removeTrunkZero: true),
  PhoneCountry('Tchad', 'TD', '+235'),
  PhoneCountry('Togo', 'TG', '+228'),
  PhoneCountry('Tunisie', 'TN', '+216'),
  PhoneCountry('Turquie', 'TR', '+90', removeTrunkZero: true),
  PhoneCountry('Ukraine', 'UA', '+380', removeTrunkZero: true),
];

class PhoneCountrySheet extends StatefulWidget {
  const PhoneCountrySheet({super.key, required this.selected});

  final PhoneCountry selected;

  @override
  State<PhoneCountrySheet> createState() => _PhoneCountrySheetState();
}

class _PhoneCountrySheetState extends State<PhoneCountrySheet> {
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  String _normalise(String value) => value
      .toLowerCase()
      .replaceAll(RegExp('[àâä]'), 'a')
      .replaceAll(RegExp('[éèêë]'), 'e')
      .replaceAll(RegExp('[îï]'), 'i')
      .replaceAll(RegExp('[ôö]'), 'o')
      .replaceAll(RegExp('[ùûü]'), 'u')
      .replaceAll('ç', 'c');

  @override
  Widget build(BuildContext context) {
    final query = _normalise(_search.text.trim());
    final matches = phoneCountries.where((country) {
      if (query.isEmpty) return true;
      return _normalise(country.name).contains(query) ||
          country.dialCode.contains(query) ||
          country.isoCode.toLowerCase().contains(query);
    }).toList();
    final availableHeight =
        MediaQuery.sizeOf(context).height -
        MediaQuery.viewInsetsOf(context).bottom;

    return Padding(
      padding: EdgeInsets.fromLTRB(
        12,
        0,
        12,
        MediaQuery.viewInsetsOf(context).bottom + 12,
      ),
      child: Material(
        color: TovoTheme.canvas,
        elevation: 8,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: availableHeight * 0.78,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'Choisir un pays',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Fermer les pays',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: TextField(
                  key: const ValueKey('auth-country-search'),
                  controller: _search,
                  autofocus: true,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'Pays ou indicatif',
                    prefixIcon: const Icon(Icons.search_rounded),
                    filled: true,
                    fillColor: const Color(0xFFF2F3F1),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Expanded(
                child: matches.isEmpty
                    ? const Center(child: Text('Aucun pays trouvé.'))
                    : ListView.builder(
                        itemCount: matches.length,
                        itemBuilder: (context, index) {
                          final country = matches[index];
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                            ),
                            leading: Text(
                              country.flag,
                              style: const TextStyle(fontSize: 24),
                            ),
                            title: Text(country.name),
                            trailing: Text(
                              country.dialCode,
                              style: const TextStyle(color: TovoTheme.inkDoux),
                            ),
                            selected:
                                country.isoCode == widget.selected.isoCode,
                            onTap: () => Navigator.pop(context, country),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

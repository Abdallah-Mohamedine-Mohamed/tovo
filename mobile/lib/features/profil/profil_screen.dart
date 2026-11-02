import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../components/widgets/read_placeholder.dart';
import '../../core/api.dart';
import '../../core/config.dart';
import '../../core/deconnexion.dart';
import '../../core/theme.dart';
import '../adresse/choix_adresse.dart';
import '../carte/choix_avatar.dart';
import 'supprimer_compte_screen.dart';

/// Le numéro de Tovo, pour l'aide (02/11).
const numeroTovo = '+22776762020';
const numeroTovoLisible = '+227 76 76 20 20';

/// « Mon profil » (maquette validée le 27/10) : qui je suis, mes adresses,
/// mes commandes, l'aide, et en bas, discrets, se déconnecter et supprimer
/// son compte — obligatoire chez Apple et Google.
///
/// Renvoie `'commandes'` quand le client veut voir ses commandes : la
/// feuille des commandes appartient à l'écran de conversation.
class ProfilScreen extends StatefulWidget {
  const ProfilScreen({super.key, required this.api});

  final TovoApi api;

  @override
  State<ProfilScreen> createState() => _ProfilScreenState();
}

class _ProfilScreenState extends State<ProfilScreen> {
  Map<String, dynamic> _moi = {};
  List<Map<String, dynamic>> _adresses = [];
  bool _charge = true;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    unawaited(_charger());
  }

  Future<void> _charger() async {
    final reponses = await Future.wait([
      widget.api.get('/me'),
      widget.api.get('/addresses'),
    ]);
    if (!mounted) return;
    setState(() {
      _charge = false;
      if (reponses[0].ok) {
        _moi = reponses[0].raw;
        _erreur = null;
      } else {
        _erreur = reponses[0].content;
      }
      if (reponses[1].ok) _adresses = reponses[1].list('addresses');
    });
  }

  String get _nom => '${_moi['full_name'] ?? ''}'.trim();

  /// « 22796123456 » → « +227 96 12 34 56 ».
  static String telephoneLisible(String? brut) {
    final chiffres = (brut ?? '').replaceAll(RegExp(r'\D'), '');
    if (chiffres.length == 11 && chiffres.startsWith('227')) {
      final n = chiffres.substring(3);
      return '+227 ${n.substring(0, 2)} ${n.substring(2, 4)} '
          '${n.substring(4, 6)} ${n.substring(6)}';
    }
    return chiffres.isEmpty ? '' : '+$chiffres';
  }

  Future<void> _modifierNom() async {
    final champ = TextEditingController(text: _nom);
    final nouveau = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (feuille) => Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          0,
          20,
          24 + MediaQuery.viewInsetsOf(feuille).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Votre nom',
              style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            const Text(
              'Le livreur et la boutique le voient sur votre commande.',
              style: TextStyle(fontSize: 14, color: TovoTheme.inkDoux),
            ),
            const SizedBox(height: 18),
            TextField(
              key: const ValueKey('champ-nom'),
              controller: champ,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              maxLength: 60,
              decoration: InputDecoration(
                counterText: '',
                filled: true,
                fillColor: TovoTheme.bloc,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
              style: const TextStyle(fontSize: 17),
              onSubmitted: (v) => Navigator.pop(feuille, v),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(feuille, champ.text),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(54),
              ),
              child: const Text('Enregistrer'),
            ),
          ],
        ),
      ),
    );
    final nom = nouveau?.trim() ?? '';
    if (!mounted || nom.length < 2 || nom == _nom) return;
    final reponse = await widget.api.patch('/me', {'full_name': nom});
    if (!mounted) return;
    if (reponse.ok) {
      setState(() => _moi = {..._moi, 'full_name': nom});
    } else {
      _dire(reponse.content);
    }
  }

  Future<void> _ajouterAdresse() async {
    final choix = await choisirAdresse(
      context,
      api: widget.api,
      action: 'Enregistrer cette adresse',
      autrePersonne: false,
      toujoursEnregistrer: true,
    );
    if (choix != null && mounted) await _charger();
  }

  Future<void> _gererAdresse(Map<String, dynamic> adresse) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.white,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (feuille) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (adresse['is_default'] != true)
              ListTile(
                leading: const Icon(Icons.star_outline_rounded),
                title: const Text('En faire l’adresse principale'),
                onTap: () => Navigator.pop(feuille, 'principale'),
              ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline_rounded,
                color: TovoTheme.danger,
              ),
              title: const Text(
                'Supprimer cette adresse',
                style: TextStyle(color: TovoTheme.danger),
              ),
              onTap: () => Navigator.pop(feuille, 'supprimer'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (action == null || !mounted) return;
    final id = adresse['id'];
    final reponse = action == 'principale'
        ? await widget.api.post('/addresses/$id/default', {})
        : await widget.api.delete('/addresses/$id');
    if (!mounted) return;
    if (!reponse.ok) _dire(reponse.content);
    await _charger();
  }

  Future<void> _ouvrir(Uri lien) async {
    final ok = await launchUrl(lien, mode: LaunchMode.externalApplication);
    if (!ok && mounted) _dire('Impossible d’ouvrir le lien.');
  }

  void _dire(String texte) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(texte)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: _charge
            ? const ReadPlaceholder()
            : RefreshIndicator(
                onRefresh: _charger,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 40),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Material(
                        color: TovoTheme.bloc,
                        shape: const CircleBorder(),
                        child: IconButton(
                          tooltip: 'Retour',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(
                            Icons.arrow_back_rounded,
                            color: TovoTheme.ink,
                          ),
                        ),
                      ),
                    ),
                    if (_erreur != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          _erreur!,
                          style: const TextStyle(color: TovoTheme.danger),
                        ),
                      ),
                    _enTete(),
                    const SizedBox(height: 30),
                    _section('Mon compte', [
                      _ligne(
                        cle: 'nom',
                        icone: Icons.person_outline_rounded,
                        libelle: 'Nom',
                        valeur: _nom,
                        onTap: _modifierNom,
                      ),
                      _ligne(
                        icone: Icons.phone_iphone_rounded,
                        libelle: 'Numéro',
                        valeur: telephoneLisible(_moi['phone'] as String?),
                      ),
                      _ligne(
                        icone: Icons.directions_walk_rounded,
                        libelle: 'Mon avatar',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const ChoixAvatar(),
                          ),
                        ),
                      ),
                    ]),
                    _section('Mes adresses', [
                      for (final a in _adresses)
                        _ligne(
                          cle: 'adresse-${a['id']}',
                          icone: _iconeAdresse('${a['label'] ?? ''}'),
                          libelle: '${a['label'] ?? 'Adresse'}',
                          sousTitre: '${a['text_hint'] ?? ''}',
                          marque: a['is_default'] == true ? 'Principale' : null,
                          onTap: () => _gererAdresse(a),
                        ),
                      _ligne(
                        cle: 'ajouter-adresse',
                        icone: Icons.add_rounded,
                        libelle: 'Ajouter une adresse',
                        onTap: _ajouterAdresse,
                        chevron: false,
                      ),
                    ]),
                    _section('Mes commandes', [
                      _ligne(
                        cle: 'commandes',
                        icone: Icons.shopping_bag_outlined,
                        libelle: 'Historique des commandes',
                        onTap: () => Navigator.of(context).pop('commandes'),
                      ),
                    ]),
                    _section('Aide', [
                      _ligne(
                        icone: Icons.chat_bubble_outline_rounded,
                        libelle: 'Écrire à Tovo',
                        valeur: 'WhatsApp',
                        onTap: () => _ouvrir(
                          Uri.parse('https://wa.me/${numeroTovo.substring(1)}'),
                        ),
                      ),
                      _ligne(
                        icone: Icons.call_outlined,
                        libelle: 'Appeler Tovo',
                        valeur: numeroTovoLisible,
                        onTap: () => _ouvrir(Uri.parse('tel:$numeroTovo')),
                        chevron: false,
                      ),
                      _ligne(
                        icone: Icons.privacy_tip_outlined,
                        libelle: 'Confidentialité',
                        onTap: () => _ouvrir(
                          Uri.parse('${TovoConfig.apiBaseUrl}/confidentialite'),
                        ),
                      ),
                      _ligne(
                        icone: Icons.description_outlined,
                        libelle: 'Conditions d’utilisation',
                        onTap: () => _ouvrir(
                          Uri.parse('${TovoConfig.apiBaseUrl}/conditions'),
                        ),
                      ),
                    ]),
                    const SizedBox(height: 4),
                    _bas(
                      'Se déconnecter',
                      TovoTheme.ink,
                      () => confirmerDeconnexion(context),
                    ),
                    _bas(
                      'Supprimer mon compte',
                      TovoTheme.danger,
                      () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SupprimerCompteScreen(
                            api: widget.api,
                            telephone: '${_moi['phone'] ?? ''}',
                          ),
                        ),
                      ),
                      cle: 'supprimer-compte',
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _enTete() {
    final initiale = _nom.isEmpty ? '?' : _nom.characters.first.toUpperCase();
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        children: [
          Container(
            width: 96,
            height: 96,
            alignment: Alignment.center,
            decoration: const BoxDecoration(
              color: TovoTheme.bloc,
              shape: BoxShape.circle,
            ),
            child: Text(
              initiale,
              style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w600),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            _nom.isEmpty ? 'Votre profil' : _nom,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.4,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            telephoneLisible(_moi['phone'] as String?),
            style: const TextStyle(fontSize: 14, color: TovoTheme.inkDoux),
          ),
        ],
      ),
    );
  }

  static IconData _iconeAdresse(String libelle) {
    final l = libelle.toLowerCase();
    if (l.contains('bureau') || l.contains('travail')) {
      return Icons.work_outline_rounded;
    }
    if (l.contains('famille')) return Icons.people_outline_rounded;
    return Icons.home_outlined;
  }

  Widget _section(String titre, List<Widget> lignes) => Padding(
    padding: const EdgeInsets.only(bottom: 22),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
          child: Text(
            titre,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TovoTheme.muted,
            ),
          ),
        ),
        for (var i = 0; i < lignes.length; i++) ...[
          if (i > 0)
            const Divider(height: 1, indent: 40, color: Color(0xFFEEF0EC)),
          lignes[i],
        ],
      ],
    ),
  );

  Widget _ligne({
    String? cle,
    required IconData icone,
    required String libelle,
    String? valeur,
    String? sousTitre,
    String? marque,
    VoidCallback? onTap,
    bool chevron = true,
  }) => InkWell(
    key: cle == null ? null : ValueKey('ligne-$cle'),
    onTap: onTap,
    borderRadius: BorderRadius.circular(12),
    child: ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Icon(icone, size: 22, color: TovoTheme.ink),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    libelle,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (sousTitre != null && sousTitre.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        sousTitre,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: TovoTheme.inkDoux,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (valeur != null && valeur.isNotEmpty) ...[
              const SizedBox(width: 10),
              // Une largeur bornée, pas un Flexible : partagé avec le libellé,
              // il laissait la valeur flotter au milieu de la ligne.
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 170),
                child: Text(
                  valeur,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 14,
                    color: TovoTheme.inkDoux,
                  ),
                ),
              ),
            ],
            if (marque != null) ...[
              const SizedBox(width: 10),
              Text(
                marque,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: TovoTheme.success,
                ),
              ),
            ] else if (chevron && onTap != null) ...[
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right_rounded,
                size: 20,
                color: Color(0xFF9AA39F),
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _bas(String texte, Color couleur, VoidCallback onTap, {String? cle}) =>
      InkWell(
        key: cle == null ? null : ValueKey(cle),
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
          child: Text(
            texte,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: couleur,
            ),
          ),
        ),
      );
}

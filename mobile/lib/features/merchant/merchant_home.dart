import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/registry.dart';
import '../../core/api.dart';
import '../../core/deconnexion.dart';
import '../../core/theme.dart';
import '../../core/catalog_image.dart';
import 'catalogue_boutique.dart';
import 'merchant_controller.dart';
import 'hours_editor.dart';
import 'product_editor.dart';

/// Écran du boutiquier.
///
/// Contrairement au livreur, deux vues coexistent : les commandes et le
/// catalogue. Le boutiquier est derrière un comptoir, pas sur une moto — il
/// peut naviguer. Mais les commandes restent l'onglet par défaut, et un
/// compteur signale celles qui attendent une réponse.
class MerchantHome extends StatefulWidget {
  const MerchantHome({super.key, required this.api});

  final TovoApi api;

  @override
  State<MerchantHome> createState() => _MerchantHomeState();
}

class _MerchantHomeState extends State<MerchantHome>
    with WidgetsBindingObserver {
  late final MerchantController _c = MerchantController(api: widget.api);
  int _onglet = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _c.addListener(_maj);
    _c.start();
  }

  @override
  void dispose() {
    _c.removeListener(_maj);
    _c.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_c.actualiserCommandes());
  }

  void _maj() {
    if (mounted) setState(() {});
  }

  /// Ouvre la fiche produit. `null` pour une création.
  Future<void> _editer(Map<String, dynamic>? produit) async {
    final modifie = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => ProductEditor(
          api: widget.api,
          merchantId: _c.boutiqueId!,
          produit: produit,
        ),
      ),
    );
    if (modifie == true) await _c.refresh();
  }

  Future<void> _ouvrirHoraires() async {
    final id = _c.boutiqueId;
    if (id == null) return;

    final modifie = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => EditeurHoraires(merchantId: id)),
    );
    // Recharger : l'état « ouverte » affiché en haut dépend des horaires.
    if (modifie == true) await _c.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final enAttente = _c.aTraiter.length;

    return Scaffold(
      backgroundColor: TovoTheme.surface,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              (_c.boutique?['name'] as String?) ?? 'Tovo Boutique',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
            Text(
              _c.ouverte ? 'Ouverte' : 'Fermée',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: _c.ouverte ? TovoTheme.success : TovoTheme.danger,
              ),
            ),
          ],
        ),
        actions: [
          // Les horaires décident autant que l'interrupteur : une boutique
          // dont l'interrupteur est levé reste fermée aux clients hors de
          // ses heures. Le réglage doit donc être à portée de main.
          IconButton(
            tooltip: 'Horaires',
            icon: const Icon(Icons.schedule_outlined),
            onPressed: _c.boutiqueId == null ? null : _ouvrirHoraires,
          ),
          Switch(
            value: _c.ouverte,
            activeThumbColor: TovoTheme.success,
            onChanged: _c.boutiqueId == null
                ? null
                : (_) => _c.basculerOuverture(),
          ),
          // Derrière un menu, loin de l'interrupteur d'ouverture : les deux
          // gestes se ressemblent trop pour cohabiter en plein écran.
          PopupMenuButton<String>(
            onSelected: (choix) {
              if (choix == 'sortir') unawaited(confirmerDeconnexion(context));
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'sortir', child: Text('Se déconnecter')),
            ],
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _c.refresh(),
        child: _c.boutiqueId == null && !_c.chargement
            ? const _AucuneBoutique()
            : _onglet == 0
            ? _ListeCommandes(controller: _c)
            : CatalogueBoutique(controller: _c, onEditer: _editer),
      ),
      floatingActionButton: _onglet == 1 && _c.boutiqueId != null
          ? FloatingActionButton.extended(
              onPressed: () => _editer(null),
              backgroundColor: TovoTheme.teal,
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text(
                'Produit',
                style: TextStyle(color: Colors.white),
              ),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _onglet,
        onDestinationSelected: (i) => setState(() => _onglet = i),
        destinations: [
          NavigationDestination(
            icon: Badge(
              // Le compteur ne montre que les commandes non traitées. Un
              // badge qui affiche le total serait toujours allumé et cesserait
              // d'attirer l'œil.
              isLabelVisible: enAttente > 0,
              label: Text('$enAttente'),
              child: const Icon(Icons.receipt_long_outlined),
            ),
            selectedIcon: const Icon(Icons.receipt_long),
            label: 'Commandes',
          ),
          const NavigationDestination(
            icon: Icon(Icons.inventory_2_outlined),
            selectedIcon: Icon(Icons.inventory_2),
            label: 'Catalogue',
          ),
        ],
      ),
    );
  }
}

class _ListeCommandes extends StatelessWidget {
  const _ListeCommandes({required this.controller});

  final MerchantController controller;

  @override
  Widget build(BuildContext context) {
    final commandes = controller.commandes;

    if (commandes.isEmpty) {
      return ListView(
        children: const [
          _Message(
            icone: Icons.inbox_outlined,
            titre: 'Aucune commande',
            detail: 'Les nouvelles commandes apparaîtront ici automatiquement.',
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: commandes.length,
      itemBuilder: (context, i) =>
          _CarteCommande(commande: commandes[i], controller: controller),
    );
  }
}

/// « 14:32 » aujourd'hui, « hier 21:05 », sinon « 12/10 09:40 ».
String? _heure(String? iso) {
  final t = iso == null ? null : DateTime.tryParse(iso)?.toLocal();
  if (t == null) return null;
  String deux(int n) => n.toString().padLeft(2, '0');
  final hm = '${deux(t.hour)}:${deux(t.minute)}';
  final maintenant = DateTime.now();
  final jour = DateTime(t.year, t.month, t.day);
  final aujourdhui = DateTime(
    maintenant.year,
    maintenant.month,
    maintenant.day,
  );
  final ecart = aujourdhui.difference(jour).inDays;
  if (ecart == 0) return hm;
  if (ecart == 1) return 'hier $hm';
  return '${deux(t.day)}/${deux(t.month)} $hm';
}

class _CarteCommande extends StatelessWidget {
  const _CarteCommande({required this.commande, required this.controller});

  final Map<String, dynamic> commande;
  final MerchantController controller;

  @override
  Widget build(BuildContext context) {
    final statut = (commande['status'] as String?) ?? '';
    final etape = MerchantController.etapeSuivante(statut);
    final nouvelle = statut == 'pending';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        border: Border.all(
          color: nouvelle ? TovoTheme.teal : const Color(0x12000000),
          width: nouvelle ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  MerchantController.libelleStatut(statut),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: nouvelle ? TovoTheme.teal : TovoTheme.muted,
                  ),
                ),
              ),
              Text(
                Money.format((commande['total'] as num?)?.toInt() ?? 0),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Qui et quand : « Awa · 14:32 ». Le prénom permet de répondre au
          // livreur qui demande « la commande de qui ? » ; l'heure dit
          // laquelle attend depuis le plus longtemps.
          Text(
            [
              if ((commande['client_prenom'] as String?)?.isNotEmpty == true)
                commande['client_prenom'] as String,
              if (_heure(commande['placed_at'] as String?) != null)
                _heure(commande['placed_at'] as String?)!,
            ].join('  ·  '),
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TovoTheme.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            (commande['dropoff_hint'] as String?) ?? '',
            style: const TextStyle(fontSize: 12, color: TovoTheme.inkDoux),
          ),
          const SizedBox(height: 2),
          // Ce que la boutique touchera réellement, commission déduite.
          // L'afficher évite la mauvaise surprise au moment du versement.
          Text(
            'Vous recevrez ${Money.format((commande['merchant_payout'] as num?)?.toInt() ?? 0)}',
            style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
          ),
          if (commande['order_items'] is List) ...[
            const SizedBox(height: 12),
            // Une photo par article : au comptoir, dix flacons se ressemblent
            // par le nom ; on les reconnaît à l'œil.
            for (final article
                in (commande['order_items'] as List).whereType<Map>())
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: TovoTheme.bloc,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: ((article['image_url'] as String?) ?? '').isEmpty
                          ? null
                          : ColoredBox(
                              color: Colors.white,
                              child: CatalogImage(
                                article['image_url'] as String,
                                fit: BoxFit.contain,
                                decodeWidth: 132,
                              ),
                            ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '${article['quantity']} ×',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${article['product_name']}'
                        '${(article['selections_label'] as String?)?.isNotEmpty == true ? ' · ${article['selections_label']}' : ''}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: TovoTheme.ink,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
          if (etape != null) ...[
            const SizedBox(height: 12),
            FilledButton(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
              onPressed: controller.actionEnCours(commande['id'] as String)
                  ? null
                  : () => controller.avancer(commande['id'] as String, etape),
              child: Text(MerchantController.libelleEtape(statut)),
            ),
          ],
        ],
      ),
    );
  }
}

class _AucuneBoutique extends StatelessWidget {
  const _AucuneBoutique();

  @override
  Widget build(BuildContext context) => ListView(
    children: const [
      _Message(
        icone: Icons.storefront_outlined,
        titre: 'Aucune boutique associée',
        detail:
            'Votre compte n’est rattaché à aucune boutique approuvée. '
            'Contactez Tovo pour finaliser votre inscription.',
      ),
    ],
  );
}

class _Message extends StatelessWidget {
  const _Message({
    required this.icone,
    required this.titre,
    required this.detail,
  });

  final IconData icone;
  final String titre;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 32),
      child: Column(
        children: [
          Icon(icone, size: 40, color: TovoTheme.muted),
          const SizedBox(height: 12),
          Text(
            titre,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: TovoTheme.muted),
          ),
        ],
      ),
    );
  }
}

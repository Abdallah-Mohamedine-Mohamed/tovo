import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../components/registry.dart';
import '../../core/api.dart';
import '../../core/deconnexion.dart';
import '../../core/theme.dart';
import 'driver_controller.dart';

/// Écran unique de l'app livreur.
///
/// Un seul état visible à la fois : disponible, ou en course. Pas d'onglets,
/// pas de navigation. Le livreur regarde son téléphone à l'arrêt, casque sur
/// la tête, sous le soleil — chaque écran doit tenir en un coup d'œil et
/// n'offrir qu'une seule action.
class DriverHome extends StatefulWidget {
  const DriverHome({super.key, required this.api});

  final TovoApi api;

  @override
  State<DriverHome> createState() => _DriverHomeState();
}

class _DriverHomeState extends State<DriverHome> {
  late final DriverController _c = DriverController(api: widget.api);

  @override
  void initState() {
    super.initState();
    _c.addListener(_maj);
    _c.start();
  }

  @override
  void dispose() {
    _c.removeListener(_maj);
    _c.dispose();
    super.dispose();
  }

  void _maj() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TovoTheme.surface,
      appBar: AppBar(
        title: const Text(
          'Tovo Livreur',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        actions: [
          // L'interrupteur de disponibilité est la commande la plus utilisée
          // de l'app : il reste toujours accessible, jamais enfoui.
          Row(
            children: [
              Text(
                _c.online ? 'En ligne' : 'Hors ligne',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: _c.online ? TovoTheme.success : TovoTheme.muted,
                ),
              ),
              Switch(
                value: _c.online,
                activeThumbColor: TovoTheme.success,
                onChanged: (v) => _c.setOnline(v),
              ),
            ],
          ),
          // Enfoui derrière un menu, et c'est voulu : à côté de
          // l'interrupteur de disponibilité, un doigt pressé se tromperait de
          // cible en plein service.
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
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _BandeauSync(controller: _c),
            _ResumeJournee(resume: _c.resume),
            const SizedBox(height: 16),
            if (_c.course != null)
              _CourseEnCours(controller: _c)
            else if (!_c.online)
              const _Repos()
            else if (_c.pool.isEmpty)
              const _AucuneCourse()
            else
              ..._c.pool.map((o) => _CarteCourse(ordre: o, controller: _c)),
          ],
        ),
      ),
    );
  }
}

/// Indicateur d'actions en attente de synchronisation.
///
/// Rendre l'attente visible évite que le livreur croie son geste perdu et le
/// refasse. C'est la contrepartie honnête d'une interface qui avance sans le
/// réseau.
class _BandeauSync extends StatelessWidget {
  const _BandeauSync({required this.controller});

  final DriverController controller;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: controller.queue.pending,
      builder: (context, enAttente, _) {
        final rejets = controller.queue.rejets;

        if (enAttente == 0 && rejets.isEmpty) return const SizedBox.shrink();

        if (rejets.isNotEmpty) {
          return _Bandeau(
            couleur: const Color(0xFFFDECEA),
            texte: rejets.first.message,
            icone: Icons.error_outline,
            teinte: TovoTheme.danger,
            action: TextButton(
              onPressed: () {
                controller.queue.clearRejets();
                controller.refresh();
              },
              child: const Text('OK'),
            ),
          );
        }

        return _Bandeau(
          couleur: const Color(0xFFFFF4E5),
          texte: '$enAttente action${enAttente > 1 ? 's' : ''} en attente de réseau',
          icone: Icons.cloud_off,
          teinte: const Color(0xFFB26A00),
        );
      },
    );
  }
}

class _Bandeau extends StatelessWidget {
  const _Bandeau({
    required this.couleur,
    required this.texte,
    required this.icone,
    required this.teinte,
    this.action,
  });

  final Color couleur;
  final String texte;
  final IconData icone;
  final Color teinte;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: couleur,
        borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
      ),
      child: Row(
        children: [
          Icon(icone, size: 18, color: teinte),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              texte,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: teinte),
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}

/// Gains et cash du jour.
///
/// Les deux montants sont séparés délibérément : ce que le livreur GAGNE et
/// ce qu'il DOIT reverser ne se compensent pas. Les afficher ensemble, ou
/// pire en solde net, ferait croire à un gain de 4 900 F sur une course qui
/// en rapporte 500.
class _ResumeJournee extends StatelessWidget {
  const _ResumeJournee({required this.resume});

  final Map<String, dynamic> resume;

  int _v(String cle) => (resume[cle] as num?)?.toInt() ?? 0;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        border: Border.all(color: const Color(0x12000000)),
      ),
      child: Row(
        children: [
          _Chiffre(libelle: 'Courses', valeur: '${_v('courses')}'),
          _Separateur(),
          _Chiffre(
            libelle: 'Gagné',
            valeur: Money.format(_v('earned')),
            couleur: TovoTheme.success,
          ),
          _Separateur(),
          _Chiffre(
            libelle: 'À reverser',
            valeur: Money.format(_v('cash_due')),
            couleur: TovoTheme.teal,
          ),
        ],
      ),
    );
  }
}

class _Chiffre extends StatelessWidget {
  const _Chiffre({required this.libelle, required this.valeur, this.couleur});

  final String libelle;
  final String valeur;
  final Color? couleur;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            valeur,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: couleur ?? TovoTheme.ink,
            ),
          ),
          const SizedBox(height: 2),
          Text(libelle, style: const TextStyle(fontSize: 11, color: TovoTheme.muted)),
        ],
      ),
    );
  }
}

class _Separateur extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Container(width: 1, height: 30, color: TovoTheme.line);
}

/// Une course disponible dans le pool.
class _CarteCourse extends StatelessWidget {
  const _CarteCourse({required this.ordre, required this.controller});

  final Map<String, dynamic> ordre;
  final DriverController controller;

  @override
  Widget build(BuildContext context) {
    final gain = (ordre['driver_earning'] as num?)?.toInt() ?? 0;
    final total = (ordre['total'] as num?)?.toInt() ?? 0;
    final coursier = ordre['type'] == 'courier';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
        border: Border.all(color: const Color(0x12000000)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                coursier ? Icons.inventory_2_outlined : Icons.restaurant_outlined,
                size: 18,
                color: TovoTheme.teal,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  coursier ? 'Colis' : 'Livraison',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ),
              // Le gain du livreur en premier et en gros : c'est l'information
              // sur laquelle il décide. Le total de la commande n'est là que
              // pour savoir combien encaisser.
              Text(
                Money.format(gain),
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  color: TovoTheme.success,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            (ordre['dropoff_hint'] as String?) ?? '',
            style: const TextStyle(fontSize: 13, color: TovoTheme.ink),
          ),
          const SizedBox(height: 2),
          Text(
            'À encaisser : ${Money.format(total)}',
            style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => controller.accepter(ordre),
            child: const Text('Accepter'),
          ),
        ],
      ),
    );
  }
}

/// La course en cours — un seul bouton, celui de l'étape suivante.
class _CourseEnCours extends StatefulWidget {
  const _CourseEnCours({required this.controller});

  final DriverController controller;

  @override
  State<_CourseEnCours> createState() => _CourseEnCoursState();
}

class _CourseEnCoursState extends State<_CourseEnCours> {
  File? _preuve;

  DriverController get controller => widget.controller;

  Future<void> _photographier() async {
    final fichier = await ImagePicker().pickImage(
      source: ImageSource.camera,
      maxWidth: 1024,
      imageQuality: 70,
    );
    if (fichier == null || !mounted) return;
    setState(() => _preuve = File(fichier.path));
  }

  static const Map<String, String> _libelles = {
    'assigned': 'Allez chercher la commande',
    'picked_up': 'Commande récupérée',
    'delivering': 'En route vers le client',
  };

  @override
  Widget build(BuildContext context) {
    final course = controller.course!;
    final dropoff = (course['dropoff'] as Map?)?.cast<String, dynamic>() ?? const {};
    final pickup = (course['pickup'] as Map?)?.cast<String, dynamic>();
    final boutique = (course['merchant'] as Map?)?.cast<String, dynamic>();
    final client = (course['client'] as Map?)?.cast<String, dynamic>();
    final articles = ((course['items'] as List?) ?? const [])
        .whereType<Map<dynamic, dynamic>>()
        .map((a) => a.cast<String, dynamic>())
        .toList(growable: false);
    // Une fois parti livrer, la boutique n'est plus le sujet.
    final enRouteVersClient = controller.statut == 'delivering';
    final etape = controller.prochaineEtape;
    final dejaPaye =
        course['payment_method'] == 'mobile_money' && course['payment_status'] == 'paid';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(TovoTheme.radiusCard),
            border: Border.all(color: const Color(0x12000000)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _libelles[controller.statut] ?? controller.statut,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: TovoTheme.teal,
                ),
              ),
              const SizedBox(height: 16),
              // Les deux points de la course, chacun avec de quoi s'y rendre
              // et joindre quelqu'un sur place. Le point ACTIF est mis en
              // avant : un livreur en circulation ne doit pas avoir à
              // choisir entre deux itinéraires.
              _EtapeCourse(
                couleur: TovoTheme.teal,
                titre: 'Récupérer',
                nom: (boutique?['name'] as String?) ??
                    (course['merchant_name'] as String?),
                repere: (pickup?['hint'] as String?) ?? (boutique?['hint'] as String?),
                telephone: boutique?['phone'] as String?,
                lat: _nombre(pickup?['lat'] ?? boutique?['lat']),
                lng: _nombre(pickup?['lng'] ?? boutique?['lng']),
                actif: !enRouteVersClient,
              ),
              const SizedBox(height: 12),
              _EtapeCourse(
                couleur: TovoTheme.danger,
                titre: 'Livrer',
                nom: client?['name'] as String?,
                repere: dropoff['hint'] as String?,
                telephone: client?['phone'] as String?,
                lat: _nombre(dropoff['lat']),
                lng: _nombre(dropoff['lng']),
                actif: enRouteVersClient,
              ),

              // Ce qu'il transporte. Sans cette liste, le livreur ne peut ni
              // vérifier le sac que lui tend la boutique, ni répondre au
              // client qui demande si son supplément a bien été mis.
              if (articles.isNotEmpty) ...[
                const Divider(height: 28),
                const Text(
                  'Contenu',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    color: TovoTheme.muted,
                  ),
                ),
                const SizedBox(height: 8),
                for (final a in articles) _LigneArticle(article: a),
              ],

              if ((course['note'] as String?)?.trim().isNotEmpty ?? false) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: TovoTheme.tealSoft,
                    borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
                  ),
                  child: Text(
                    'Note du client : ${course['note']}',
                    style: const TextStyle(fontSize: 12, height: 1.4),
                  ),
                ),
              ],

              const Divider(height: 28),
              // Un paiement déjà constaté ne doit surtout pas s'afficher
              // comme « à encaisser » : le livreur réclamerait une seconde
              // fois de l'argent que le client a déjà versé.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    dejaPaye ? 'Déjà payé' : 'À encaisser',
                    style: const TextStyle(fontSize: 13, color: TovoTheme.muted),
                  ),
                  Text(
                    Money.format((course['total'] as num?)?.toInt() ?? 0),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: dejaPaye ? TovoTheme.success : null,
                      decoration: dejaPaye ? TextDecoration.lineThrough : null,
                    ),
                  ),
                ],
              ),
              if (dejaPaye)
                const Padding(
                  padding: EdgeInsets.only(top: 4),
                  child: Text(
                    'Réglé par Nita. Ne rien réclamer au client.',
                    style: TextStyle(fontSize: 12, color: TovoTheme.success),
                  ),
                ),
            ],
          ),
        ),
        // Le client a annoncé payer par Nita mais rien n'est constaté : il a
        // pu envoyer l'argent directement, hors de l'achat en ligne. Aucune
        // API ne peut le voir — seul le livreur, devant lui, le sait.
        if (controller.paiementNitaADemander) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              foregroundColor: TovoTheme.teal,
            ),
            onPressed: controller.confirmerPaiement,
            icon: const Icon(Icons.check_circle_outline, size: 20),
            label: const Text(
              'Le client a payé par Nita',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        ],
        // La photo n’est proposée qu’au dernier geste, et reste
        // facultative : un livreur sous la pluie, de nuit, dans une cour
        // sans lumière, ne doit pas être bloqué par un appareil photo.
        if (etape == 'delivered') ...[
          const SizedBox(height: 12),
          _BoutonPreuve(fichier: _preuve, onTap: _photographier),
        ],
        const SizedBox(height: 16),
        if (etape != null)
          FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              backgroundColor:
                  etape == 'delivered' ? TovoTheme.success : TovoTheme.teal,
            ),
            onPressed: () => controller.avancer(etape, preuveLocale: _preuve?.path),
            child: Text(
              controller.libelleProchaineEtape,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
      ],
    );
  }
}

class _BoutonPreuve extends StatelessWidget {
  const _BoutonPreuve({required this.fichier, required this.onTap});

  final File? fichier;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
          border: Border.all(
            color: fichier != null ? TovoTheme.success : const Color(0x14000000),
          ),
        ),
        child: Row(
          children: [
            if (fichier != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(fichier!, width: 40, height: 40, fit: BoxFit.cover),
              )
            else
              const Icon(Icons.photo_camera_outlined, color: TovoTheme.muted),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                fichier != null ? 'Photo prise' : 'Photo de livraison (facultatif)',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fichier != null ? TovoTheme.success : TovoTheme.muted,
                ),
              ),
            ),
            if (fichier != null)
              const Icon(Icons.check_circle, size: 18, color: TovoTheme.success),
          ],
        ),
      ),
    );
  }
}

/// Les coordonnées arrivent en `num` ou en `String` selon le chemin par
/// lequel la commande a transité. Un `as double?` sec renvoyait `null` sur un
/// entier — et le bouton d'itinéraire disparaissait sans explication.
double? _nombre(dynamic valeur) => switch (valeur) {
      num n => n.toDouble(),
      String s => double.tryParse(s),
      _ => null,
    };

/// Ouvre l'itinéraire dans l'application de cartes du téléphone.
///
/// On n'affiche PAS de carte dans l'app : le livreur utilise déjà Google Maps
/// et le connaît par cœur. Une carte maison lui ferait perdre le guidage
/// vocal, le trafic et les raccourcis qu'il connaît — pour afficher moins.
Future<void> _itineraire(double lat, double lng) async {
  final uri = Uri.parse(
    'https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving',
  );
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

Future<void> _appeler(String numero) async {
  final propre = numero.replaceAll(RegExp(r'[^\d+]'), '');
  await launchUrl(Uri.parse('tel:$propre'));
}

/// Un point de la course : où aller, qui appeler.
class _EtapeCourse extends StatelessWidget {
  const _EtapeCourse({
    required this.couleur,
    required this.titre,
    required this.nom,
    required this.repere,
    required this.telephone,
    required this.lat,
    required this.lng,
    required this.actif,
  });

  final Color couleur;
  final String titre;
  final String? nom;
  final String? repere;
  final String? telephone;
  final double? lat;
  final double? lng;

  /// Le point vers lequel le livreur se dirige maintenant.
  final bool actif;

  @override
  Widget build(BuildContext context) {
    final aPosition = lat != null && lng != null;
    final aTelephone = (telephone ?? '').trim().isNotEmpty;

    return Opacity(
      // L'étape franchie s'efface sans disparaître : le livreur peut encore
      // rappeler la boutique s'il s'aperçoit d'un oubli en chemin.
      opacity: actif ? 1 : 0.55,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: actif ? couleur.withValues(alpha: 0.06) : Colors.transparent,
          borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
          border: Border.all(
            color: actif ? couleur.withValues(alpha: 0.35) : const Color(0x14000000),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 9,
                  height: 9,
                  decoration: BoxDecoration(color: couleur, shape: BoxShape.circle),
                ),
                const SizedBox(width: 8),
                Text(
                  titre.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: TovoTheme.muted,
                    letterSpacing: 0.6,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            if ((nom ?? '').trim().isNotEmpty)
              Text(
                nom!,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
              ),
            if ((repere ?? '').trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  repere!,
                  style: const TextStyle(fontSize: 13, height: 1.35),
                ),
              ),
            if (!aPosition && !aTelephone)
              const Padding(
                padding: EdgeInsets.only(top: 2),
                child: Text(
                  'Aucun repère enregistré',
                  style: TextStyle(fontSize: 12, color: TovoTheme.muted),
                ),
              ),
            if (aPosition || aTelephone) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  if (aPosition)
                    Expanded(
                      child: FilledButton.tonalIcon(
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                        ),
                        onPressed: () => _itineraire(lat!, lng!),
                        icon: const Icon(Icons.directions, size: 18),
                        label: const Text(
                          'Itinéraire',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  if (aPosition && aTelephone) const SizedBox(width: 8),
                  if (aTelephone)
                    Expanded(
                      child: OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(44),
                          foregroundColor: TovoTheme.teal,
                        ),
                        onPressed: () => _appeler(telephone!),
                        icon: const Icon(Icons.call, size: 18),
                        label: const Text(
                          'Appeler',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _LigneArticle extends StatelessWidget {
  const _LigneArticle({required this.article});

  final Map<String, dynamic> article;

  @override
  Widget build(BuildContext context) {
    final options = (article['selections_label'] as String?)?.trim() ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '${article['quantity'] ?? 1}×',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${article['product_name'] ?? ''}',
                  style: const TextStyle(fontSize: 13),
                ),
                if (options.isNotEmpty)
                  Text(
                    options,
                    style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Repos extends StatelessWidget {
  const _Repos();

  @override
  Widget build(BuildContext context) => const _Message(
        icone: Icons.nightlight_outlined,
        titre: 'Vous êtes hors ligne',
        detail: 'Passez en ligne pour recevoir des courses.',
      );
}

class _AucuneCourse extends StatelessWidget {
  const _AucuneCourse();

  @override
  Widget build(BuildContext context) => const _Message(
        icone: Icons.check_circle_outline,
        titre: 'Aucune course pour le moment',
        detail: 'Vous serez prévenu dès qu’une course est disponible.',
      );
}

class _Message extends StatelessWidget {
  const _Message({required this.icone, required this.titre, required this.detail});

  final IconData icone;
  final String titre;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
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

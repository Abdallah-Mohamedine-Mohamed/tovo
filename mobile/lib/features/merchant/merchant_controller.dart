import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/api.dart';

/// État de l'app boutiquier.
///
/// Deux sources de données, et le partage entre les deux n'est pas arbitraire.
///
/// LES COMMANDES passent par le backend. Faire avancer un statut déclenche le
/// dispatch des livreurs ; court-circuiter la route laisserait la commande
/// prête sans que personne ne soit prévenu.
///
/// LE CATALOGUE passe directement par Supabase. Modifier le prix d'un
/// beignet ou le rendre indisponible ne demande aucun calcul serveur, et la
/// RLS interdit déjà de toucher au catalogue d'une autre boutique. Ajouter
/// une route ne ferait qu'ajouter un intermédiaire.
class MerchantController extends ChangeNotifier {
  MerchantController({required TovoApi api, SupabaseClient? db})
      : _api = api,
        _db = db ?? Supabase.instance.client;

  final TovoApi _api;
  final SupabaseClient _db;

  RealtimeChannel? _canal;

  Map<String, dynamic>? boutique;
  List<Map<String, dynamic>> commandes = const [];
  List<Map<String, dynamic>> produits = const [];

  bool chargement = false;
  String? erreur;

  String? get boutiqueId => boutique?['id'] as String?;
  bool get ouverte => boutique?['is_open'] as bool? ?? false;

  /// Commandes qui réclament une action immédiate du boutiquier.
  List<Map<String, dynamic>> get aTraiter =>
      commandes.where((c) => c['status'] == 'pending').toList(growable: false);

  Future<void> start() async {
    await refresh();
    _ecouter();
  }

  @override
  void dispose() {
    if (_canal != null) _db.removeChannel(_canal!);
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Temps réel
  // ------------------------------------------------------------------

  /// Une commande entrante doit apparaître sans que le boutiquier touche à
  /// l'écran : il est derrière son comptoir, les mains occupées. Un
  /// rafraîchissement manuel ferait perdre des minutes sur chaque commande.
  void _ecouter() {
    final id = boutiqueId;
    if (id == null || _canal != null) return;

    _canal = _db
        .channel('tovo:merchant:$id')
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'orders',
          filter: PostgresChangeFilter(
            type: PostgresChangeFilterType.eq,
            column: 'merchant_id',
            value: id,
          ),
          callback: (_) => refresh(silencieux: true),
        )
        .subscribe();
  }

  // ------------------------------------------------------------------
  // Chargement
  // ------------------------------------------------------------------

  Future<void> refresh({bool silencieux = false}) async {
    if (!silencieux) {
      chargement = true;
      erreur = null;
      notifyListeners();
    }

    try {
      // La RLS restreint déjà aux boutiques dont on est propriétaire :
      // inutile de filtrer sur owner_id, ce serait redondant et faux le jour
      // où un compte gérera deux boutiques.
      final boutiques = await _db
          .from('merchants')
          .select('id, name, is_open, prep_time_min, address_hint')
          .limit(1);

      boutique = boutiques.isNotEmpty ? boutiques.first : null;

      if (boutiqueId != null) {
        final reponse = await _api.get('/merchant/orders');
        if (reponse.ok) commandes = reponse.list('orders');

        produits = await _db
            .from('products')
            .select('id, name, price, is_available, image_url')
            .eq('merchant_id', boutiqueId!)
            .order('name');
      }
    } on Exception catch (cause) {
      erreur = 'Impossible de charger : $cause';
    }

    chargement = false;
    _ecouter();
    notifyListeners();
  }

  // ------------------------------------------------------------------
  // Actions
  // ------------------------------------------------------------------

  /// Ouvrir ou fermer la boutique.
  ///
  /// Fermée, elle reste visible au catalogue mais `cart_view` bloque le
  /// paiement — le client voit les produits sans pouvoir commander, ce qui
  /// vaut mieux que de disparaître complètement.
  Future<void> basculerOuverture() async {
    final id = boutiqueId;
    if (id == null) return;

    final nouvelEtat = !ouverte;
    boutique = {...boutique!, 'is_open': nouvelEtat};
    notifyListeners();

    try {
      await _db.from('merchants').update({'is_open': nouvelEtat}).eq('id', id);
    } on Exception {
      // Retour en arrière : un interrupteur qui ment sur l'état réel de la
      // boutique ferait accepter des commandes qu'on ne peut pas préparer.
      boutique = {...boutique!, 'is_open': !nouvelEtat};
      erreur = "L'ouverture n'a pas pu être enregistrée.";
      notifyListeners();
    }
  }

  Future<void> basculerDisponibilite(Map<String, dynamic> produit) async {
    final id = produit['id'] as String?;
    if (id == null) return;

    final nouvelEtat = !(produit['is_available'] as bool? ?? true);

    produits = produits
        .map((p) => p['id'] == id ? {...p, 'is_available': nouvelEtat} : p)
        .toList(growable: false);
    notifyListeners();

    try {
      await _db.from('products').update({'is_available': nouvelEtat}).eq('id', id);
    } on Exception {
      await refresh(silencieux: true);
    }
  }

  /// Fait avancer une commande.
  ///
  /// Passe par le backend et non par Supabase : c'est le passage à `ready`
  /// qui met la commande en file de dispatch.
  Future<void> avancer(String orderId, String statut) async {
    final reponse = await _api.post('/orders/$orderId/status', {'status': statut});
    if (!reponse.ok) {
      erreur = reponse.content;
      notifyListeners();
      return;
    }
    await refresh(silencieux: true);
  }

  static String? etapeSuivante(String statut) => switch (statut) {
        'pending' => 'confirmed',
        'confirmed' => 'preparing',
        'preparing' => 'ready',
        _ => null,
      };

  static String libelleEtape(String statut) => switch (statut) {
        'pending' => 'Accepter',
        'confirmed' => 'En préparation',
        'preparing' => 'Prête pour le livreur',
        _ => '',
      };

  static String libelleStatut(String statut) => switch (statut) {
        'pending' => 'Nouvelle commande',
        'confirmed' => 'Acceptée',
        'preparing' => 'En préparation',
        'ready' => 'En attente d’un livreur',
        'assigned' => 'Livreur en route',
        'picked_up' => 'Récupérée',
        'delivering' => 'En livraison',
        'delivered' => 'Livrée',
        'cancelled' => 'Annulée',
        _ => statut,
      };
}

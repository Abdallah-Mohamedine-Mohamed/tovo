import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/deconnexion.dart';
import '../../core/theme.dart';
import '../../components/widgets/read_placeholder.dart';
import 'conversation_chrome.dart';

/// La liste des conversations, en tiroir.
///
/// Les échanges étaient enregistrés depuis le premier jour et personne ne
/// pouvait y revenir : chaque lancement ouvrait un fil neuf, et ce qu'on
/// avait dit la veille devenait introuvable. Un client qui a commandé
/// mercredi doit pouvoir retrouver cette conversation, ne serait-ce que pour
/// recommander la même chose.
class TiroirConversations extends StatefulWidget {
  const TiroirConversations({
    super.key,
    required this.api,
    required this.onOuvrir,
    required this.onNouvelle,
    this.conversationCourante,
    this.onPanier,
    this.onCatalogue,
  });

  final TovoApi api;
  final void Function(String conversationId) onOuvrir;
  final VoidCallback onNouvelle;
  final String? conversationCourante;
  final VoidCallback? onPanier;
  final VoidCallback? onCatalogue;

  @override
  State<TiroirConversations> createState() => _TiroirConversationsState();
}

class _TiroirConversationsState extends State<TiroirConversations> {
  List<Map<String, dynamic>> _conversations = const [];
  bool _charge = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _recharger();
  }

  Future<void> _recharger() async {
    final request = widget.api.get('/conversations');
    final cached = await widget.api.cachedGet('/conversations');
    if (!mounted) return;
    if (cached != null) {
      setState(() {
        _conversations = cached.list('conversations');
        _charge = false;
      });
    }
    final reponse = await request;
    if (!mounted) return;

    setState(() {
      _charge = false;
      if (!reponse.ok) {
        _error = reponse.content;
        return;
      }
      _error = null;
      _conversations = ((reponse.raw['conversations'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();
    });
  }

  /// « aujourd'hui », « hier », puis la date.
  ///
  /// Une heure précise n'apprend rien trois jours plus tard, et un
  /// horodatage complet encombre une liste qu'on parcourt du regard.
  String _quand(String? iso) {
    final date = DateTime.tryParse(iso ?? '')?.toLocal();
    if (date == null) return '';

    final maintenant = DateTime.now();
    final jours = DateTime(
      maintenant.year,
      maintenant.month,
      maintenant.day,
    ).difference(DateTime(date.year, date.month, date.day)).inDays;

    if (jours == 0) return "aujourd'hui";
    if (jours == 1) return 'hier';
    if (jours < 7) return 'il y a $jours jours';
    return '${date.day}/${date.month}';
  }

  static const _ligne = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w500,
    color: TovoTheme.ink,
  );

  @override
  Widget build(BuildContext context) {
    return Drawer(
      width: MediaQuery.sizeOf(context).width.clamp(280, 360).toDouble(),
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.onPanier != null)
              ListTile(
                leading: const ConversationIcon(ConversationSymbol.cart),
                title: const Text('Mon panier', style: _ligne),
                onTap: () {
                  Navigator.pop(context);
                  widget.onPanier!();
                },
              ),
            if (widget.onCatalogue != null)
              ListTile(
                leading: const ConversationIcon(ConversationSymbol.store),
                title: const Text('Explorer les boutiques', style: _ligne),
                onTap: () {
                  Navigator.pop(context);
                  widget.onCatalogue!();
                },
              ),
            // Une ligne comme les autres, pas un gros bouton plein : le
            // panneau entier parle la langue des symboles du haut.
            ListTile(
              leading: const ConversationIcon(ConversationSymbol.compose),
              title: const Text('Nouvelle conversation', style: _ligne),
              onTap: () {
                Navigator.of(context).pop();
                widget.onNouvelle();
              },
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 22, 22, 8),
              child: Text(
                'Récentes',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: TovoTheme.muted,
                ),
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Column(
                  children: [
                    Text(_error!, style: const TextStyle(fontSize: 12)),
                    TextButton(
                      onPressed: _recharger,
                      child: const Text('Réessayer'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: _charge
                  ? const SingleChildScrollView(child: ReadPlaceholder())
                  : _conversations.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.fromLTRB(22, 20, 22, 0),
                      child: Text(
                        'Vos échanges apparaîtront ici.',
                        style: TextStyle(fontSize: 13, color: TovoTheme.muted),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      itemCount: _conversations.length,
                      itemBuilder: (context, i) {
                        final c = _conversations[i];
                        final id = '${c['id']}';
                        final courante = id == widget.conversationCourante;

                        return ListTile(
                          dense: false,
                          selected: courante,
                          selectedTileColor: const Color(0xFFF4F5F5),
                          leading: const ConversationIcon(
                            ConversationSymbol.bubble,
                            size: 20,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(
                              TovoTheme.radiusChip,
                            ),
                          ),
                          title: Text(
                            '${c['title'] ?? 'Conversation'}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: courante
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                              color: TovoTheme.ink,
                            ),
                          ),
                          subtitle: Text(
                            _quand(c['updated_at'] as String?),
                            style: const TextStyle(
                              fontSize: 11,
                              color: TovoTheme.muted,
                            ),
                          ),
                          onTap: () {
                            Navigator.of(context).pop();
                            widget.onOuvrir(id);
                          },
                        );
                      },
                    ),
            ),

            // En pied de panneau, sous les conversations : c'est là qu'on
            // cherche son compte, et l'app client n'offrait jusqu'ici aucune
            // façon d'en sortir.
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: const ConversationIcon(
                ConversationSymbol.logout,
                size: 20,
                color: TovoTheme.muted,
              ),
              title: const Text(
                'Se déconnecter',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: TovoTheme.muted,
                ),
              ),
              onTap: () {
                // Le contexte du navigateur racine est pris AVANT de fermer :
                // celui-ci appartient au tiroir, qui est démonté par le `pop`.
                // La boîte de dialogue s'ouvrirait alors sur un élément mort.
                final racine = Navigator.of(
                  context,
                  rootNavigator: true,
                ).context;
                Navigator.of(context).pop();
                unawaited(confirmerDeconnexion(racine));
              },
            ),
          ],
        ),
      ),
    );
  }
}

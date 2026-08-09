import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api.dart';
import '../../core/deconnexion.dart';
import '../../core/marque.dart';
import '../../core/theme.dart';

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
  });

  final TovoApi api;
  final void Function(String conversationId) onOuvrir;
  final VoidCallback onNouvelle;
  final String? conversationCourante;

  @override
  State<TiroirConversations> createState() => _TiroirConversationsState();
}

class _TiroirConversationsState extends State<TiroirConversations> {
  List<Map<String, dynamic>> _conversations = const [];
  bool _charge = true;

  @override
  void initState() {
    super.initState();
    _recharger();
  }

  Future<void> _recharger() async {
    final reponse = await widget.api.get('/conversations');
    if (!mounted) return;

    setState(() {
      _charge = false;
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
    final jours = DateTime(maintenant.year, maintenant.month, maintenant.day)
        .difference(DateTime(date.year, date.month, date.day))
        .inDays;

    if (jours == 0) return "aujourd'hui";
    if (jours == 1) return 'hier';
    if (jours < 7) return 'il y a $jours jours';
    return '${date.day}/${date.month}';
  }

  @override
  Widget build(BuildContext context) {
    return Drawer(
      backgroundColor: Colors.white,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 16, 10),
              child: Row(
                children: [
                  const MarqueTovo(taille: 26),
                  const SizedBox(width: 10),
                  const Text(
                    'tovo',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: TovoTheme.teal,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(46),
                  backgroundColor: TovoTheme.tealSoft,
                  foregroundColor: TovoTheme.teal,
                  elevation: 0,
                ),
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onNouvelle();
                },
                icon: const Icon(Icons.add, size: 18),
                label: const Text(
                  'Nouvelle conversation',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 22),
              child: Text(
                'Vos conversations',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: TovoTheme.muted),
              ),
            ),
            const SizedBox(height: 6),
            Expanded(
              child: _charge
                  ? const Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: TovoTheme.teal),
                      ),
                    )
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
                              dense: true,
                              selected: courante,
                              selectedTileColor: TovoTheme.tealSoft,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
                              ),
                              title: Text(
                                '${c['title'] ?? 'Conversation'}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: courante ? FontWeight.w700 : FontWeight.w500,
                                  color: courante ? TovoTheme.teal : TovoTheme.ink,
                                ),
                              ),
                              subtitle: Text(
                                _quand(c['updated_at'] as String?),
                                style: const TextStyle(fontSize: 11, color: TovoTheme.muted),
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
              leading: const Icon(Icons.logout, size: 18, color: TovoTheme.muted),
              title: const Text(
                'Se déconnecter',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: TovoTheme.muted),
              ),
              onTap: () {
                // Le contexte du navigateur racine est pris AVANT de fermer :
                // celui-ci appartient au tiroir, qui est démonté par le `pop`.
                // La boîte de dialogue s'ouvrirait alors sur un élément mort.
                final racine = Navigator.of(context, rootNavigator: true).context;
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

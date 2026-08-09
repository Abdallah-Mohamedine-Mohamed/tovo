import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/theme.dart';

/// Les horaires d'ouverture, réglés par le boutiquier.
///
/// La reprise depuis 6ammart a rempli ces horaires, mais beaucoup vont
/// jusqu'à 23:59 parce que l'ancien système les créait ainsi par défaut. Une
/// boutique qui ferme réellement à 22 h reste donc affichée ouverte jusqu'à
/// minuit — et le client commande dans le vide.
///
/// Personne d'autre que le boutiquier ne connaît ses vraies heures.
class EditeurHoraires extends StatefulWidget {
  const EditeurHoraires({super.key, required this.merchantId});

  final String merchantId;

  @override
  State<EditeurHoraires> createState() => _EditeurHorairesState();
}

/// 0 = dimanche, comme `extract(dow)` de Postgres et comme le stockait
/// 6ammart. Aligner les trois évite un décalage d'un jour que personne ne
/// remarque avant qu'un client ne trouve tout fermé le lundi.
const List<String> _jours = [
  'Dimanche',
  'Lundi',
  'Mardi',
  'Mercredi',
  'Jeudi',
  'Vendredi',
  'Samedi',
];

class _Plage {
  _Plage({required this.ouvre, required this.ferme});

  TimeOfDay ouvre;
  TimeOfDay ferme;
}

class _EditeurHorairesState extends State<EditeurHoraires> {
  final _db = Supabase.instance.client;

  /// Une seule plage par jour. Les doubles services — midi puis soir —
  /// existent, mais les demander à tout le monde compliquerait l'écran pour
  /// une minorité ; le schéma les accepte déjà si on veut les ajouter.
  final Map<int, _Plage?> _semaine = {for (var j = 0; j < 7; j++) j: null};

  bool _charge = true;
  bool _enregistre = false;
  String? _erreur;

  @override
  void initState() {
    super.initState();
    _lire();
  }

  TimeOfDay _versHeure(String sql) {
    final p = sql.split(':');
    return TimeOfDay(hour: int.tryParse(p[0]) ?? 0, minute: int.tryParse(p[1]) ?? 0);
  }

  String _versSql(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';

  String _libelle(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}h${t.minute.toString().padLeft(2, '0')}';

  Future<void> _lire() async {
    try {
      final lignes = await _db
          .from('merchant_hours')
          .select('day, opens_at, closes_at')
          .eq('merchant_id', widget.merchantId)
          .order('day');

      for (final l in lignes) {
        final jour = (l['day'] as num).toInt();
        _semaine[jour] = _Plage(
          ouvre: _versHeure('${l['opens_at']}'),
          ferme: _versHeure('${l['closes_at']}'),
        );
      }
    } catch (_) {
      _erreur = 'Horaires illisibles. Vérifiez votre réseau.';
    }

    if (mounted) setState(() => _charge = false);
  }

  Future<void> _choisir(int jour, bool ouverture) async {
    final actuel = _semaine[jour];
    final depart = ouverture
        ? (actuel?.ouvre ?? const TimeOfDay(hour: 8, minute: 0))
        : (actuel?.ferme ?? const TimeOfDay(hour: 22, minute: 0));

    final choisi = await showTimePicker(context: context, initialTime: depart);
    if (choisi == null || !mounted) return;

    setState(() {
      final p = _semaine[jour] ??
          _Plage(
            ouvre: const TimeOfDay(hour: 8, minute: 0),
            ferme: const TimeOfDay(hour: 22, minute: 0),
          );
      if (ouverture) {
        p.ouvre = choisi;
      } else {
        p.ferme = choisi;
      }
      _semaine[jour] = p;
    });
  }

  Future<void> _enregistrer() async {
    // Une plage inversée fermerait la boutique toute la journée sans que
    // rien ne le signale.
    for (final entree in _semaine.entries) {
      final p = entree.value;
      if (p == null) continue;
      final debut = p.ouvre.hour * 60 + p.ouvre.minute;
      final fin = p.ferme.hour * 60 + p.ferme.minute;
      if (fin <= debut) {
        setState(() => _erreur =
            '${_jours[entree.key]} : la fermeture doit être après l’ouverture.');
        return;
      }
    }

    setState(() {
      _enregistre = true;
      _erreur = null;
    });

    try {
      // On remplace la semaine entière plutôt que de rapprocher ligne par
      // ligne : un jour retiré de l'écran doit disparaître de la base, et
      // une mise à jour sélective laisserait des horaires fantômes.
      await _db.from('merchant_hours').delete().eq('merchant_id', widget.merchantId);

      final lignes = _semaine.entries
          .where((e) => e.value != null)
          .map((e) => {
                'merchant_id': widget.merchantId,
                'day': e.key,
                'opens_at': _versSql(e.value!.ouvre),
                'closes_at': _versSql(e.value!.ferme),
              })
          .toList();

      if (lignes.isNotEmpty) {
        await _db.from('merchant_hours').insert(lignes);
      }

      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _enregistre = false;
          _erreur = "L'enregistrement a échoué. Réessayez.";
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TovoTheme.surface,
      appBar: AppBar(
        title: const Text('Horaires', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        actions: [
          TextButton(
            onPressed: _enregistre ? null : _enregistrer,
            child: Text(_enregistre ? '…' : 'Enregistrer'),
          ),
        ],
      ),
      body: _charge
          ? const Center(child: CircularProgressIndicator(color: TovoTheme.teal))
          : ListView(
              padding: const EdgeInsets.all(14),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 0, 4, 14),
                  child: Text(
                    'Votre boutique n’apparaît ouverte aux clients que pendant '
                    'ces heures, et seulement si l’interrupteur du haut est '
                    'levé.',
                    style: TextStyle(fontSize: 12, color: TovoTheme.muted, height: 1.5),
                  ),
                ),
                for (var jour = 0; jour < 7; jour++) _ligneJour(jour),
                if (_erreur != null) ...[
                  const SizedBox(height: 14),
                  Text(
                    _erreur!,
                    style: const TextStyle(fontSize: 12, color: TovoTheme.danger),
                  ),
                ],
              ],
            ),
    );
  }

  Widget _ligneJour(int jour) {
    final p = _semaine[jour];
    final ouvert = p != null;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(TovoTheme.radiusChip),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(
              _jours[jour],
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(
            child: ouvert
                ? Row(
                    children: [
                      TextButton(
                        onPressed: () => _choisir(jour, true),
                        child: Text(_libelle(p.ouvre)),
                      ),
                      const Text('→', style: TextStyle(color: TovoTheme.muted)),
                      TextButton(
                        onPressed: () => _choisir(jour, false),
                        child: Text(_libelle(p.ferme)),
                      ),
                    ],
                  )
                : const Padding(
                    padding: EdgeInsets.only(left: 12),
                    child: Text(
                      'Fermé',
                      style: TextStyle(fontSize: 13, color: TovoTheme.muted),
                    ),
                  ),
          ),
          Switch(
            value: ouvert,
            activeThumbColor: TovoTheme.success,
            onChanged: (v) => setState(() {
              _semaine[jour] = v
                  ? _Plage(
                      ouvre: const TimeOfDay(hour: 8, minute: 0),
                      ferme: const TimeOfDay(hour: 22, minute: 0),
                    )
                  : null;
            }),
          ),
        ],
      ),
    );
  }
}

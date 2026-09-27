import { useCallback, useEffect, useState } from 'react';
import { List } from '@refinedev/antd';
import { useNotification } from '@refinedev/core';
import {
  Alert, Button, Card, Col, Empty, Input, InputNumber, Radio, Row, Select, Space, Statistic, Switch, Tag, Typography,
} from 'antd';
import { supabaseClient } from '../supabaseClient';

/**
 * Qualité de l'IA — l'examen de l'assistant, et les phrases à trancher.
 *
 * La boucle du banc (lancée par le serveur, réglable en haut de la page)
 * relit les phrases tapées dans l'app et fait écrire des phrases de clients
 * imaginés par deux IA puissantes (Gemini et GPT). Quand les avis divergent,
 * la phrase arrive ici. L'humain dit ce qu'elle veut dire :
 *   - un sens unique ;
 *   - ambiguë : l'assistant doit proposer des tuiles (les choix à cocher) ;
 *   - erronée : incompréhensible, l'assistant ne doit pas agir.
 * « Valider » la met dans l'examen ; « Écarter » la retire. Accès : admins.
 */

const INTENTIONS: Record<string, string> = {
  recherche: 'Cherche un produit',
  envie: 'Envie, sans produit précis',
  boutique: 'Veut une boutique',
  livreur: 'Veut un livreur',
  colis: 'Envoie un colis',
  designe: 'Désigne ce qu’il voit',
  panier: 'Voir ou valider son panier',
  habitude: 'Refaire une commande',
  suivi: 'Suivi de commande',
  annuler: 'Annuler la commande',
  aide: 'Problème, réclamation',
  question: 'Question sur Tovo',
  social: 'Rien à commander',
};
const OPTIONS = Object.entries(INTENTIONS).map(([value, label]) => ({ value, label }));
const nom = (cle: string | null) => (cle ? INTENTIONS[cle] ?? (cle === 'ambigu' ? 'Ambiguë' : cle === 'tuiles' ? 'Hésite (tuiles)' : cle) : '—');

interface Cas {
  id: string;
  texte: string;
  avant: string | null;
  attendu: string;
  origine: string;
  etiqueteur: string | null;
  juge: string | null;
  cerveau: string | null;
  note: string | null;
}

type Reponse = 'intention' | 'tuiles' | 'erronee';
interface Decision {
  reponse: Reponse;
  intention: string;
  tuiles: string[];
  commentaire: string;
}

interface Rapport {
  passage?: string;
  reels?: { recoltees: number };
  synthetiques?: { ecrites: number; gardees: number };
  examen?: { phrases: number; justesse: number | null; actions_couteuses_a_tort: number; ambigues?: { phrases: number; doutes: number } } | null;
}

/** Les avis connus d'une phrase, sans doublon, pour pré-cocher les tuiles. */
function propositions(c: Cas): string[] {
  return [...new Set([c.etiqueteur, c.juge, c.cerveau].filter((x): x is string => !!x && x in INTENTIONS))];
}

function decisionParDefaut(c: Cas): Decision {
  return { reponse: 'intention', intention: c.juge && c.juge in INTENTIONS ? c.juge : c.attendu, tuiles: propositions(c), commentaire: '' };
}

// ── Réglages ────────────────────────────────────────────────────────────
interface Reglages {
  banc_ia_actif: boolean;
  banc_ia_intervalle_min: number;
  banc_ia_phrases: number;
  banc_ia_examen_min?: number;
}

const ReglagesBoucle = () => {
  const { open } = useNotification();
  const [r, setR] = useState<Reglages | null>(null);
  const [enCours, setEnCours] = useState(false);

  useEffect(() => {
    void (async () => {
      let lecture = await supabaseClient.from('platform_settings')
        .select('banc_ia_actif, banc_ia_intervalle_min, banc_ia_phrases, banc_ia_examen_min').limit(1).maybeSingle();
      if (lecture.error) {
        lecture = await supabaseClient.from('platform_settings')
          .select('banc_ia_actif, banc_ia_intervalle_min, banc_ia_phrases').limit(1).maybeSingle() as typeof lecture;
      }
      setR((lecture.data as Reglages | null) ?? null);
    })();
  }, []);

  if (!r) return null;
  const enregistrer = async () => {
    setEnCours(true);
    const { error } = await supabaseClient.from('platform_settings').update(r).eq('id', true);
    setEnCours(false);
    open?.(error
      ? { type: 'error', message: 'Réglages non enregistrés', description: error.message }
      : { type: 'success', message: 'Réglages enregistrés', description: 'Le serveur les applique dans la minute.' });
  };
  const champ = (titre: string, element: React.ReactNode) => (
    <Space direction="vertical" size={4}>
      <Typography.Text type="secondary">{titre}</Typography.Text>
      {element}
    </Space>
  );
  return (
    <Card size="small" title="Réglages de l’apprentissage" style={{ marginBottom: 20 }}>
      <Space size={32} wrap align="end">
        {champ('En marche', <Switch checked={r.banc_ia_actif} onChange={(v) => setR({ ...r, banc_ia_actif: v })} />)}
        {champ('Un passage toutes les', (
          <InputNumber min={10} max={1440} value={r.banc_ia_intervalle_min} addonAfter="minutes"
            onChange={(v) => setR({ ...r, banc_ia_intervalle_min: Number(v ?? 10) })} />
        ))}
        {champ('Phrases imaginées par passage', (
          <InputNumber min={0} max={200} value={r.banc_ia_phrases}
            onChange={(v) => setR({ ...r, banc_ia_phrases: Number(v ?? 20) })} />
        ))}
        {r.banc_ia_examen_min !== undefined && champ('Examen complet toutes les', (
          <InputNumber min={10} max={1440} value={r.banc_ia_examen_min} addonAfter="minutes"
            onChange={(v) => setR({ ...r, banc_ia_examen_min: Number(v ?? 60) })} />
        ))}
        <Button type="primary" loading={enCours} onClick={() => void enregistrer()}>Enregistrer</Button>
      </Space>
    </Card>
  );
};

// ── Une phrase à trancher ───────────────────────────────────────────────
const CartePhrase = ({ c, onFini }: { c: Cas; onFini: (id: string) => void }) => {
  const { open } = useNotification();
  const [d, setD] = useState<Decision>(() => decisionParDefaut(c));
  const [enCours, setEnCours] = useState(false);
  const imaginee = c.origine === 'synthetique';

  const trancher = async (statut: 'valide' | 'rejete') => {
    setEnCours(true);
    const { data: session } = await supabaseClient.auth.getUser();
    const { error } = await supabaseClient.from('banc_cas').update({
      statut,
      reponse: d.reponse,
      attendu: d.reponse === 'intention' ? d.intention : d.tuiles[0] ?? c.attendu,
      tuiles: d.reponse === 'tuiles' ? d.tuiles : null,
      commentaire: d.commentaire.trim() || null,
      tranche_le: new Date().toISOString(),
      tranche_par: session.user?.id ?? null,
    }).eq('id', c.id);
    setEnCours(false);
    if (error) {
      open?.({ type: 'error', message: 'Impossible d’enregistrer', description: `${error.message} — la migration 0066 est-elle appliquée ?` });
      return;
    }
    onFini(c.id);
  };

  return (
    <Card style={{ marginBottom: 14 }} styles={{ body: { padding: 18 } }}>
      <Space direction="vertical" size={12} style={{ width: '100%' }}>
        <div>
          <Tag>{imaginee ? 'Phrase imaginée' : 'Phrase tapée dans l’app'}</Tag>
          <Typography.Title level={4} style={{ margin: '8px 0 0' }}>« {c.texte} »</Typography.Title>
          {c.avant && <Typography.Text type="secondary">En réponse à Tovo : « {c.avant} »</Typography.Text>}
        </div>

        <Space wrap size={[8, 8]}>
          <Typography.Text type="secondary">Les avis :</Typography.Text>
          {imaginee && <Tag color="purple">Gemini (qui l’a écrite) : {nom(c.etiqueteur)}</Tag>}
          <Tag color="blue">GPT‑5.5 (le juge) : {nom(c.juge)}</Tag>
          <Tag color="orange">L’assistant : {nom(c.cerveau)}</Tag>
        </Space>
        {c.note && <Typography.Text type="secondary" italic>{c.note}</Typography.Text>}

        <Radio.Group value={d.reponse} onChange={(e) => setD({ ...d, reponse: e.target.value as Reponse })}>
          <Radio.Button value="intention">Elle veut dire…</Radio.Button>
          <Radio.Button value="tuiles">Ambiguë : proposer des tuiles</Radio.Button>
          <Radio.Button value="erronee">Phrase erronée</Radio.Button>
        </Radio.Group>

        {d.reponse === 'intention' && (
          <Select style={{ width: 300 }} value={d.intention} options={OPTIONS}
            onChange={(v) => setD({ ...d, intention: v })} />
        )}
        {d.reponse === 'tuiles' && (
          <Space direction="vertical" size={4}>
            <Typography.Text type="secondary">Les choix que l’assistant doit proposer :</Typography.Text>
            <Select mode="multiple" style={{ minWidth: 420 }} value={d.tuiles} options={OPTIONS}
              onChange={(v) => setD({ ...d, tuiles: v })} />
          </Space>
        )}
        {d.reponse === 'erronee' && (
          <Typography.Text type="secondary">
            Incompréhensible ou mal transcrite : l’assistant ne doit rien faire à sa place, seulement demander de reformuler.
          </Typography.Text>
        )}

        <Input.TextArea
          value={d.commentaire}
          onChange={(e) => setD({ ...d, commentaire: e.target.value })}
          placeholder="Avec vos mots : ce que la phrase veut dire (facultatif — ex. « réclamation, mauvais plat reçu »)"
          autoSize={{ minRows: 1, maxRows: 3 }}
          maxLength={500}
        />

        <Space>
          <Button type="primary" loading={enCours} onClick={() => void trancher('valide')}>Valider</Button>
          <Button disabled={enCours} onClick={() => void trancher('rejete')}>Écarter</Button>
        </Space>
      </Space>
    </Card>
  );
};

// ── La page ─────────────────────────────────────────────────────────────
export const QualiteIa = () => {
  const [cas, setCas] = useState<Cas[]>([]);
  const [rapport, setRapport] = useState<Rapport | null>(null);
  const [total, setTotal] = useState<number | null>(null);
  const [chargement, setChargement] = useState(true);
  const [erreur, setErreur] = useState<string | null>(null);

  const charger = useCallback(async () => {
    setChargement(true);
    const [aValider, dernier, compte] = await Promise.all([
      supabaseClient.from('banc_cas').select('id, texte, avant, attendu, origine, etiqueteur, juge, cerveau, note')
        .eq('statut', 'a_valider').order('cree_le', { ascending: false }).limit(100),
      supabaseClient.from('banc_passages').select('rapport').order('cree_le', { ascending: false }).limit(20),
      supabaseClient.from('banc_cas').select('id', { count: 'exact', head: true }).eq('statut', 'valide'),
    ]);
    if (aValider.error) {
      setErreur(aValider.error.message);
    } else {
      setErreur(null);
      setCas((aValider.data ?? []) as Cas[]);
      // Le dernier passage qui a fait passer l'examen.
      const rapports = ((dernier.data ?? []) as Array<{ rapport: Rapport }>).map((l) => l.rapport);
      setRapport(rapports.find((x) => x.examen) ?? rapports[0] ?? null);
      setTotal(compte.count ?? null);
    }
    setChargement(false);
  }, []);

  useEffect(() => {
    void charger();
  }, [charger]);

  const ex = rapport?.examen;
  return (
    <List title="Qualité de l’IA" headerButtons={<Button onClick={() => void charger()}>Actualiser</Button>}>
      <Typography.Paragraph style={{ maxWidth: 860, fontSize: 15 }}>
        L’assistant de Tovo passe un <b>examen</b> en continu. À chaque passage, le serveur relit les phrases tapées dans
        l’app et fait écrire des phrases de clients imaginés par deux IA puissantes, <b>Gemini</b> et <b>GPT</b>, qui se
        contrôlent l’une l’autre. Quand leurs avis divergent, la phrase arrive ci-dessous. Dites ce qu’elle veut dire,
        si elle est <b>ambiguë</b> (l’assistant devra proposer des choix) ou <b>erronée</b>, puis <b>Valider</b>.
      </Typography.Paragraph>

      <ReglagesBoucle />

      {erreur && (
        <Alert type="error" showIcon style={{ marginBottom: 16 }}
          message="Lecture impossible" description={`${erreur} — la migration 0065 est-elle appliquée ?`} />
      )}

      <Row gutter={16} style={{ marginBottom: 12 }}>
        <Col xs={12} lg={6}><Card><Statistic title="Justesse de l’assistant" value={ex?.justesse ?? '—'} suffix={ex?.justesse != null ? '%' : ''} /></Card></Col>
        <Col xs={12} lg={6}><Card><Statistic title="Actions coûteuses à tort" value={ex?.actions_couteuses_a_tort ?? '—'} /></Card></Col>
        <Col xs={12} lg={6}><Card><Statistic title="Phrases dans l’examen" value={total ?? '—'} /></Card></Col>
        <Col xs={12} lg={6}><Card><Statistic title="À trancher" value={cas.length} /></Card></Col>
      </Row>
      {rapport?.passage && (
        <Typography.Paragraph type="secondary">
          Dernier examen : {new Date(rapport.passage).toLocaleString('fr-FR')}
          {ex?.ambigues && ex.ambigues.phrases > 0 && ` — phrases ambiguës : l’assistant a hésité sur ${ex.ambigues.doutes} sur ${ex.ambigues.phrases}`}.
        </Typography.Paragraph>
      )}

      <Typography.Title level={4} style={{ marginTop: 12 }}>À trancher</Typography.Title>
      {!chargement && cas.length === 0 && <Empty description="Rien à trancher pour le moment." />}
      {cas.map((c) => (
        <CartePhrase key={c.id} c={c} onFini={(id) => setCas((l) => l.filter((x) => x.id !== id))} />
      ))}
    </List>
  );
};

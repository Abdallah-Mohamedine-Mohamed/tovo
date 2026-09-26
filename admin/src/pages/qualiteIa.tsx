import { useCallback, useEffect, useState } from 'react';
import { List } from '@refinedev/antd';
import { useNotification } from '@refinedev/core';
import { Alert, Button, Card, Col, InputNumber, Row, Select, Space, Statistic, Switch, Table, Tag, Typography } from 'antd';
import { supabaseClient } from '../supabaseClient';

/**
 * Qualité de l'IA — les phrases où le juge (un modèle fort) et le cerveau ne
 * sont pas d'accord. Un humain tranche : c'est ce qui empêche l'IA de graver
 * ses propres erreurs dans l'examen.
 *
 * Écrites par la boucle du banc (lancée par le serveur, toutes les 30 minutes
 * par défaut — réglable en haut de la page). « Valider » met la phrase dans l'examen du cerveau avec
 * l'intention choisie ; « Écarter » la retire. Accès : admins (RLS).
 */

const INTENTIONS: Record<string, string> = {
  recherche: 'Cherche un produit',
  envie: 'Envie, sans produit précis',
  boutique: 'Veut une boutique',
  livreur: 'Veut un livreur',
  colis: 'Envoie un colis',
  designe: 'Désigne ce qu’il voit',
  habitude: 'Refaire une commande',
  suivi: 'Suivi de commande',
  annuler: 'Annuler la commande',
  social: 'Rien à commander',
};

interface Cas {
  id: string;
  texte: string;
  avant: string | null;
  attendu: string;
  origine: string;
  juge: string | null;
  cerveau: string | null;
  note: string | null;
  cree_le: string;
}

interface Rapport {
  passage?: string;
  reels?: { recoltees: number; dans_examen: number; a_valider: number };
  synthetiques?: { ecrites: number; gardees: number; ecartees: number };
  examen?: { phrases: number; justesse: number | null; actions_couteuses_a_tort: number };
}

const etiquette = (cle: string | null) => (cle ? INTENTIONS[cle] ?? cle : '—');

interface Reglages {
  banc_ia_actif: boolean;
  banc_ia_intervalle_min: number;
  banc_ia_phrases: number;
}

/**
 * Les réglages de la boucle : le serveur les relit chaque minute.
 */
const ReglagesBoucle = () => {
  const { open } = useNotification();
  const [r, setR] = useState<Reglages | null>(null);
  const [enCours, setEnCours] = useState(false);

  useEffect(() => {
    void supabaseClient.from('platform_settings')
      .select('banc_ia_actif, banc_ia_intervalle_min, banc_ia_phrases').limit(1).maybeSingle()
      .then(({ data }) => setR((data as Reglages | null) ?? null));
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
  return (
    <Card size="small" title="Réglages de l’apprentissage" style={{ marginBottom: 20 }}>
      <Space size={32} wrap align="end">
        <Space direction="vertical" size={4}>
          <Typography.Text type="secondary">En marche</Typography.Text>
          <Switch checked={r.banc_ia_actif} onChange={(v) => setR({ ...r, banc_ia_actif: v })} />
        </Space>
        <Space direction="vertical" size={4}>
          <Typography.Text type="secondary">Un passage toutes les</Typography.Text>
          <InputNumber min={10} max={1440} value={r.banc_ia_intervalle_min} addonAfter="minutes"
            onChange={(v) => setR({ ...r, banc_ia_intervalle_min: Number(v ?? 30) })} />
        </Space>
        <Space direction="vertical" size={4}>
          <Typography.Text type="secondary">Phrases de clients imaginés par passage</Typography.Text>
          <InputNumber min={0} max={200} value={r.banc_ia_phrases}
            onChange={(v) => setR({ ...r, banc_ia_phrases: Number(v ?? 30) })} />
        </Space>
        <Button type="primary" loading={enCours} onClick={() => void enregistrer()}>Enregistrer</Button>
      </Space>
    </Card>
  );
};

export const QualiteIa = () => {
  const { open } = useNotification();
  const [cas, setCas] = useState<Cas[]>([]);
  const [choix, setChoix] = useState<Record<string, string>>({});
  const [rapport, setRapport] = useState<Rapport | null>(null);
  const [total, setTotal] = useState<number | null>(null);
  const [chargement, setChargement] = useState(true);
  const [erreur, setErreur] = useState<string | null>(null);

  const charger = useCallback(async () => {
    setChargement(true);
    const [aValider, dernier, compte] = await Promise.all([
      supabaseClient.from('banc_cas').select('id, texte, avant, attendu, origine, juge, cerveau, note, cree_le')
        .eq('statut', 'a_valider').order('cree_le', { ascending: false }).limit(200),
      supabaseClient.from('banc_passages').select('rapport').order('cree_le', { ascending: false }).limit(1),
      supabaseClient.from('banc_cas').select('id', { count: 'exact', head: true }).eq('statut', 'valide'),
    ]);
    if (aValider.error) {
      setErreur(aValider.error.message);
    } else {
      setErreur(null);
      setCas((aValider.data ?? []) as Cas[]);
      setRapport(((dernier.data?.[0] as { rapport?: Rapport } | undefined)?.rapport) ?? null);
      setTotal(compte.count ?? null);
    }
    setChargement(false);
  }, []);

  useEffect(() => {
    void charger();
  }, [charger]);

  const trancher = async (c: Cas, statut: 'valide' | 'rejete') => {
    const { data: session } = await supabaseClient.auth.getUser();
    const { error } = await supabaseClient.from('banc_cas').update({
      statut,
      attendu: choix[c.id] ?? c.juge ?? c.attendu,
      tranche_le: new Date().toISOString(),
      tranche_par: session.user?.id ?? null,
    }).eq('id', c.id);
    if (error) {
      open?.({ type: 'error', message: 'Impossible d’enregistrer', description: error.message });
      return;
    }
    setCas((liste) => liste.filter((x) => x.id !== c.id));
  };

  const ex = rapport?.examen;
  return (
    <List title="Qualité de l’IA">
      <Typography.Paragraph style={{ maxWidth: 820, fontSize: 15 }}>
        L’assistant de Tovo passe un <b>examen</b> en continu. À chaque passage, le serveur relit les vraies phrases de
        vos clients, et fait écrire des phrases de clients imaginés par deux IA puissantes qui se contrôlent l’une
        l’autre. Quand un <b>juge</b> et l’<b>assistant</b> ne comprennent pas une vraie phrase de la même façon, elle
        arrive ci-dessous : choisissez ce qu’elle veut vraiment dire, puis <b>Valider</b>. Une phrase inutile ou
        incompréhensible : <b>Écarter</b>.
      </Typography.Paragraph>
      <ReglagesBoucle />
      {erreur && (
        <Alert type="error" showIcon style={{ marginBottom: 16 }}
          message="Lecture impossible" description={`${erreur} — la migration 0065 est-elle appliquée ?`} />
      )}
      <Row gutter={16} style={{ marginBottom: 20 }}>
        <Col span={6}><Card><Statistic title="Justesse du cerveau (dernier passage)" value={ex?.justesse ?? '—'} suffix={ex?.justesse != null ? '%' : ''} /></Card></Col>
        <Col span={6}><Card><Statistic title="Actions coûteuses à tort" value={ex?.actions_couteuses_a_tort ?? '—'} /></Card></Col>
        <Col span={6}><Card><Statistic title="Phrases dans l’examen" value={total ?? '—'} /></Card></Col>
        <Col span={6}><Card><Statistic title="À trancher" value={cas.length} /></Card></Col>
      </Row>
      {rapport?.passage && (
        <Typography.Paragraph type="secondary">
          Dernier passage : {new Date(rapport.passage).toLocaleString('fr-FR')} — {rapport.reels?.recoltees ?? 0} vraies phrases
          récoltées, {rapport.synthetiques?.gardees ?? 0} phrases écrites gardées sur {rapport.synthetiques?.ecrites ?? 0}.
        </Typography.Paragraph>
      )}
      <Table<Cas>
        rowKey="id"
        loading={chargement}
        dataSource={cas}
        pagination={{ pageSize: 20 }}
        columns={[
          {
            title: 'Phrase du client',
            render: (_, c) => (
              <Space direction="vertical" size={2}>
                <Typography.Text strong>{c.texte}</Typography.Text>
                {c.avant && <Typography.Text type="secondary">En réponse à : « {c.avant} »</Typography.Text>}
                {c.note && <Typography.Text type="warning">{c.note}</Typography.Text>}
              </Space>
            ),
          },
          { title: 'Le juge', width: 170, render: (_, c) => <Tag color="blue">{etiquette(c.juge)}</Tag> },
          { title: 'Le cerveau', width: 170, render: (_, c) => <Tag color="orange">{etiquette(c.cerveau)}</Tag> },
          {
            title: 'Ce que ça veut dire',
            width: 240,
            render: (_, c) => (
              <Select
                style={{ width: 220 }}
                value={choix[c.id] ?? c.juge ?? c.attendu}
                onChange={(v) => setChoix((x) => ({ ...x, [c.id]: v }))}
                options={Object.entries(INTENTIONS).map(([value, label]) => ({ value, label }))}
              />
            ),
          },
          {
            title: '',
            width: 200,
            render: (_, c) => (
              <Space>
                <Button type="primary" onClick={() => void trancher(c, 'valide')}>Valider</Button>
                <Button onClick={() => void trancher(c, 'rejete')}>Écarter</Button>
              </Space>
            ),
          },
        ]}
      />
    </List>
  );
};

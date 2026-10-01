import { useCallback, useEffect, useMemo, useState } from 'react';
import { List } from '@refinedev/antd';
import { Alert, Button, Segmented, Table, Tag, Typography } from 'antd';
import { supabaseClient } from '../supabaseClient';

/**
 * Boutiques demandées — celles que les clients réclament et qui ne sont pas
 * sur Tovo (« de la viande chez Tchos »). L'assistant leur propose d'y envoyer
 * un livreur ; chaque demande arrive ici. Les plus demandées d'abord : c'est
 * la liste de prospection, dans l'ordre.
 */

interface Demande {
  nom: string;
  nom_normalise: string;
  article: string | null;
  cree_le: string;
}

interface Ligne {
  cle: string;
  nom: string;
  demandes: number;
  derniere: string;
  articles: string[];
}

const PERIODES = { 7: '7 jours', 30: '30 jours', 90: '90 jours' } as const;

/** Les demandes regroupées par nom ; le nom affiché est l'écriture la plus fréquente. */
function regrouper(demandes: Demande[]): Ligne[] {
  const groupes = new Map<string, Demande[]>();
  for (const d of demandes) groupes.set(d.nom_normalise, [...(groupes.get(d.nom_normalise) ?? []), d]);
  const plusFrequent = (valeurs: string[]) => {
    const compte = new Map<string, number>();
    for (const v of valeurs) compte.set(v, (compte.get(v) ?? 0) + 1);
    return [...compte.entries()].sort((a, b) => b[1] - a[1]).map(([v]) => v);
  };
  return [...groupes.entries()].map(([cle, liste]) => ({
    cle,
    nom: plusFrequent(liste.map((d) => d.nom))[0] ?? cle,
    demandes: liste.length,
    derniere: liste.map((d) => d.cree_le).sort().at(-1)!,
    articles: plusFrequent(liste.map((d) => d.article?.trim()).filter((a): a is string => Boolean(a))).slice(0, 4),
  })).sort((a, b) => b.demandes - a.demandes || b.derniere.localeCompare(a.derniere));
}

export const BoutiquesDemandees = () => {
  const [jours, setJours] = useState<keyof typeof PERIODES>(30);
  const [demandes, setDemandes] = useState<Demande[]>([]);
  const [chargement, setChargement] = useState(true);
  const [erreur, setErreur] = useState<string | null>(null);

  const charger = useCallback(async () => {
    setChargement(true);
    const depuis = new Date(Date.now() - jours * 86_400_000).toISOString();
    const { data, error } = await supabaseClient.from('boutiques_demandees')
      .select('nom, nom_normalise, article, cree_le')
      .gte('cree_le', depuis)
      .order('cree_le', { ascending: false })
      .limit(5000);
    setErreur(error?.message ?? null);
    setDemandes((data ?? []) as Demande[]);
    setChargement(false);
  }, [jours]);

  useEffect(() => {
    void charger();
  }, [charger]);

  const lignes = useMemo(() => regrouper(demandes), [demandes]);

  return (
    <List title="Boutiques demandées" headerButtons={<Button onClick={() => void charger()}>Actualiser</Button>}>
      <Typography.Paragraph style={{ maxWidth: 820, fontSize: 15 }}>
        Les commerces que les clients ont réclamés et qui ne sont <b>pas sur Tovo</b>. L’assistant leur a proposé
        d’y envoyer un livreur. Les plus demandés d’abord : ce sont les boutiques à faire venir sur Tovo en priorité.
      </Typography.Paragraph>
      <Segmented
        style={{ marginBottom: 16 }}
        value={jours}
        onChange={(v) => setJours(v as keyof typeof PERIODES)}
        options={Object.entries(PERIODES).map(([value, label]) => ({ value: Number(value), label }))}
      />
      {erreur && (
        <Alert type="error" showIcon style={{ marginBottom: 16 }}
          message="Lecture impossible" description={`${erreur} — la migration 0072 est-elle appliquée ?`} />
      )}
      <Table<Ligne>
        rowKey="cle"
        loading={chargement}
        dataSource={lignes}
        pagination={{ pageSize: 50, hideOnSinglePage: true }}
        locale={{ emptyText: 'Aucune boutique demandée sur cette période.' }}
        columns={[
          { title: 'Boutique', dataIndex: 'nom', render: (nom: string) => <b>{nom}</b> },
          { title: 'Demandes', dataIndex: 'demandes', width: 110, align: 'right' },
          {
            title: 'Ce que les clients voulaient',
            dataIndex: 'articles',
            render: (articles: string[]) => articles.length
              ? articles.map((a) => <Tag key={a}>{a}</Tag>)
              : <Typography.Text type="secondary">Non précisé</Typography.Text>,
          },
          {
            title: 'Dernière demande',
            dataIndex: 'derniere',
            width: 190,
            render: (d: string) => new Date(d).toLocaleString('fr-FR'),
          },
        ]}
      />
    </List>
  );
};

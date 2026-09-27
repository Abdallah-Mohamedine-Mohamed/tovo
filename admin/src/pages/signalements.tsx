import { useCallback, useEffect, useState } from 'react';
import { List } from '@refinedev/antd';
import { useNotification } from '@refinedev/core';
import { Alert, Button, Card, Empty, Input, Segmented, Space, Tag, Typography } from 'antd';
import { supabaseClient } from '../supabaseClient';

/**
 * Signalements — les problèmes que les clients ont dits à l'assistant :
 * mauvaise commande, article manquant, paiement Nita bloqué, monnaie,
 * livreur… Chaque fois que le cerveau comprend « aide », l'assistant répond
 * par des excuses, et le problème arrive ici pour qu'un humain le règle.
 */

interface Signalement {
  id: string;
  message: string;
  statut: 'ouvert' | 'en_cours' | 'regle';
  reponse_admin: string | null;
  order_id: string | null;
  user_id: string;
  cree_le: string;
}

const STATUTS = { ouvert: 'Ouvert', en_cours: 'En cours', regle: 'Réglé' } as const;
const COULEURS = { ouvert: 'red', en_cours: 'gold', regle: 'green' } as const;

const Carte = ({ s, onChange }: { s: Signalement; onChange: () => void }) => {
  const { open } = useNotification();
  const [note, setNote] = useState(s.reponse_admin ?? '');
  const [enCours, setEnCours] = useState(false);

  const changer = async (statut: Signalement['statut']) => {
    setEnCours(true);
    const { data: session } = await supabaseClient.auth.getUser();
    const { error } = await supabaseClient.from('signalements').update({
      statut,
      reponse_admin: note.trim() || null,
      ...(statut === 'regle' ? { regle_le: new Date().toISOString(), regle_par: session.user?.id ?? null } : {}),
    }).eq('id', s.id);
    setEnCours(false);
    if (error) {
      open?.({ type: 'error', message: 'Impossible d’enregistrer', description: error.message });
      return;
    }
    onChange();
  };

  return (
    <Card style={{ marginBottom: 12 }} styles={{ body: { padding: 18 } }}>
      <Space direction="vertical" size={10} style={{ width: '100%' }}>
        <Space wrap>
          <Tag color={COULEURS[s.statut]}>{STATUTS[s.statut]}</Tag>
          <Typography.Text type="secondary">{new Date(s.cree_le).toLocaleString('fr-FR')}</Typography.Text>
          {s.order_id && <Typography.Text type="secondary">Commande {s.order_id.slice(0, 8)}</Typography.Text>}
        </Space>
        <Typography.Title level={5} style={{ margin: 0 }}>« {s.message} »</Typography.Title>
        <Input.TextArea
          value={note}
          onChange={(e) => setNote(e.target.value)}
          placeholder="Ce qui a été fait (remboursement, nouveau livreur, appel au client…)"
          autoSize={{ minRows: 1, maxRows: 4 }}
          maxLength={2000}
        />
        <Space>
          {s.statut !== 'en_cours' && s.statut !== 'regle' && (
            <Button loading={enCours} onClick={() => void changer('en_cours')}>Je m’en occupe</Button>
          )}
          {s.statut !== 'regle' && (
            <Button type="primary" loading={enCours} onClick={() => void changer('regle')}>Réglé</Button>
          )}
          {s.statut === 'regle' && (
            <Button loading={enCours} onClick={() => void changer('ouvert')}>Rouvrir</Button>
          )}
        </Space>
      </Space>
    </Card>
  );
};

export const Signalements = () => {
  const [filtre, setFiltre] = useState<'a_traiter' | 'regle'>('a_traiter');
  const [liste, setListe] = useState<Signalement[]>([]);
  const [chargement, setChargement] = useState(true);
  const [erreur, setErreur] = useState<string | null>(null);

  const charger = useCallback(async () => {
    setChargement(true);
    const requete = supabaseClient.from('signalements')
      .select('id, message, statut, reponse_admin, order_id, user_id, cree_le')
      .order('cree_le', { ascending: false }).limit(200);
    const { data, error } = filtre === 'regle'
      ? await requete.eq('statut', 'regle')
      : await requete.in('statut', ['ouvert', 'en_cours']);
    setErreur(error?.message ?? null);
    setListe((data ?? []) as Signalement[]);
    setChargement(false);
  }, [filtre]);

  useEffect(() => {
    void charger();
  }, [charger]);

  return (
    <List title="Signalements" headerButtons={<Button onClick={() => void charger()}>Actualiser</Button>}>
      <Typography.Paragraph style={{ maxWidth: 820, fontSize: 15 }}>
        Les problèmes que les clients ont signalés à l’assistant : mauvaise commande, article manquant, paiement Nita,
        monnaie, livreur… L’assistant s’est excusé et a promis que l’équipe s’en occupe : c’est ici. Notez ce qui a été
        fait, puis <b>Réglé</b>.
      </Typography.Paragraph>
      <Segmented
        style={{ marginBottom: 16 }}
        value={filtre}
        onChange={(v) => setFiltre(v as typeof filtre)}
        options={[{ value: 'a_traiter', label: 'À traiter' }, { value: 'regle', label: 'Réglés' }]}
      />
      {erreur && (
        <Alert type="error" showIcon style={{ marginBottom: 16 }}
          message="Lecture impossible" description={`${erreur} — la migration 0067 est-elle appliquée ?`} />
      )}
      {!chargement && liste.length === 0 && !erreur && <Empty description="Aucun signalement ici." />}
      {liste.map((s) => <Carte key={s.id} s={s} onChange={() => void charger()} />)}
    </List>
  );
};

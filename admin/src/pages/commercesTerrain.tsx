import { useCallback, useEffect, useMemo, useState } from 'react';
import { List } from '@refinedev/antd';
import { Alert, Button, Image, Input, Modal, Segmented, Select, Space, Table, Tag, Typography, message } from 'antd';
import { supabaseClient } from '../supabaseClient';

/**
 * Commerces du terrain — relevés par les livreurs devant la devanture (photo,
 * point GPS, nom, type, téléphone ; migration 0076). L'équipe regarde la
 * photo, corrige le nom ou le type au besoin, et valide : le commerce apparaît
 * aux clients dans les 5 minutes, dans « commerces hors Tovo ». Les fiches
 * validées par livreur servent au calcul de leur prime.
 */

type Statut = 'propose' | 'valide' | 'refuse';

interface Fiche {
  id: string;
  nom: string;
  type: string;
  telephone: string | null;
  lat: number;
  lng: number;
  precision_m: number | null;
  repere: string | null;
  photo: string | null;
  statut: Statut;
  motif_refus: string | null;
  cree_le: string;
  propose_par: string;
  livreur: { full_name: string; phone: string | null } | null;
}

const TYPES: Record<string, string> = {
  supermarche: 'Supermarché', marche: 'Marché', boucherie: 'Boucherie', boulangerie: 'Boulangerie',
  beaute: 'Beauté', electronique: 'Électronique', vetements: 'Vêtements', quincaillerie: 'Quincaillerie',
  restaurant: 'Restaurant', grillades: 'Grillades', pharmacie: 'Pharmacie', boutique: 'Boutique',
};

const STATUTS: Record<Statut, string> = { propose: 'À vérifier', valide: 'Validés', refuse: 'Refusés' };

export const CommercesTerrain = () => {
  const [statut, setStatut] = useState<Statut>('propose');
  const [fiches, setFiches] = useState<Fiche[]>([]);
  const [photos, setPhotos] = useState<Record<string, string>>({});
  // Les corrections de l'équipe avant validation (nom, type).
  const [corrections, setCorrections] = useState<Record<string, { nom?: string; type?: string }>>({});
  const [refus, setRefus] = useState<{ fiche: Fiche; motif: string } | null>(null);
  const [validees30j, setValidees30j] = useState<Array<{ livreur: string; fiches: number }>>([]);
  const [chargement, setChargement] = useState(true);
  const [erreur, setErreur] = useState<string | null>(null);

  const charger = useCallback(async () => {
    setChargement(true);
    const { data, error } = await supabaseClient.from('commerces_terrain')
      .select('id, nom, type, telephone, lat, lng, precision_m, repere, photo, statut, motif_refus, cree_le, propose_par, livreur:profiles!commerces_terrain_propose_par_fkey(full_name, phone)')
      .eq('statut', statut)
      .order('cree_le', { ascending: statut === 'propose' })
      .limit(300);
    setErreur(error?.message ?? null);
    const liste = (data ?? []) as unknown as Fiche[];
    setFiches(liste);
    // Les photos : privées, lues par liens signés (1 h).
    const chemins = liste.map((f) => f.photo).filter((p): p is string => Boolean(p));
    if (chemins.length) {
      const { data: liens } = await supabaseClient.storage.from('terrain').createSignedUrls(chemins, 3600);
      setPhotos(Object.fromEntries((liens ?? []).filter((l) => l.signedUrl).map((l) => [l.path, l.signedUrl])));
    } else {
      setPhotos({});
    }
    // Les fiches validées par livreur, sur 30 jours : la base de la prime.
    const depuis = new Date(Date.now() - 30 * 86_400_000).toISOString();
    const { data: validees } = await supabaseClient.from('commerces_terrain')
      .select('propose_par, livreur:profiles!commerces_terrain_propose_par_fkey(full_name)')
      .eq('statut', 'valide').gte('verifie_le', depuis).limit(10_000);
    const compte = new Map<string, number>();
    for (const v of (validees ?? []) as unknown as Array<{ livreur: { full_name: string } | null }>) {
      const nom = v.livreur?.full_name || 'Livreur sans nom';
      compte.set(nom, (compte.get(nom) ?? 0) + 1);
    }
    setValidees30j([...compte.entries()].map(([livreur, n]) => ({ livreur, fiches: n })).sort((a, b) => b.fiches - a.fiches));
    setChargement(false);
  }, [statut]);

  useEffect(() => {
    void charger();
  }, [charger]);

  const decider = useCallback(async (fiche: Fiche, decision: 'valide' | 'refuse', motif?: string) => {
    const { data: moi } = await supabaseClient.auth.getUser();
    const correction = corrections[fiche.id] ?? {};
    const { error } = await supabaseClient.from('commerces_terrain').update({
      statut: decision,
      ...(decision === 'valide' ? { nom: (correction.nom ?? fiche.nom).trim(), type: correction.type ?? fiche.type } : {}),
      motif_refus: decision === 'refuse' ? (motif?.trim() || null) : null,
      verifie_le: new Date().toISOString(),
      verifie_par: moi.user?.id ?? null,
    }).eq('id', fiche.id);
    if (error) {
      void message.error(error.message);
      return;
    }
    void message.success(decision === 'valide'
      ? `« ${correction.nom ?? fiche.nom} » validé : visible par les clients d’ici 5 minutes.`
      : `« ${fiche.nom} » refusé.`);
    setFiches((liste) => liste.filter((f) => f.id !== fiche.id));
  }, [corrections]);

  const corriger = (id: string, champ: 'nom' | 'type', valeur: string) =>
    setCorrections((c) => ({ ...c, [id]: { ...c[id], [champ]: valeur } }));

  const colonnes = useMemo(() => [
    {
      title: 'Devanture',
      dataIndex: 'photo',
      width: 130,
      render: (photo: string | null) => (photo && photos[photo]
        ? <Image src={photos[photo]} width={110} height={82} style={{ objectFit: 'cover', borderRadius: 6 }} />
        : <Typography.Text type="secondary">Sans photo</Typography.Text>),
    },
    {
      title: 'Commerce',
      key: 'commerce',
      render: (_: unknown, f: Fiche) => (statut === 'propose'
        ? (
          <Space direction="vertical" size={6} style={{ width: '100%' }}>
            <Input value={corrections[f.id]?.nom ?? f.nom} onChange={(e) => corriger(f.id, 'nom', e.target.value)} />
            <Select
              style={{ width: 200 }}
              value={corrections[f.id]?.type ?? f.type}
              onChange={(v) => corriger(f.id, 'type', v)}
              options={Object.entries(TYPES).map(([value, label]) => ({ value, label }))}
            />
          </Space>
        )
        : (
          <Space direction="vertical" size={2}>
            <b>{f.nom}</b>
            <Tag>{TYPES[f.type] ?? f.type}</Tag>
            {f.motif_refus && <Typography.Text type="secondary">Motif : {f.motif_refus}</Typography.Text>}
          </Space>
        )),
    },
    {
      title: 'Téléphone',
      dataIndex: 'telephone',
      width: 120,
      render: (t: string | null) => t ?? <Typography.Text type="secondary">—</Typography.Text>,
    },
    {
      title: 'Où',
      key: 'ou',
      render: (_: unknown, f: Fiche) => (
        <Space direction="vertical" size={2}>
          {f.repere && <span>{f.repere}</span>}
          <a href={`https://www.google.com/maps?q=${f.lat},${f.lng}`} target="_blank" rel="noreferrer">Voir sur la carte</a>
          {f.precision_m != null && (
            <Typography.Text type={f.precision_m > 50 ? 'warning' : 'secondary'}>GPS à {f.precision_m} m près</Typography.Text>
          )}
        </Space>
      ),
    },
    {
      title: 'Livreur',
      key: 'livreur',
      width: 170,
      render: (_: unknown, f: Fiche) => (
        <Space direction="vertical" size={2}>
          <span>{f.livreur?.full_name || '—'}</span>
          <Typography.Text type="secondary">{new Date(f.cree_le).toLocaleString('fr-FR')}</Typography.Text>
        </Space>
      ),
    },
    ...(statut === 'propose' ? [{
      title: '',
      key: 'actions',
      width: 200,
      render: (_: unknown, f: Fiche) => (
        <Space>
          <Button type="primary" onClick={() => void decider(f, 'valide')}>Valider</Button>
          <Button danger onClick={() => setRefus({ fiche: f, motif: '' })}>Refuser</Button>
        </Space>
      ),
    }] : []),
  ], [statut, photos, corrections, decider]);

  return (
    <List title="Commerces du terrain" headerButtons={<Button onClick={() => void charger()}>Actualiser</Button>}>
      <Typography.Paragraph style={{ maxWidth: 820, fontSize: 15 }}>
        Les commerces relevés par les livreurs, devant la devanture. Regardez la photo, corrigez le nom ou le type si
        besoin, puis validez : le commerce apparaît aux clients d’ici 5 minutes, parmi les commerces hors Tovo.
      </Typography.Paragraph>
      {validees30j.length > 0 && (
        <Typography.Paragraph type="secondary">
          Validées sur 30 jours : {validees30j.map((v) => `${v.livreur} (${v.fiches})`).join(' · ')}
        </Typography.Paragraph>
      )}
      <Segmented
        style={{ marginBottom: 16 }}
        value={statut}
        onChange={(v) => setStatut(v as Statut)}
        options={Object.entries(STATUTS).map(([value, label]) => ({ value, label }))}
      />
      {erreur && (
        <Alert type="error" showIcon style={{ marginBottom: 16 }}
          message="Lecture impossible" description={`${erreur} — la migration 0076 est-elle appliquée ?`} />
      )}
      <Table<Fiche>
        rowKey="id"
        loading={chargement}
        dataSource={fiches}
        pagination={{ pageSize: 30, hideOnSinglePage: true }}
        locale={{ emptyText: statut === 'propose' ? 'Aucune fiche à vérifier.' : 'Aucune fiche.' }}
        columns={colonnes}
      />
      <Modal
        open={Boolean(refus)}
        title={refus ? `Refuser « ${refus.fiche.nom} »` : ''}
        okText="Refuser"
        okButtonProps={{ danger: true }}
        cancelText="Annuler"
        onCancel={() => setRefus(null)}
        onOk={async () => {
          if (refus) await decider(refus.fiche, 'refuse', refus.motif);
          setRefus(null);
        }}
      >
        <Input.TextArea
          rows={3}
          maxLength={200}
          placeholder="Motif (le livreur le verra) : photo floue, doublon, fermé…"
          value={refus?.motif ?? ''}
          onChange={(e) => setRefus((r) => (r ? { ...r, motif: e.target.value } : r))}
        />
      </Modal>
    </List>
  );
};

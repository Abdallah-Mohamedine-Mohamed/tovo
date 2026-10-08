import { useCallback, useEffect, useMemo, useState } from 'react';
import { List } from '@refinedev/antd';
import {
  Alert, Button, Form, Image, Input, InputNumber, Modal, Popconfirm, Segmented, Select, Space, Table, Tag, Typography, Upload, message,
} from 'antd';
import { supabaseClient } from '../supabaseClient';

/**
 * Commerces du terrain — relevés par les livreurs devant la devanture (photo,
 * point GPS, nom, catégories, téléphone ; migrations 0076 et 0078). L'équipe
 * regarde la photo, CORRIGE tout ce qu'il faut (nom, catégories, téléphone,
 * repère, position, photo), puis valide : le commerce apparaît aux clients
 * d'ici 5 minutes. L'onglet « Catégories » : celles que les livreurs ont
 * proposées, à valider, renommer, ou rattacher à un type de l'annuaire.
 */

type Statut = 'propose' | 'valide' | 'refuse';
type Vue = Statut | 'categories';

interface Fiche {
  id: string;
  nom: string;
  type: string | null;
  categories: string[] | null;
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

interface Categorie {
  slug: string;
  libelle: string;
  type: string | null;
  statut: 'propose' | 'valide';
  propose_par: string | null;
  cree_le: string;
}

/** Les types de l'annuaire : la recherche des clients s'appuie dessus. */
const TYPES: Record<string, string> = {
  supermarche: 'Supermarché', marche: 'Marché', boucherie: 'Boucherie', boulangerie: 'Boulangerie',
  beaute: 'Beauté', electronique: 'Électronique', vetements: 'Vêtements', quincaillerie: 'Quincaillerie',
  restaurant: 'Restaurant', grillades: 'Grillades', pharmacie: 'Pharmacie', boutique: 'Boutique',
};

const VUES: Record<Vue, string> = { propose: 'À vérifier', valide: 'Validés', refuse: 'Refusés', categories: 'Catégories' };

/** « Pièces auto » → « pieces-auto » (comme le serveur). */
function cleDeCategorie(libelle: string): string {
  return libelle.toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, ' ').trim().split(' ').filter(Boolean).join('-').slice(0, 60);
}

export const CommercesTerrain = () => {
  const [vue, setVue] = useState<Vue>('propose');
  const [fiches, setFiches] = useState<Fiche[]>([]);
  const [categories, setCategories] = useState<Categorie[]>([]);
  const [usages, setUsages] = useState<Record<string, number>>({});
  const [photos, setPhotos] = useState<Record<string, string>>({});
  const [edition, setEdition] = useState<Fiche | null>(null);
  const [refus, setRefus] = useState<{ fiche: Fiche; motif: string } | null>(null);
  const [validees30j, setValidees30j] = useState<Array<{ livreur: string; fiches: number }>>([]);
  const [chargement, setChargement] = useState(true);
  const [erreur, setErreur] = useState<string | null>(null);

  const libelles = useMemo(() => Object.fromEntries(categories.map((c) => [c.slug, c.libelle])), [categories]);

  const chargerCategories = useCallback(async () => {
    const { data, error } = await supabaseClient.from('categories_commerce')
      .select('slug, libelle, type, statut, propose_par, cree_le').order('libelle');
    if (error) setErreur(`${error.message} — la migration 0078 est-elle appliquée ?`);
    setCategories((data ?? []) as Categorie[]);
  }, []);

  const charger = useCallback(async () => {
    setChargement(true);
    await chargerCategories();
    if (vue === 'categories') {
      // Combien de fiches utilisent chaque catégorie (pour savoir laquelle supprimer).
      const { data } = await supabaseClient.from('commerces_terrain').select('categories').limit(20_000);
      const compte: Record<string, number> = {};
      for (const f of (data ?? []) as Array<{ categories: string[] | null }>) for (const c of f.categories ?? []) compte[c] = (compte[c] ?? 0) + 1;
      setUsages(compte);
      setChargement(false);
      return;
    }
    const { data, error } = await supabaseClient.from('commerces_terrain')
      .select('id, nom, type, categories, telephone, lat, lng, precision_m, repere, photo, statut, motif_refus, cree_le, propose_par, livreur:profiles!commerces_terrain_propose_par_fkey(full_name, phone)')
      .eq('statut', vue)
      .order('cree_le', { ascending: vue === 'propose' })
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
  }, [vue, chargerCategories]);

  useEffect(() => {
    void charger();
  }, [charger]);

  const decider = useCallback(async (fiche: Fiche, decision: 'valide' | 'refuse', motif?: string) => {
    const { data: moi } = await supabaseClient.auth.getUser();
    const { error } = await supabaseClient.from('commerces_terrain').update({
      statut: decision,
      motif_refus: decision === 'refuse' ? (motif?.trim() || null) : null,
      verifie_le: new Date().toISOString(),
      verifie_par: moi.user?.id ?? null,
    }).eq('id', fiche.id);
    if (error) {
      void message.error(error.message);
      return;
    }
    void message.success(decision === 'valide'
      ? `« ${fiche.nom} » validé : visible par les clients d’ici 5 minutes.`
      : `« ${fiche.nom} » refusé.`);
    setFiches((liste) => liste.filter((f) => f.id !== fiche.id));
  }, []);

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
      render: (_: unknown, f: Fiche) => (
        <Space direction="vertical" size={4}>
          <b>{f.nom}</b>
          <Space size={4} wrap>
            {(f.categories?.length ? f.categories : [f.type ?? 'boutique']).map((c) => (
              <Tag key={c} color={categories.find((k) => k.slug === c)?.statut === 'propose' ? 'gold' : undefined}>
                {libelles[c] ?? TYPES[c] ?? c}
              </Tag>
            ))}
          </Space>
          {f.motif_refus && <Typography.Text type="secondary">Motif : {f.motif_refus}</Typography.Text>}
        </Space>
      ),
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
    {
      title: '',
      key: 'actions',
      width: 270,
      render: (_: unknown, f: Fiche) => (
        <Space wrap>
          <Button onClick={() => setEdition(f)}>Modifier</Button>
          {vue === 'propose' && <Button type="primary" onClick={() => void decider(f, 'valide')}>Valider</Button>}
          {vue === 'propose' && <Button danger onClick={() => setRefus({ fiche: f, motif: '' })}>Refuser</Button>}
        </Space>
      ),
    },
  ], [vue, photos, categories, libelles, decider]);

  return (
    <List title="Commerces du terrain" headerButtons={<Button onClick={() => void charger()}>Actualiser</Button>}>
      <Typography.Paragraph style={{ maxWidth: 860, fontSize: 15 }}>
        Les commerces relevés par les livreurs, devant la devanture. Regardez la photo, corrigez ce qu’il faut
        avec « Modifier » (nom, catégories, téléphone, position, photo), puis validez : le commerce apparaît aux
        clients d’ici 5 minutes, parmi les commerces hors Tovo.
      </Typography.Paragraph>
      {vue !== 'categories' && validees30j.length > 0 && (
        <Typography.Paragraph type="secondary">
          Validées sur 30 jours : {validees30j.map((v) => `${v.livreur} (${v.fiches})`).join(' · ')}
        </Typography.Paragraph>
      )}
      <Segmented
        style={{ marginBottom: 16 }}
        value={vue}
        onChange={(v) => setVue(v as Vue)}
        options={Object.entries(VUES).map(([value, label]) => ({
          value,
          label: value === 'categories' && categories.some((c) => c.statut === 'propose')
            ? `${label} (${categories.filter((c) => c.statut === 'propose').length} à valider)`
            : label,
        }))}
      />
      {erreur && <Alert type="error" showIcon style={{ marginBottom: 16 }} message="Lecture impossible" description={erreur} />}
      {vue === 'categories'
        ? <OngletCategories categories={categories} usages={usages} chargement={chargement} recharger={charger} />
        : (
          <Table<Fiche>
            rowKey="id"
            loading={chargement}
            dataSource={fiches}
            pagination={{ pageSize: 30, hideOnSinglePage: true }}
            locale={{ emptyText: vue === 'propose' ? 'Aucune fiche à vérifier.' : 'Aucune fiche.' }}
            columns={colonnes}
          />
        )}
      {edition && (
        <EditionFiche
          fiche={edition}
          categories={categories}
          photo={edition.photo ? photos[edition.photo] : undefined}
          fermer={() => setEdition(null)}
          enregistre={async () => {
            setEdition(null);
            await charger();
          }}
          rechargerCategories={chargerCategories}
        />
      )}
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

/** Corriger tout ce que le livreur a envoyé, photo comprise. */
function EditionFiche({ fiche, categories, photo, fermer, enregistre, rechargerCategories }: {
  fiche: Fiche;
  categories: Categorie[];
  photo?: string;
  fermer: () => void;
  enregistre: () => Promise<void>;
  rechargerCategories: () => Promise<void>;
}) {
  const [form] = Form.useForm();
  const [nouvellePhoto, setNouvellePhoto] = useState<{ chemin: string; apercu: string } | null>(null);
  const [envoiPhoto, setEnvoiPhoto] = useState(false);
  const [enregistrement, setEnregistrement] = useState(false);
  const [saisie, setSaisie] = useState('');

  const creerCategorie = async (libelle: string) => {
    const propre = libelle.trim();
    const slug = cleDeCategorie(propre);
    if (slug.length < 2) return;
    // Créée par l'admin : validée d'emblée.
    const { error } = await supabaseClient.from('categories_commerce')
      .upsert({ slug, libelle: propre.charAt(0).toUpperCase() + propre.slice(1), statut: 'valide' }, { onConflict: 'slug', ignoreDuplicates: true });
    if (error) {
      void message.error(error.message);
      return;
    }
    await rechargerCategories();
    const actuelles: string[] = form.getFieldValue('categories') ?? [];
    if (!actuelles.includes(slug)) form.setFieldValue('categories', [...actuelles, slug]);
    setSaisie('');
  };

  const enregistrer = async () => {
    const v = await form.validateFields();
    setEnregistrement(true);
    const choisies: string[] = v.categories ?? [];
    // Le type de l'annuaire : celui de la première catégorie qui en a un.
    const type = choisies.map((c) => categories.find((k) => k.slug === c)?.type).find((t) => t) ?? 'boutique';
    const { error } = await supabaseClient.from('commerces_terrain').update({
      nom: String(v.nom).trim(),
      categories: choisies,
      type,
      telephone: v.telephone ? String(v.telephone).replace(/\D/g, '').replace(/^227(?=\d{8}$)/, '') || null : null,
      repere: v.repere?.trim() || null,
      lat: v.lat,
      lng: v.lng,
      ...(nouvellePhoto ? { photo: nouvellePhoto.chemin } : {}),
    }).eq('id', fiche.id);
    setEnregistrement(false);
    if (error) {
      void message.error(error.message);
      return;
    }
    void message.success(`« ${v.nom} » enregistré${fiche.statut === 'valide' ? ' : les clients le verront corrigé d’ici 5 minutes' : ''}.`);
    await enregistre();
  };

  return (
    <Modal
      open
      width={640}
      title={`Modifier « ${fiche.nom} »`}
      okText="Enregistrer"
      cancelText="Annuler"
      confirmLoading={enregistrement}
      onCancel={fermer}
      onOk={() => void enregistrer()}
    >
      <Form
        form={form}
        layout="vertical"
        initialValues={{
          nom: fiche.nom,
          categories: fiche.categories?.length ? fiche.categories : [fiche.type ?? 'boutique'],
          telephone: fiche.telephone ?? '',
          repere: fiche.repere ?? '',
          lat: fiche.lat,
          lng: fiche.lng,
        }}
      >
        <Form.Item label="Photo de la devanture">
          <Space align="start">
            {(nouvellePhoto?.apercu ?? photo)
              ? <Image src={nouvellePhoto?.apercu ?? photo} width={160} height={120} style={{ objectFit: 'cover', borderRadius: 8 }} />
              : <Typography.Text type="secondary">Sans photo</Typography.Text>}
            <Upload
              accept="image/jpeg,image/png,image/webp"
              showUploadList={false}
              customRequest={async ({ file, onSuccess, onError }) => {
                const f = file as File;
                setEnvoiPhoto(true);
                const extension = f.type === 'image/png' ? 'png' : f.type === 'image/webp' ? 'webp' : 'jpg';
                const chemin = `admin/${fiche.id}-${Date.now()}.${extension}`;
                const { error } = await supabaseClient.storage.from('terrain').upload(chemin, f, { contentType: f.type, upsert: false });
                setEnvoiPhoto(false);
                if (error) {
                  void message.error(`Photo non envoyée : ${error.message}`);
                  onError?.(error);
                  return;
                }
                setNouvellePhoto({ chemin, apercu: URL.createObjectURL(f) });
                onSuccess?.({});
              }}
            >
              <Button loading={envoiPhoto}>Remplacer la photo</Button>
            </Upload>
          </Space>
        </Form.Item>
        <Form.Item name="nom" label="Nom" rules={[{ required: true, min: 2, max: 120, message: 'Nom : 2 à 120 caractères' }]}>
          <Input />
        </Form.Item>
        <Form.Item name="categories" label="Catégories" rules={[{ required: true, type: 'array', min: 1, message: 'Au moins une catégorie' }]}>
          <Select
            mode="multiple"
            maxCount={5}
            optionFilterProp="label"
            options={categories.map((c) => ({ value: c.slug, label: c.statut === 'propose' ? `${c.libelle} (proposée)` : c.libelle }))}
            onSearch={setSaisie}
            searchValue={saisie}
            notFoundContent={saisie.trim().length >= 2
              ? <Button type="link" onClick={() => void creerCategorie(saisie)}>Créer la catégorie « {saisie.trim()} »</Button>
              : 'Aucune catégorie'}
          />
        </Form.Item>
        <Space style={{ width: '100%' }} size={12}>
          <Form.Item name="telephone" label="Téléphone" style={{ flex: 1 }}
            rules={[{ pattern: /^(\+?227)?[\s\d]{8,12}$/, message: 'Numéro à 8 chiffres' }]}>
            <Input placeholder="8 chiffres" />
          </Form.Item>
          <Form.Item name="repere" label="Repère" style={{ flex: 2 }}>
            <Input maxLength={200} placeholder="Face à la mosquée…" />
          </Form.Item>
        </Space>
        <Space size={12} align="end">
          <Form.Item name="lat" label="Latitude" rules={[{ required: true }]}>
            <InputNumber min={13.2} max={13.8} step={0.0001} style={{ width: 150 }} />
          </Form.Item>
          <Form.Item name="lng" label="Longitude" rules={[{ required: true }]}>
            <InputNumber min={1.8} max={2.4} step={0.0001} style={{ width: 150 }} />
          </Form.Item>
          <Form.Item>
            <a href={`https://www.google.com/maps?q=${fiche.lat},${fiche.lng}`} target="_blank" rel="noreferrer">Voir sur la carte</a>
          </Form.Item>
        </Space>
      </Form>
    </Modal>
  );
}

/** Les catégories : valider celles des livreurs, renommer, rattacher. */
function OngletCategories({ categories, usages, chargement, recharger }: {
  categories: Categorie[];
  usages: Record<string, number>;
  chargement: boolean;
  recharger: () => Promise<void>;
}) {
  const [libelles, setLibelles] = useState<Record<string, string>>({});
  const [types, setTypes] = useState<Record<string, string | null>>({});

  const enregistrer = async (c: Categorie, valider: boolean) => {
    const { error } = await supabaseClient.from('categories_commerce').update({
      libelle: (libelles[c.slug] ?? c.libelle).trim(),
      type: c.slug in types ? types[c.slug] : c.type,
      ...(valider ? { statut: 'valide' } : {}),
    }).eq('slug', c.slug);
    if (error) {
      void message.error(error.message);
      return;
    }
    void message.success(valider ? `« ${libelles[c.slug] ?? c.libelle} » validée.` : 'Enregistré.');
    await recharger();
  };

  const supprimer = async (c: Categorie) => {
    const { error } = await supabaseClient.from('categories_commerce').delete().eq('slug', c.slug);
    if (error) void message.error(error.message);
    else await recharger();
  };

  const tri = [...categories].sort((a, b) => (a.statut === b.statut ? a.libelle.localeCompare(b.libelle) : a.statut === 'propose' ? -1 : 1));

  return (
    <>
      <Typography.Paragraph type="secondary" style={{ maxWidth: 860 }}>
        Les catégories proposées par les livreurs apparaissent en premier. Rattachez-les à un type de l’annuaire :
        c’est ce qui permet aux clients de les trouver (« Friperie » → Vêtements). Une catégorie proposée reste
        utilisable par son livreur en attendant.
      </Typography.Paragraph>
      <Table<Categorie>
        rowKey="slug"
        loading={chargement}
        dataSource={tri}
        pagination={{ pageSize: 50, hideOnSinglePage: true }}
        columns={[
          {
            title: 'Catégorie',
            key: 'libelle',
            render: (_: unknown, c: Categorie) => (
              <Input
                value={libelles[c.slug] ?? c.libelle}
                maxLength={60}
                onChange={(e) => setLibelles((l) => ({ ...l, [c.slug]: e.target.value }))}
                style={{ maxWidth: 260 }}
              />
            ),
          },
          {
            title: 'Type de l’annuaire',
            key: 'type',
            width: 220,
            render: (_: unknown, c: Categorie) => (
              <Select
                allowClear
                placeholder="Aucun"
                style={{ width: 200 }}
                value={(c.slug in types ? types[c.slug] : c.type) ?? undefined}
                onChange={(v) => setTypes((t) => ({ ...t, [c.slug]: v ?? null }))}
                options={Object.entries(TYPES).map(([value, label]) => ({ value, label }))}
              />
            ),
          },
          {
            title: 'Statut',
            key: 'statut',
            width: 120,
            render: (_: unknown, c: Categorie) => (c.statut === 'propose' ? <Tag color="gold">À valider</Tag> : <Tag>Validée</Tag>),
          },
          {
            title: 'Fiches',
            key: 'usages',
            width: 80,
            align: 'right' as const,
            render: (_: unknown, c: Categorie) => usages[c.slug] ?? 0,
          },
          {
            title: '',
            key: 'actions',
            width: 280,
            render: (_: unknown, c: Categorie) => (
              <Space wrap>
                {c.statut === 'propose' && <Button type="primary" onClick={() => void enregistrer(c, true)}>Valider</Button>}
                <Button onClick={() => void enregistrer(c, false)}>Enregistrer</Button>
                {!usages[c.slug] && c.statut === 'propose' && (
                  <Popconfirm title="Supprimer cette proposition ?" okText="Supprimer" cancelText="Annuler" onConfirm={() => void supprimer(c)}>
                    <Button danger>Supprimer</Button>
                  </Popconfirm>
                )}
              </Space>
            ),
          },
        ]}
      />
    </>
  );
}

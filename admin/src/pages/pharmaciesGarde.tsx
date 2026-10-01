import { useCallback, useEffect, useState } from 'react';
import { List } from '@refinedev/antd';
import { useNotification } from '@refinedev/core';
import { Alert, Button, Card, Input, Space, Table, Tag, Typography, Upload } from 'antd';
import { supabaseClient } from '../supabaseClient';
import { appelerBackend } from '../backend';

/**
 * Pharmacies de garde — la liste de la semaine que Tovo montre aux clients
 * (les plus proches de leur position, avec le numéro et un livreur).
 *
 * Chaque samedi : déposer l'image publiée par Lahiyata (Facebook), vérifier
 * ce que Gemini a lu, corriger au besoin, publier. Environ deux minutes.
 */

type Precision = 'google' | 'pharmacie' | 'repere' | 'quartier' | 'manuelle' | null;

interface Ligne {
  commune: string;
  nom: string;
  localisation: string;
  telephone: string;
  lat: number | null;
  lng: number | null;
  precision: Precision;
  /** Le nom trouvé sur Google : pour repérer d'un coup d'œil une confusion. */
  nom_google?: string;
}

interface Lecture {
  debut: string;
  fin: string;
  pharmacies: Ligne[];
}

interface Semaine {
  debut: string;
  fin: string;
  nombre: number;
}

const PRECISIONS: Record<string, { texte: string; couleur: string }> = {
  google: { texte: 'Trouvée sur Google', couleur: 'green' },
  pharmacie: { texte: 'Pharmacie trouvée', couleur: 'green' },
  repere: { texte: 'Près du repère', couleur: 'blue' },
  quartier: { texte: 'Centre du quartier', couleur: 'gold' },
  manuelle: { texte: 'Position collée', couleur: 'green' },
  aucune: { texte: 'Introuvable', couleur: 'red' },
};

const jour = (iso: string) => new Date(iso).toLocaleDateString('fr-FR', { weekday: 'long', day: '2-digit', month: '2-digit' });

/** « 13.504031, 2.133979 » (copié depuis Google Maps) → { lat, lng }, ou null. */
function lirePosition(texte: string): { lat: number; lng: number } | null {
  const m = texte.match(/(-?\d{1,2}\.\d+)\s*[,;\s]\s*(-?\d{1,3}\.\d+)/);
  if (!m) return null;
  const lat = Number(m[1]);
  const lng = Number(m[2]);
  return lat > 13.2 && lat < 13.8 && lng > 1.8 && lng < 2.4 ? { lat, lng } : null;
}

const enBase64 = (fichier: File) => new Promise<string>((resoudre, rejeter) => {
  const lecteur = new FileReader();
  lecteur.onload = () => resoudre(String(lecteur.result).split(',')[1] ?? '');
  lecteur.onerror = () => rejeter(lecteur.error);
  lecteur.readAsDataURL(fichier);
});

export const PharmaciesGarde = () => {
  const { open } = useNotification();
  const [semaines, setSemaines] = useState<Semaine[]>([]);
  const [erreur, setErreur] = useState<string | null>(null);
  const [lecture, setLecture] = useState<Lecture | null>(null);
  const [enLecture, setEnLecture] = useState(false);
  const [enPublication, setEnPublication] = useState(false);

  const chargerSemaines = useCallback(async () => {
    const depuis = new Date(Date.now() - 7 * 86_400_000).toISOString();
    const { data, error } = await supabaseClient.from('pharmacies_garde')
      .select('debut, fin').gte('fin', depuis).order('debut', { ascending: false }).limit(1000);
    setErreur(error?.message ?? null);
    const parSemaine = new Map<string, Semaine>();
    for (const l of (data ?? []) as Array<{ debut: string; fin: string }>) {
      const s = parSemaine.get(l.debut) ?? { debut: l.debut, fin: l.fin, nombre: 0 };
      s.nombre += 1;
      parSemaine.set(l.debut, s);
    }
    setSemaines([...parSemaine.values()]);
  }, []);

  useEffect(() => {
    void chargerSemaines();
  }, [chargerSemaines]);

  const lireImage = async (fichier: File) => {
    setEnLecture(true);
    try {
      const mime = fichier.type || 'image/jpeg';
      const lu = await appelerBackend<Lecture>('POST', '/admin/pharmacies-garde/lire', { mime, data: await enBase64(fichier) });
      setLecture(lu);
    } catch (e) {
      open?.({ type: 'error', message: 'Lecture impossible', description: (e as Error).message });
    } finally {
      setEnLecture(false);
    }
    return false; // pas d'envoi automatique par Upload
  };

  const modifier = (index: number, champ: Partial<Ligne>) => {
    setLecture((l) => l && { ...l, pharmacies: l.pharmacies.map((p, i) => (i === index ? { ...p, ...champ } : p)) });
  };

  const publier = async () => {
    if (!lecture) return;
    setEnPublication(true);
    try {
      // Le nom Google sert à vérifier, il n'est pas enregistré.
      const r = await appelerBackend<{ publiees: number }>('POST', '/admin/pharmacies-garde', {
        ...lecture,
        pharmacies: lecture.pharmacies.map(({ nom_google: _nom, ...p }) => p),
      });
      open?.({ type: 'success', message: `${r.publiees} pharmacies de garde publiées`, description: 'Les clients les voient dès maintenant.' });
      setLecture(null);
      void chargerSemaines();
    } catch (e) {
      open?.({ type: 'error', message: 'Publication impossible', description: (e as Error).message });
    } finally {
      setEnPublication(false);
    }
  };

  const aVerifier = lecture?.pharmacies.filter((p) => p.precision === 'quartier' || p.precision === null).length ?? 0;

  return (
    <List title="Pharmacies de garde" headerButtons={<Button onClick={() => void chargerSemaines()}>Actualiser</Button>}>
      <Typography.Paragraph style={{ maxWidth: 820, fontSize: 15 }}>
        La liste que Tovo montre aux clients, les plus proches de leur position d’abord. <b>Chaque samedi</b> : déposez
        l’image de la semaine (celle que Lahiyata publie sur Facebook), vérifiez ce qui a été lu, puis <b>Publier</b>.
      </Typography.Paragraph>

      {erreur && (
        <Alert type="error" showIcon style={{ marginBottom: 16 }}
          message="Lecture impossible" description={`${erreur} — la migration 0074 est-elle appliquée ?`} />
      )}

      <Space wrap style={{ marginBottom: 20 }}>
        {semaines.length === 0 && !erreur && <Typography.Text type="secondary">Aucune semaine publiée.</Typography.Text>}
        {semaines.map((s) => {
          const enCours = new Date(s.debut) <= new Date() && new Date() < new Date(s.fin);
          return (
            <Tag key={s.debut} color={enCours ? 'green' : 'default'} style={{ padding: '4px 10px', fontSize: 13 }}>
              {enCours ? 'En cours' : new Date(s.debut) > new Date() ? 'À venir' : 'Passée'} · du {jour(s.debut)} au {jour(s.fin)} · {s.nombre} pharmacies
            </Tag>
          );
        })}
      </Space>

      {!lecture && (
        <Card>
          <Upload.Dragger accept="image/jpeg,image/png,image/webp" showUploadList={false} beforeUpload={lireImage} disabled={enLecture}>
            <Typography.Title level={5} style={{ margin: 0 }}>
              {enLecture ? 'Lecture de l’image… (environ 20 secondes)' : 'Déposez ici l’image des pharmacies de garde de la semaine'}
            </Typography.Title>
            <Typography.Text type="secondary">ou cliquez pour la choisir — JPEG ou PNG</Typography.Text>
          </Upload.Dragger>
        </Card>
      )}

      {lecture && (
        <Space direction="vertical" size={16} style={{ width: '100%' }}>
          <Space wrap>
            <span>Du</span>
            <Input id="garde-debut" type="date" value={lecture.debut} onChange={(e) => setLecture({ ...lecture, debut: e.target.value })} style={{ width: 170 }} />
            <span>au</span>
            <Input id="garde-fin" type="date" value={lecture.fin} onChange={(e) => setLecture({ ...lecture, fin: e.target.value })} style={{ width: 170 }} />
            <Typography.Text type="secondary">de 8 h à 8 h</Typography.Text>
          </Space>
          {aVerifier > 0 && (
            <Alert type="warning" showIcon
              message={`${aVerifier} pharmacie(s) placée(s) seulement au centre du quartier, ou introuvable(s).`}
              description="Facultatif : collez sa position exacte (« 13.5040, 2.1339 », copiée depuis Google Maps) dans la colonne Position." />
          )}
          <Table<Ligne>
            rowKey={(p) => `${p.commune}-${p.nom}`}
            dataSource={lecture.pharmacies}
            pagination={false}
            size="small"
            scroll={{ x: 900 }}
            columns={[
              { title: 'Commune', dataIndex: 'commune', width: 90 },
              {
                title: 'Pharmacie', dataIndex: 'nom', width: 180,
                render: (v: string, _p, i) => <Input value={v} onChange={(e) => modifier(i, { nom: e.target.value })} />,
              },
              {
                title: 'Localisation', dataIndex: 'localisation',
                render: (v: string, _p, i) => <Input value={v} onChange={(e) => modifier(i, { localisation: e.target.value })} />,
              },
              {
                title: 'Téléphone', dataIndex: 'telephone', width: 130,
                render: (v: string, _p, i) => (
                  <Input value={v} status={/^\d{8}$/.test(v.replace(/\D/g, '')) ? '' : 'error'}
                    onChange={(e) => modifier(i, { telephone: e.target.value })} />
                ),
              },
              {
                title: 'Position', width: 230,
                render: (_v, p, i) => {
                  const etat = PRECISIONS[p.precision ?? 'aucune']!;
                  return (
                    <Space direction="vertical" size={4} style={{ width: '100%' }}>
                      <Tag color={etat.couleur}>{etat.texte}</Tag>
                      {p.precision === 'google' && p.nom_google && (
                        <Typography.Text type="secondary" style={{ fontSize: 12 }}>« {p.nom_google} »</Typography.Text>
                      )}
                      <Input
                        placeholder="Coller « lat, lng »"
                        onChange={(e) => {
                          const pos = lirePosition(e.target.value);
                          if (pos) modifier(i, { ...pos, precision: 'manuelle' });
                        }}
                      />
                    </Space>
                  );
                },
              },
            ]}
          />
          <Space>
            <Button type="primary" size="large" loading={enPublication} onClick={() => void publier()}>
              Publier {lecture.pharmacies.length} pharmacies de garde
            </Button>
            <Button size="large" onClick={() => setLecture(null)}>Annuler</Button>
          </Space>
        </Space>
      )}
    </List>
  );
};

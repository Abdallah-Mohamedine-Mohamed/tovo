import { useCallback, useEffect, useState } from 'react';
import { useNotification } from '@refinedev/core';
import {
  Alert,
  Button,
  Descriptions,
  Divider,
  Drawer,
  Empty,
  Select,
  Space,
  Table,
  Tag,
  Timeline,
  Typography,
} from 'antd';
import { supabaseClient } from '../supabaseClient';

/**
 * La fiche complète d'une commande.
 *
 * Quand un client appelle pour se plaindre, une ligne de tableau ne suffit
 * pas : il faut son numéro, ce qu'il a commandé, depuis combien de temps il
 * attend, et qui devait le livrer. Tout est là, en un seul aller-retour.
 */

/**
 * Les neuf statuts internes, ramenés à quatre étapes lisibles.
 *
 * Les neuf existent pour de bonnes raisons : `ready` est ce qui rend une
 * course visible aux livreurs, `assigned` marque celui qui l'a prise,
 * `picked_up` qu'il a le repas en main. Le dispatch repose dessus.
 *
 * Mais personne n'a besoin de cette précision pour comprendre où en est une
 * commande. On la garde en base, on la cache à l'écran.
 */
export const ETAPES = [
  { cle: 'acceptee', libelle: 'Acceptée', statuts: ['pending', 'confirmed'] },
  { cle: 'preparation', libelle: 'En préparation', statuts: ['preparing', 'ready'] },
  { cle: 'route', libelle: 'Livreur en route', statuts: ['assigned', 'picked_up', 'delivering'] },
  { cle: 'livree', libelle: 'Livrée', statuts: ['delivered'] },
] as const;

export function etapeDe(statut: string): number {
  return ETAPES.findIndex((e) => (e.statuts as readonly string[]).includes(statut));
}

/** Le statut interne à viser pour atteindre l'étape suivante. */
export function statutSuivant(statut: string): string | null {
  const i = etapeDe(statut);
  if (i < 0 || i >= ETAPES.length - 1) return null;
  // Le PREMIER statut de l'étape d'après : passer « en préparation » veut
  // dire `preparing`, pas `ready`.
  return ETAPES[i + 1]?.statuts[0] ?? null;
}

const xof = (v: unknown) =>
  `${Number(v ?? 0).toLocaleString('fr-FR').replace(/ | /g, ' ')} F`;

const heure = (iso?: string | null) =>
  iso ? new Date(iso).toLocaleString('fr-FR', { dateStyle: 'short', timeStyle: 'short' }) : '—';

interface Livreur {
  driver_id: string;
  full_name: string;
  distance_m: number | null;
  courses_actives?: number | null;
}

export const FicheCommande = ({
  orderId,
  onFerme,
  onChange,
}: {
  orderId: string | null;
  onFerme: () => void;
  onChange: () => void;
}) => {
  const { open } = useNotification();
  const [fiche, setFiche] = useState<Record<string, any> | null>(null);
  const [livreurs, setLivreurs] = useState<Livreur[]>([]);
  const [charge, setCharge] = useState(false);
  const [occupe, setOccupe] = useState(false);

  const lire = useCallback(async () => {
    if (!orderId) return;
    setCharge(true);

    const { data, error } = await supabaseClient.rpc('admin_order_detail', {
      p_order_id: orderId,
    });
    setCharge(false);

    if (error) {
      open?.({ type: 'error', message: 'Commande illisible', description: error.message });
      return;
    }
    setFiche(data as Record<string, any> | null);
  }, [orderId, open]);

  useEffect(() => {
    if (orderId) {
      void lire();
      setLivreurs([]);
    } else {
      setFiche(null);
    }
  }, [orderId, lire]);

  const chargerLivreurs = async () => {
    if (!orderId) return;
    const { data, error } = await supabaseClient.rpc('admin_assignable_drivers', {
      p_order_id: orderId,
    });
    if (error) {
      open?.({ type: 'error', message: 'Livreurs indisponibles', description: error.message });
      return;
    }
    setLivreurs((data ?? []) as Livreur[]);
  };

  const assigner = async (driverId: string) => {
    if (!orderId) return;
    setOccupe(true);
    const { error } = await supabaseClient.rpc('admin_assign_driver', {
      p_order_id: orderId,
      p_driver_id: driverId,
    });
    setOccupe(false);

    if (error) {
      open?.({ type: 'error', message: 'Assignation refusée', description: error.message });
      return;
    }
    open?.({ type: 'success', message: 'Livreur assigné' });
    await lire();
    onChange();
  };

  const avancer = async (statut: string) => {
    if (!orderId) return;
    setOccupe(true);
    const { error } = await supabaseClient.rpc('advance_order_status', {
      p_order_id: orderId,
      p_status: statut,
      p_note: 'Modifié depuis l’administration',
    });
    setOccupe(false);

    if (error) {
      open?.({ type: 'error', message: 'Changement refusé', description: error.message });
      return;
    }
    await lire();
    onChange();
  };

  const statut = String(fiche?.status ?? '');
  const suivant = statutSuivant(statut);
  const etape = etapeDe(statut);
  const annulee = statut === 'cancelled';

  return (
    <Drawer
      title={fiche ? `Commande — ${fiche.merchant?.name ?? 'Coursier'}` : 'Commande'}
      open={orderId !== null}
      onClose={onFerme}
      width={560}
      loading={charge}
    >
      {!fiche ? (
        <Empty description="Rien à afficher" />
      ) : (
        <>
          {/* Le temps d'attente en premier : c'est ce qui dit s'il y a
              urgence, avant même de savoir ce qui a été commandé. */}
          <Alert
            type={annulee ? 'error' : Number(fiche.attente_min) > 30 && etape < 3 ? 'warning' : 'info'}
            showIcon
            message={
              annulee
                ? `Annulée — ${fiche.cancelled_reason ?? 'sans motif'}`
                : `${ETAPES[etape]?.libelle ?? statut} · depuis ${fiche.attente_min} min`
            }
          />

          {!annulee && (
            <Space style={{ marginTop: 16 }} wrap>
              {suivant && (
                <Button type="primary" loading={occupe} onClick={() => void avancer(suivant)}>
                  → {ETAPES[etape + 1]?.libelle ?? ""}
                </Button>
              )}
              <Button danger loading={occupe} onClick={() => void avancer('cancelled')}>
                Annuler la commande
              </Button>
            </Space>
          )}

          <Divider orientation="left" plain style={{ marginTop: 24 }}>
            Client
          </Divider>
          <Descriptions column={1} size="small">
            <Descriptions.Item label="Nom">{fiche.client?.name || '—'}</Descriptions.Item>
            <Descriptions.Item label="Téléphone">
              {fiche.client?.phone ? (
                <a href={`tel:+${String(fiche.client.phone).replace(/^\+/, '')}`}>
                  +{String(fiche.client.phone).replace(/^\+/, '')}
                </a>
              ) : (
                '—'
              )}
            </Descriptions.Item>
            <Descriptions.Item label="Livrer à">{fiche.dropoff?.hint || '—'}</Descriptions.Item>
            {fiche.pickup && (
              <Descriptions.Item label="Récupérer à">{fiche.pickup.hint}</Descriptions.Item>
            )}
            <Descriptions.Item label="Passée le">{heure(fiche.placed_at)}</Descriptions.Item>
            {fiche.delivered_at && (
              <Descriptions.Item label="Livrée le">{heure(fiche.delivered_at)}</Descriptions.Item>
            )}
            {fiche.note && <Descriptions.Item label="Note">{fiche.note}</Descriptions.Item>}
          </Descriptions>

          <Divider orientation="left" plain>
            Livreur
          </Divider>
          {fiche.driver ? (
            <Descriptions column={1} size="small">
              <Descriptions.Item label="A accepté">{fiche.driver.name}</Descriptions.Item>
              <Descriptions.Item label="Téléphone">
                <a href={`tel:+${String(fiche.driver.phone).replace(/^\+/, '')}`}>
                  +{String(fiche.driver.phone).replace(/^\+/, '')}
                </a>
              </Descriptions.Item>
            </Descriptions>
          ) : (
            <Space direction="vertical" style={{ width: '100%' }}>
              <Typography.Text type="secondary">Aucun livreur n’a pris cette course.</Typography.Text>
              <Space.Compact style={{ width: '100%' }}>
                <Select
                  style={{ width: '100%' }}
                  placeholder="Choisir un livreur"
                  onDropdownVisibleChange={(ouvert) => {
                    if (ouvert && livreurs.length === 0) void chargerLivreurs();
                  }}
                  onChange={(v) => void assigner(String(v))}
                  options={livreurs.map((d) => ({
                    value: d.driver_id,
                    label:
                      d.distance_m != null
                        ? `${d.full_name} — à ${Math.round(d.distance_m / 100) / 10} km`
                        : d.full_name,
                  }))}
                  notFoundContent="Aucun livreur disponible"
                />
              </Space.Compact>
            </Space>
          )}

          <Divider orientation="left" plain>
            Contenu
          </Divider>
          <Table
            dataSource={(fiche.items ?? []) as Record<string, unknown>[]}
            rowKey={(_, i) => String(i)}
            size="small"
            pagination={false}
            locale={{ emptyText: 'Course coursier — pas d’articles' }}
          >
            <Table.Column
              title="Article"
              render={(_, r: Record<string, unknown>) => (
                <>
                  <div>{String(r.name)}</div>
                  {r.options ? (
                    <Typography.Text type="secondary" style={{ fontSize: 12 }}>
                      {String(r.options)}
                    </Typography.Text>
                  ) : null}
                </>
              )}
            />
            <Table.Column dataIndex="quantity" title="Qté" width={60} align="center" />
            <Table.Column dataIndex="line_total" title="Total" render={xof} align="right" />
          </Table>

          <Divider orientation="left" plain>
            Argent
          </Divider>
          <Descriptions column={2} size="small">
            <Descriptions.Item label="Articles">{xof(fiche.items_total)}</Descriptions.Item>
            <Descriptions.Item label="Livraison">{xof(fiche.delivery_fee)}</Descriptions.Item>
            <Descriptions.Item label="Total">
              <strong>{xof(fiche.total)}</strong>
            </Descriptions.Item>
            <Descriptions.Item label="Paiement">
              {fiche.payment_method === 'cash' ? (
                'Espèces'
              ) : (
                <Space size={4}>
                  Nita
                  <Tag color={fiche.payment_status === 'paid' ? 'green' : 'gold'}>
                    {fiche.payment_status === 'paid' ? 'payé' : 'en attente'}
                  </Tag>
                </Space>
              )}
            </Descriptions.Item>
            <Descriptions.Item label="Commission">{xof(fiche.commission_amount)}</Descriptions.Item>
            <Descriptions.Item label="Dû boutique">{xof(fiche.merchant_payout)}</Descriptions.Item>
            <Descriptions.Item label="Dû livreur">{xof(fiche.driver_earning)}</Descriptions.Item>
            {fiche.payment_confirmed_by && (
              <Descriptions.Item label="Encaissé par">{fiche.payment_confirmed_by}</Descriptions.Item>
            )}
          </Descriptions>

          <Divider orientation="left" plain>
            Déroulé
          </Divider>
          {/* L'historique dit où le temps a été perdu : trente minutes entre
              « prête » et « livreur assigné » désigne un problème de
              dispatch, pas une cuisine lente. */}
          <Timeline
            items={((fiche.history ?? []) as Record<string, unknown>[]).map((h) => ({
              children: `${ETAPES[etapeDe(String(h.status))]?.libelle ?? String(h.status)} — ${heure(
                String(h.at),
              )}`,
            }))}
          />
        </>
      )}
    </Drawer>
  );
};

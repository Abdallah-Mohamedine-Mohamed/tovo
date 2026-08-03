import { useCustom, useInvalidate, useNotification } from '@refinedev/core';
import { List } from '@refinedev/antd';
import { Alert, Button, Modal, Space, Table, Tag, Typography } from 'antd';
import { useState } from 'react';
import { supabaseClient } from '../supabaseClient';

/**
 * Dispatch — la porte de sortie quand l'automatique n'a pas suffi.
 *
 * Le dispatch notifie les livreurs proches et le premier qui accepte gagne.
 * Ça couvre le cas normal, pas la nuit où deux livreurs sont en ligne, ni la
 * commande à l'autre bout de la ville que personne ne prend.
 *
 * Cet écran montre toutes les commandes actives, signale celles que plus
 * aucun livreur ne voit, et permet d'assigner à la main — après un coup de
 * téléphone.
 */

const xof = (v: unknown) =>
  `${Number(v ?? 0).toLocaleString('fr-FR').replace(/ | /g, ' ')} F`;

interface Commande {
  id: string;
  status: string;
  type: string;
  total: number;
  driver_earning: number;
  attente_min: number;
  dropoff_hint: string;
  merchant_name: string | null;
  driver_name: string | null;
  dispatchable: boolean;
}

interface Livreur {
  driver_id: string;
  full_name: string | null;
  phone: string | null;
  is_online: boolean;
  is_available: boolean;
  distance_m: number | null;
}

const LIBELLES: Record<string, string> = {
  pending: 'En attente',
  confirmed: 'Acceptée',
  preparing: 'En préparation',
  ready: 'Prête',
  assigned: 'Livreur assigné',
  picked_up: 'Récupérée',
  delivering: 'En livraison',
};

export const DispatchList = () => {
  const [commande, setCommande] = useState<Commande | null>(null);
  const [livreurs, setLivreurs] = useState<Livreur[]>([]);
  const [enCours, setEnCours] = useState(false);
  const { open } = useNotification();
  const invalider = useInvalidate();

  const { data, isLoading, refetch } = useCustom<Commande[]>({
    url: '',
    method: 'get',
    meta: { operation: 'admin_orders' },
    dataProviderName: 'default',
    queryOptions: {
      queryKey: ['admin_orders'],
      queryFn: async () => {
        const { data, error } = await supabaseClient.rpc('admin_orders', {
          p_bloquees_seulement: false,
        });
        if (error) throw error;
        return { data: (data ?? []) as Commande[] };
      },
      refetchInterval: 20_000,
    },
  });

  const commandes = data?.data ?? [];
  const bloquees = commandes.filter((c) => c.status === 'ready' && !c.dispatchable && !c.driver_name);

  const ouvrirAssignation = async (c: Commande) => {
    setCommande(c);
    const { data, error } = await supabaseClient.rpc('admin_assignable_drivers', {
      p_order_id: c.id,
    });
    if (error) {
      open?.({ type: 'error', message: 'Livreurs indisponibles', description: error.message });
      return;
    }
    setLivreurs((data ?? []) as Livreur[]);
  };

  const assigner = async (driverId: string) => {
    if (!commande) return;
    setEnCours(true);
    const { error } = await supabaseClient.rpc('admin_assign_driver', {
      p_order_id: commande.id,
      p_driver_id: driverId,
    });
    setEnCours(false);

    if (error) {
      open?.({ type: 'error', message: 'Assignation refusée', description: error.message });
      return;
    }

    open?.({ type: 'success', message: 'Livreur assigné' });
    setCommande(null);
    invalider({ resource: 'orders', invalidates: ['list'] });
    void refetch();
  };

  return (
    <List title="Dispatch">
      {bloquees.length > 0 && (
        <Alert
          type="warning"
          showIcon
          style={{ marginBottom: 16 }}
          message={`${bloquees.length} commande${bloquees.length > 1 ? 's' : ''} qu'aucun livreur ne voit plus`}
          description="Passé le délai réglé dans les paramètres, une commande sort du pool des livreurs pour ne pas bloquer les suivantes. Elle reste ici : assignez un livreur à la main, ou annulez-la."
        />
      )}

      <Table
        dataSource={commandes}
        loading={isLoading}
        rowKey="id"
        size="small"
        scroll={{ x: 1000 }}
        pagination={{ pageSize: 25 }}
        rowClassName={(r) => (r.status === 'ready' && !r.dispatchable ? 'ant-table-row-error' : '')}
      >
        <Table.Column
          dataIndex="attente_min"
          title="Attente"
          align="right"
          render={(v: number) => (
            <Typography.Text
              strong={v > 30}
              type={v > 60 ? 'danger' : v > 30 ? 'warning' : undefined}
            >
              {v} min
            </Typography.Text>
          )}
        />
        <Table.Column
          dataIndex="status"
          title="Statut"
          render={(v: string) => <Tag>{LIBELLES[v] ?? v}</Tag>}
        />
        <Table.Column
          dataIndex="type"
          title="Type"
          render={(v) => (v === 'courier' ? 'Coursier' : 'Livraison')}
        />
        <Table.Column dataIndex="merchant_name" title="Boutique" ellipsis />
        <Table.Column dataIndex="dropoff_hint" title="Livraison" ellipsis />
        <Table.Column dataIndex="total" title="Total" render={xof} align="right" />
        <Table.Column
          dataIndex="driver_earning"
          title="Pour le livreur"
          render={xof}
          align="right"
        />
        <Table.Column
          title="Livreur"
          render={(_, r: Commande) =>
            r.driver_name ? (
              <Tag color="cyan">{r.driver_name}</Tag>
            ) : r.dispatchable ? (
              <Tag color="blue">dans le pool</Tag>
            ) : (
              <Tag color="red">personne ne la voit</Tag>
            )
          }
        />
        <Table.Column
          title="Action"
          render={(_, r: Commande) => (
            <Button size="small" type="primary" onClick={() => ouvrirAssignation(r)}>
              {r.driver_name ? 'Changer de livreur' : 'Assigner'}
            </Button>
          )}
        />
      </Table>

      <Modal
        open={commande !== null}
        onCancel={() => setCommande(null)}
        footer={null}
        title="Assigner un livreur"
        width={640}
      >
        <Typography.Paragraph type="secondary" style={{ fontSize: 12 }}>
          Les livreurs libres et proches apparaissent en premier. Un livreur hors
          ligne peut être assigné — appelez-le d'abord. Si la course était déjà
          attribuée, l'ancien livreur redevient disponible.
        </Typography.Paragraph>

        <Table dataSource={livreurs} rowKey="driver_id" size="small" pagination={false}>
          <Table.Column dataIndex="full_name" title="Nom" render={(v) => v || '—'} />
          <Table.Column dataIndex="phone" title="Téléphone" render={(v) => v || '—'} />
          <Table.Column
            title="État"
            render={(_, r: Livreur) => (
              <Space size={4}>
                <Tag color={r.is_online ? 'green' : 'default'}>
                  {r.is_online ? 'en ligne' : 'hors ligne'}
                </Tag>
                <Tag color={r.is_available ? 'blue' : 'orange'}>
                  {r.is_available ? 'libre' : 'en course'}
                </Tag>
              </Space>
            )}
          />
          <Table.Column
            dataIndex="distance_m"
            title="Distance"
            align="right"
            render={(v: number | null) =>
              v === null ? '—' : v < 1000 ? `${v} m` : `${(v / 1000).toFixed(1)} km`
            }
          />
          <Table.Column
            title=""
            render={(_, r: Livreur) => (
              <Button
                size="small"
                type="primary"
                loading={enCours}
                onClick={() => assigner(r.driver_id)}
              >
                Assigner
              </Button>
            )}
          />
        </Table>
      </Modal>
    </List>
  );
};

import { List, useTable, DateField } from '@refinedev/antd';
import { Table, Tag, Typography } from 'antd';

/**
 * Suivi des commandes.
 *
 * L'écran que l'admin regarde en continu. Il ne sert pas à modifier une
 * commande — les transitions appartiennent au boutiquier et au livreur, et
 * le trigger en base les fait respecter — mais à voir ce qui bloque.
 */

const COULEURS: Record<string, string> = {
  pending: 'gold',
  confirmed: 'blue',
  preparing: 'blue',
  ready: 'orange',
  assigned: 'cyan',
  picked_up: 'cyan',
  delivering: 'geekblue',
  delivered: 'green',
  cancelled: 'red',
};

const LIBELLES: Record<string, string> = {
  pending: 'En attente',
  confirmed: 'Acceptée',
  preparing: 'En préparation',
  ready: 'Prête',
  assigned: 'Livreur assigné',
  picked_up: 'Récupérée',
  delivering: 'En livraison',
  delivered: 'Livrée',
  cancelled: 'Annulée',
};

/** Les montants sont des entiers XOF : ni décimale, ni conversion. */
const xof = (v: unknown) =>
  `${Number(v ?? 0).toLocaleString('fr-FR').replace(/ | /g, ' ')} F`;

export const OrderList = () => {
  const { tableProps } = useTable({
    resource: 'orders',
    sorters: { initial: [{ field: 'placed_at', order: 'desc' }] },
    filters: {
      initial: [{ field: 'status', operator: 'ne', value: 'delivered' }],
    },
    pagination: { pageSize: 25 },
  });

  return (
    <List title="Commandes">
      <Table {...tableProps} rowKey="id" size="small" scroll={{ x: 1100 }}>
        <Table.Column
          dataIndex="placed_at"
          title="Passée le"
          render={(v) => <DateField value={v} format="DD/MM HH:mm" />}
        />
        <Table.Column
          dataIndex="type"
          title="Type"
          render={(v) => (v === 'courier' ? 'Coursier' : 'Livraison')}
        />
        <Table.Column
          dataIndex="status"
          title="Statut"
          render={(v: string) => (
            <Tag color={COULEURS[v] ?? 'default'}>{LIBELLES[v] ?? v}</Tag>
          )}
        />
        <Table.Column dataIndex="dropoff_hint" title="Livraison" ellipsis />
        <Table.Column dataIndex="total" title="Total" render={xof} align="right" />
        <Table.Column
          dataIndex="commission_amount"
          title="Commission"
          render={xof}
          align="right"
        />
        <Table.Column
          dataIndex="merchant_payout"
          title="Dû boutique"
          render={xof}
          align="right"
        />
        <Table.Column
          dataIndex="driver_earning"
          title="Dû livreur"
          render={xof}
          align="right"
        />
        <Table.Column
          title="Marge"
          align="right"
          render={(_, r: Record<string, number>) => (
            // Marge = commission + frais de livraison − rémunération livreur.
            // La calculer ici plutôt qu'en base permet de la voir évoluer
            // sans migration ; elle n'est jamais facturée à personne.
            <Typography.Text strong>
              {xof(
                (r.commission_amount ?? 0) +
                  (r.delivery_fee ?? 0) -
                  (r.driver_earning ?? 0),
              )}
            </Typography.Text>
          )}
        />
        <Table.Column
          dataIndex="payment_method"
          title="Paiement"
          render={(v) => (v === 'cash' ? 'Espèces' : 'Mobile money')}
        />
      </Table>
    </List>
  );
};

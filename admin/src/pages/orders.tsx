import { useState } from 'react';
import { List, useTable, DateField } from '@refinedev/antd';
import { Button, Popconfirm, Space, Table, Tag, Tooltip, Typography } from 'antd';
import { useInvalidate, useNotification } from '@refinedev/core';
import { supabaseClient } from '../supabaseClient';

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

/**
 * Ce que dit l'état d'un paiement, et ce qu'il ne dit pas.
 *
 * « En attente » sur du mobile money ne signifie pas que le client n'a pas
 * payé : il a pu envoyer l'argent directement par Nita au lieu de régler
 * l'achat en ligne, auquel cas aucune API ne peut le voir. C'est tout
 * l'objet du bouton de confirmation.
 */
const PAIEMENT: Record<string, { couleur: string; libelle: string }> = {
  pending: { couleur: 'gold', libelle: 'En attente' },
  paid: { couleur: 'green', libelle: 'Payé' },
  failed: { couleur: 'red', libelle: 'Échec' },
  refunded: { couleur: 'purple', libelle: 'Remboursé' },
};

export const OrderList = () => {
  const { open } = useNotification();
  const invalider = useInvalidate();
  const [enCours, setEnCours] = useState<string | null>(null);

  /**
   * L'admin déclare avoir constaté le paiement.
   *
   * Le recours quand aucun livreur n'est encore assigné : un client appelle
   * pour dire qu'il a payé, et personne d'autre ne peut l'enregistrer. La
   * fonction en base trace qui l'a déclaré — il s'agit d'argent.
   */
  const confirmerPaiement = async (orderId: string) => {
    setEnCours(orderId);
    const { data, error } = await supabaseClient.rpc('confirm_payment_received', {
      p_order_id: orderId,
    });
    setEnCours(null);

    if (error) {
      open?.({
        type: 'error',
        message: 'Confirmation refusée',
        description: error.message,
      });
      return;
    }
    if (data !== true) {
      open?.({ type: 'error', message: 'Ce paiement était déjà réglé' });
      return;
    }

    open?.({ type: 'success', message: 'Encaissement enregistré à votre nom' });
    invalider({ resource: 'orders', invalidates: ['list'] });
  };

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
          title="Paiement"
          render={(_, r: Record<string, unknown>) => {
            const espece = r.payment_method === 'cash';
            const etat = PAIEMENT[String(r.payment_status)] ?? {
              couleur: 'default',
              libelle: String(r.payment_status ?? '—'),
            };

            // En espèces, le paiement se fait à la livraison : afficher un
            // état « en attente » y serait un faux signal permanent.
            if (espece) return <span>Espèces</span>;

            return (
              <Space size={4}>
                <span>Nita</span>
                <Tooltip
                  title={
                    r.payment_confirmed_by
                      ? 'Constaté par un livreur ou un admin'
                      : r.payment_status === 'paid'
                        ? 'Constaté automatiquement chez Nita'
                        : undefined
                  }
                >
                  <Tag color={etat.couleur}>{etat.libelle}</Tag>
                </Tooltip>
              </Space>
            );
          }}
        />
        <Table.Column
          title=""
          align="right"
          render={(_, r: Record<string, unknown>) => {
            const aConfirmer =
              r.payment_method === 'mobile_money' &&
              (r.payment_status === 'pending' || r.payment_status === 'failed');
            if (!aConfirmer) return null;

            return (
              <Popconfirm
                title="Le client a-t-il payé ?"
                description="Votre nom sera enregistré comme ayant constaté cet encaissement."
                okText="Oui, il a payé"
                cancelText="Annuler"
                onConfirm={() => confirmerPaiement(String(r.id))}
              >
                <Button size="small" loading={enCours === r.id}>
                  Marquer payé
                </Button>
              </Popconfirm>
            );
          }}
        />
      </Table>
    </List>
  );
};

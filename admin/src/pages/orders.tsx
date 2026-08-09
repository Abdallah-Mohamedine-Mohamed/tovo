import { useState } from 'react';
import { List, useTable, DateField } from '@refinedev/antd';
import { Button, Input, Popconfirm, Segmented, Space, Table, Tag, Tooltip, Typography } from 'antd';
import { useInvalidate, useNotification } from '@refinedev/core';
import { supabaseClient } from '../supabaseClient';
import { ETAPES, etapeDe, FicheCommande, statutSuivant } from './orderDetail';

/**
 * Suivi des commandes.
 *
 * L'écran que l'admin regarde en continu, et par lequel il DÉBLOQUE.
 *
 * Le parcours normal appartient au boutiquier et au livreur, et le trigger
 * `guard_status_transition` le fait respecter. Mais l'admin en est exempté :
 * quand une commande se bloque un vendredi soir — boutiquier injoignable,
 * livreur qui a coupé son app — quelqu'un doit pouvoir la dénouer sans
 * attendre lundi.
 *
 * L'écran propose donc l'étape SUIVANTE, pas une liste de neuf statuts :
 * c'est presque toujours ce qu'on cherche à faire.
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

/**
 * Ce que lit un humain, et non les neuf statuts internes.
 *
 * « Prête », « Récupérée », « En livraison » disent la même chose à qui
 * regarde un tableau : le livreur s'en occupe. La distinction sert au
 * dispatch, pas à l'œil.
 */
function libelleEtape(statut: string): string {
  if (statut === 'cancelled') return 'Annulée';
  return ETAPES[etapeDe(statut)]?.libelle ?? statut;
}

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

/**
 * Le parcours normal d'une commande.
 *
 * Sert à proposer l'étape SUIVANTE plutôt qu'une liste de neuf statuts :
 * l'admin cherche presque toujours à débloquer, pas à choisir librement.
 */
export const OrderList = () => {
  const { open } = useNotification();
  const invalider = useInvalidate();
  const [enCours, setEnCours] = useState<string | null>(null);
  const [fiche, setFiche] = useState<string | null>(null);

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

  const { tableProps, setFilters } = useTable({
    resource: 'orders',
    sorters: { initial: [{ field: 'placed_at', order: 'desc' }] },
    filters: {
      initial: [{ field: 'status', operator: 'ne', value: 'delivered' }],
    },
    pagination: { pageSize: 25 },
  });

  /**
   * Fait avancer une commande, d'autorité.
   *
   * L'admin est exempté de `guard_status_transition` : il peut ramener une
   * commande à n'importe quel état. C'est voulu — quand une commande se
   * bloque un vendredi soir, quelqu'un doit pouvoir la dénouer sans attendre
   * que le boutiquier rouvre son application.
   */
  const avancer = async (orderId: string, statut: string) => {
    setEnCours(orderId);
    const { error } = await supabaseClient.rpc('advance_order_status', {
      p_order_id: orderId,
      p_status: statut,
      p_note: 'Modifié depuis l’administration',
    });
    setEnCours(null);

    if (error) {
      open?.({ type: 'error', message: 'Changement refusé', description: error.message });
      return;
    }
    open?.({ type: 'success', message: `Commande passée à « ${libelleEtape(statut)} »` });
    invalider({ resource: 'orders', invalidates: ['list'] });
  };

  /** Recherche sur le repère de livraison — ce que l'admin a sous les yeux. */
  const chercher = (texte: string) => {
    setFilters(
      texte.trim()
        ? [{ field: 'dropoff_hint', operator: 'contains', value: texte.trim() }]
        : [],
      'replace',
    );
  };

  const filtrerStatut = (valeur: string) => {
    setFilters(
      valeur === 'en_cours'
        ? [{ field: 'status', operator: 'ne', value: 'delivered' }]
        : valeur === 'toutes'
          ? []
          : [{ field: 'status', operator: 'eq', value: valeur }],
      'replace',
    );
  };

  return (
    <List title="Commandes">
      <Space style={{ marginBottom: 16 }} wrap>
        <Input.Search
          placeholder="Chercher un repère de livraison…"
          allowClear
          style={{ width: 320 }}
          onSearch={chercher}
          onChange={(e) => {
            if (e.target.value === '') chercher('');
          }}
        />
        <Segmented
          defaultValue="en_cours"
          onChange={(v) => filtrerStatut(String(v))}
          options={[
            { label: 'En cours', value: 'en_cours' },
            { label: 'Livrées', value: 'delivered' },
            { label: 'Annulées', value: 'cancelled' },
            { label: 'Toutes', value: 'toutes' },
          ]}
        />
      </Space>

      <Table
        {...tableProps}
        rowKey="id"
        size="small"
        scroll={{ x: 1300 }}
        // Toute la ligne ouvre la fiche : chercher un bouton « voir » sur
        // une ligne de tableau est un réflexe qu'on n'a pas.
        onRow={(r: Record<string, unknown>) => ({
          onClick: () => setFiche(String(r.id)),
          style: { cursor: 'pointer' },
        })}
      >
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
            <Tag color={COULEURS[v] ?? 'default'}>{libelleEtape(v)}</Tag>
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
          title="Faire avancer"
          render={(_, r: Record<string, unknown>) => {
            const statut = String(r.status);
            const suivant = statutSuivant(statut);
            if (!suivant || statut === 'cancelled') return null;

            return (
              <Space size={4} onClick={(e) => e.stopPropagation()}>
                <Button
                  size="small"
                  type="primary"
                  ghost
                  loading={enCours === r.id}
                  onClick={() => void avancer(String(r.id), suivant)}
                >
                  → {libelleEtape(suivant)}
                </Button>
                <Popconfirm
                  title="Annuler cette commande ?"
                  description="Le client et la boutique en seront avertis."
                  okText="Annuler la commande"
                  cancelText="Non"
                  onConfirm={() => void avancer(String(r.id), 'cancelled')}
                >
                  <Button size="small" danger>
                    Annuler
                  </Button>
                </Popconfirm>
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

      <FicheCommande
        orderId={fiche}
        onFerme={() => setFiche(null)}
        onChange={() => invalider({ resource: 'orders', invalidates: ['list'] })}
      />
    </List>
  );
};

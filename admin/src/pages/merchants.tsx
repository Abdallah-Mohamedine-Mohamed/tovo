import { useState } from 'react';
import { List, useTable } from '@refinedev/antd';
import { useNotification, useUpdate } from '@refinedev/core';
import { Alert, Button, Drawer, Form, Input, Space, Table, Tag } from 'antd';
import { appelerBackend } from '../backend';
import { NouvelleBoutique } from './nouvelleBoutique';

/**
 * Boutiques — et surtout leur approbation.
 *
 * C'est l'action d'administration la plus sensible du produit. Une boutique
 * s'inscrit librement, mais reste invisible au catalogue tant qu'un admin ne
 * l'a pas approuvée : c'est le trigger `guard_merchant_approval` qui le
 * garantit en base, et cet écran est le seul endroit légitime pour lever ce
 * verrou.
 */
interface Boutique {
  id: string;
  name: string;
  phone: string | null;
  is_approved: boolean;
}

interface Proprietaire {
  id: string;
  full_name: string;
  /** Tel que Supabase Auth l'enregistre : sans le « + ». */
  phone: string | null;
  role: string;
}

export const MerchantList = () => {
  const { tableProps, tableQuery, setFilters } = useTable({
    resource: 'merchants',
    sorters: { initial: [{ field: 'created_at', order: 'desc' }] },
    pagination: { pageSize: 25 },
  });

  const { mutate, isLoading } = useUpdate();
  const { open } = useNotification();

  const [enEdition, setEnEdition] = useState<Boutique | null>(null);
  const [proprietaire, setProprietaire] = useState<Proprietaire | null>(null);
  const [enregistre, setEnregistre] = useState(false);
  const [form] = Form.useForm();

  /**
   * Ouvre la fiche d'une boutique.
   *
   * Le numéro de connexion du propriétaire n'est pas dans la table des
   * boutiques : il vit sur son profil, et seul le service peut le lire ou le
   * changer. On va donc le chercher au moment de l'édition.
   */
  /**
   * Recherche par nom.
   *
   * Avec 77 boutiques, faire défiler pour en trouver une est déjà pénible ;
   * ce sera intenable quand elles seront trois cents.
   */
  const chercher = (texte: string) => {
    setFilters(
      texte.trim() ? [{ field: 'name', operator: 'contains', value: texte.trim() }] : [],
      'replace',
    );
  };

  const editer = async (b: Boutique) => {
    setEnEdition(b);
    setProprietaire(null);
    form.setFieldsValue({ phone: b.phone ?? '', owner_phone: '' });

    try {
      const r = await appelerBackend<{ owner: Proprietaire | null }>(
        'GET',
        `/admin/merchants/${b.id}/owner`,
      );
      setProprietaire(r.owner);
      form.setFieldsValue({ owner_phone: r.owner?.phone ? `+${r.owner.phone}` : '' });
    } catch (cause) {
      open?.({ type: 'error', message: 'Propriétaire illisible', description: (cause as Error).message });
    }
  };

  const enregistrer = async () => {
    if (!enEdition) return;
    const valeurs = await form.validateFields();
    setEnregistre(true);

    // On n'envoie le numéro de connexion QUE s'il a changé : le renvoyer
    // identique déclencherait une écriture sur le compte d'authentification
    // pour rien, et la moindre erreur y coûte l'accès du boutiquier.
    const ancien = proprietaire?.phone ? `+${proprietaire.phone}` : '';
    const corps: Record<string, unknown> = { phone: valeurs.phone || null };
    if (valeurs.owner_phone && valeurs.owner_phone !== ancien) {
      corps.owner_phone = valeurs.owner_phone;
    }

    try {
      await appelerBackend('PATCH', `/admin/merchants/${enEdition.id}`, corps);
      open?.({ type: 'success', message: 'Boutique mise à jour' });
      setEnEdition(null);
      tableQuery.refetch();
    } catch (cause) {
      open?.({ type: 'error', message: 'Modification refusée', description: (cause as Error).message });
    } finally {
      setEnregistre(false);
    }
  };

  const basculer = (id: string, approuvee: boolean) => {
    mutate(
      {
        resource: 'merchants',
        id,
        values: { is_approved: !approuvee },
      },
      { onSuccess: () => tableQuery.refetch() },
    );
  };

  return (
    <List
      title="Boutiques"
      headerButtons={
        <Space>
          <NouvelleBoutique onCreee={() => void tableQuery.refetch()} />
        </Space>
      }
    >
      <Input.Search
        placeholder="Chercher une boutique…"
        allowClear
        style={{ width: 320, marginBottom: 16 }}
        onSearch={(t) => chercher(t)}
        onChange={(e) => {
          if (e.target.value === '') chercher('');
        }}
      />

      <Table {...tableProps} rowKey="id" size="small">
        <Table.Column dataIndex="name" title="Nom" />
        <Table.Column dataIndex="address_hint" title="Adresse" ellipsis />
        <Table.Column dataIndex="phone" title="Téléphone" />
        <Table.Column
          dataIndex="is_approved"
          title="Approuvée"
          render={(v: boolean) => (
            <Tag color={v ? 'green' : 'red'}>{v ? 'Oui' : 'En attente'}</Tag>
          )}
        />
        <Table.Column
          dataIndex="is_open"
          title="Ouverte"
          render={(v: boolean) => (
            <Tag color={v ? 'blue' : 'default'}>{v ? 'Oui' : 'Non'}</Tag>
          )}
        />
        <Table.Column
          dataIndex="prep_time_min"
          title="Préparation"
          render={(v) => `${v ?? 0} min`}
        />
        <Table.Column
          title="Action"
          render={(_, r: { id: string; is_approved: boolean }) => (
            <Space>
              <Button
                size="small"
                type={r.is_approved ? 'default' : 'primary'}
                danger={r.is_approved}
                loading={isLoading}
                onClick={() => basculer(r.id, r.is_approved)}
              >
                {r.is_approved ? 'Retirer du catalogue' : 'Approuver'}
              </Button>
              <Button size="small" onClick={() => void editer(r as Boutique)}>
                Modifier
              </Button>
            </Space>
          )}
        />
      </Table>

      <Drawer
        title={enEdition?.name ?? 'Boutique'}
        open={enEdition !== null}
        onClose={() => setEnEdition(null)}
        width={430}
        extra={
          <Button type="primary" loading={enregistre} onClick={() => void enregistrer()}>
            Enregistrer
          </Button>
        }
      >
        <Alert
          type="info"
          showIcon
          style={{ marginBottom: 18 }}
          message="Deux numéros différents"
          description="Le premier s'affiche au client et sert à joindre le commerce. Le second ouvre la session du boutiquier dans son application : le changer déplace son compte, et l'ancien numéro ne permettra plus d'entrer."
        />

        <Form form={form} layout="vertical">
          <Form.Item
            name="phone"
            label="Numéro public de la boutique"
            extra="Affiché au client. Peut être un fixe."
          >
            <Input placeholder="+227 90 00 00 00" />
          </Form.Item>

          <Form.Item
            name="owner_phone"
            label="Numéro de connexion du boutiquier"
            extra={
              proprietaire
                ? `Compte : ${proprietaire.full_name} (${proprietaire.role})`
                : 'Chargement du propriétaire…'
            }
          >
            <Input placeholder="+227 90 00 00 00" />
          </Form.Item>
        </Form>
      </Drawer>
    </List>
  );
};

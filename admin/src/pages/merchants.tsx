import { List, useTable } from '@refinedev/antd';
import { useUpdate } from '@refinedev/core';
import { Button, Space, Table, Tag } from 'antd';

/**
 * Boutiques — et surtout leur approbation.
 *
 * C'est l'action d'administration la plus sensible du produit. Une boutique
 * s'inscrit librement, mais reste invisible au catalogue tant qu'un admin ne
 * l'a pas approuvée : c'est le trigger `guard_merchant_approval` qui le
 * garantit en base, et cet écran est le seul endroit légitime pour lever ce
 * verrou.
 */
export const MerchantList = () => {
  const { tableProps, tableQuery } = useTable({
    resource: 'merchants',
    sorters: { initial: [{ field: 'created_at', order: 'desc' }] },
    pagination: { pageSize: 25 },
  });

  const { mutate, isLoading } = useUpdate();

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
    <List title="Boutiques">
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
            </Space>
          )}
        />
      </Table>
    </List>
  );
};

import { List, useTable, DateField } from '@refinedev/antd';
import { Table, Tag } from 'antd';

/**
 * Livreurs et collectes.
 *
 * Deux tableaux qui répondent à deux questions différentes : qui travaille
 * en ce moment, et qui doit combien.
 */

const xof = (v: unknown) =>
  `${Number(v ?? 0).toLocaleString('fr-FR').replace(/ | /g, ' ')} F`;

export const DriverList = () => {
  const { tableProps } = useTable({
    resource: 'driver_profiles',
    sorters: { initial: [{ field: 'last_seen_at', order: 'desc' }] },
    meta: { select: '*, profiles(full_name, phone)' },
    pagination: { pageSize: 25 },
  });

  return (
    <List title="Livreurs">
      <Table {...tableProps} rowKey="id" size="small">
        <Table.Column
          title="Nom"
          render={(_, r: { profiles?: { full_name?: string } }) =>
            r.profiles?.full_name || '—'
          }
        />
        <Table.Column
          title="Téléphone"
          render={(_, r: { profiles?: { phone?: string } }) => r.profiles?.phone || '—'}
        />
        <Table.Column
          dataIndex="is_online"
          title="En ligne"
          render={(v: boolean) => (
            <Tag color={v ? 'green' : 'default'}>{v ? 'Oui' : 'Non'}</Tag>
          )}
        />
        <Table.Column
          dataIndex="is_available"
          title="Disponible"
          render={(v: boolean) => (
            <Tag color={v ? 'blue' : 'orange'}>{v ? 'Libre' : 'En course'}</Tag>
          )}
        />
        <Table.Column dataIndex="vehicle_type" title="Véhicule" />
        <Table.Column
          dataIndex="last_seen_at"
          title="Dernier signal"
          render={(v) =>
            v ? <DateField value={v} format="DD/MM HH:mm" /> : '—'
          }
        />
      </Table>
    </List>
  );
};

/**
 * Registre des espèces.
 *
 * Le livreur encaisse le cash des commandes réglées en espèces et le reverse
 * ensuite. Ce registre est la trace comptable de ces mouvements : positif,
 * il a encaissé ; négatif, il a reversé.
 */
export const CashList = () => {
  const { tableProps } = useTable({
    resource: 'driver_cash_ledger',
    sorters: { initial: [{ field: 'created_at', order: 'desc' }] },
    pagination: { pageSize: 50 },
  });

  return (
    <List title="Collectes en espèces">
      <Table {...tableProps} rowKey="id" size="small">
        <Table.Column
          dataIndex="created_at"
          title="Date"
          render={(v) => <DateField value={v} format="DD/MM HH:mm" />}
        />
        <Table.Column
          dataIndex="entry_type"
          title="Nature"
          render={(v: string) => {
            const libelles: Record<string, string> = {
              collection: 'Encaissement',
              settlement: 'Versement',
              adjustment: 'Ajustement',
            };
            return <Tag>{libelles[v] ?? v}</Tag>;
          }}
        />
        <Table.Column
          dataIndex="amount"
          title="Montant"
          align="right"
          render={(v: number) => (
            <span style={{ color: v >= 0 ? '#006666' : '#E74C3C' }}>{xof(v)}</span>
          )}
        />
        <Table.Column dataIndex="note" title="Note" ellipsis />
      </Table>
    </List>
  );
};

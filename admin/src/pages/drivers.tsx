import { useState } from 'react';
import { List, useTable, DateField } from '@refinedev/antd';
import { useNotification } from '@refinedev/core';
import { Button, Drawer, Form, Input, Select, Space, Table, Tag } from 'antd';
import { appelerBackend } from '../backend';

/**
 * Livreurs et collectes.
 *
 * Deux tableaux qui répondent à deux questions différentes : qui travaille
 * en ce moment, et qui doit combien.
 */

const xof = (v: unknown) =>
  `${Number(v ?? 0).toLocaleString('fr-FR').replace(/ | /g, ' ')} F`;

/**
 * Recrutement d'un livreur.
 *
 * Il n'y avait aucun chemin : le livreur devait installer l'app CLIENT,
 * s'inscrire lui-même, puis quelqu'un modifiait son rôle directement en
 * base. Ici l'administration crée le compte, et le livreur n'a plus qu'à
 * ouvrir l'app livreur avec son numéro.
 */
const RecruterLivreur = ({ onCree }: { onCree: () => void }) => {
  const { open } = useNotification();
  const [ouvert, setOuvert] = useState(false);
  const [occupe, setOccupe] = useState(false);
  const [form] = Form.useForm();

  const enregistrer = async () => {
    const valeurs = await form.validateFields();
    setOccupe(true);
    try {
      const reponse = await appelerBackend<{ content?: string }>(
        'POST',
        '/admin/drivers',
        valeurs,
      );
      open?.({
        type: 'success',
        message: 'Livreur enregistré',
        description: reponse.content ?? '',
      });
      form.resetFields();
      setOuvert(false);
      onCree();
    } catch (cause) {
      open?.({
        type: 'error',
        message: 'Création impossible',
        description: cause instanceof Error ? cause.message : String(cause),
      });
    } finally {
      setOccupe(false);
    }
  };

  return (
    <>
      <Button type="primary" onClick={() => setOuvert(true)}>
        Ajouter un livreur
      </Button>
      <Drawer
        title="Nouveau livreur"
        open={ouvert}
        onClose={() => setOuvert(false)}
        width={420}
        extra={
          <Button type="primary" loading={occupe} onClick={() => void enregistrer()}>
            Enregistrer
          </Button>
        }
      >
        <Form form={form} layout="vertical" initialValues={{ vehicle_type: 'moto' }}>
          <Form.Item
            name="full_name"
            label="Nom complet"
            rules={[{ required: true, min: 2, message: 'Le nom est obligatoire.' }]}
          >
            <Input placeholder="Ibrahim Moussa" />
          </Form.Item>
          <Form.Item
            name="phone"
            label="Téléphone"
            // C'est l'identité du compte : il n'y a ni email ni mot de passe,
            // le livreur se connecte par code WhatsApp sur ce numéro.
            extra="Le livreur se connectera avec ce numéro. 8 chiffres, ou +227…"
            rules={[{ required: true, min: 6, message: 'Le numéro est obligatoire.' }]}
          >
            <Input placeholder="90 00 00 00" />
          </Form.Item>
          <Form.Item name="vehicle_type" label="Véhicule">
            <Select
              options={[
                { value: 'moto', label: 'Moto' },
                { value: 'velo', label: 'Vélo' },
                { value: 'voiture', label: 'Voiture' },
              ]}
            />
          </Form.Item>
          <Form.Item name="plate_number" label="Plaque (facultatif)">
            <Input placeholder="1A 2345 RN" />
          </Form.Item>
        </Form>
      </Drawer>
    </>
  );
};

export const DriverList = () => {
  const { tableProps, tableQuery } = useTable({
    resource: 'driver_profiles',
    sorters: { initial: [{ field: 'last_seen_at', order: 'desc' }] },
    meta: { select: '*, profiles(full_name, phone)' },
    pagination: { pageSize: 25 },
  });

  return (
    <List
      title="Livreurs"
      headerButtons={
        <Space>
          <RecruterLivreur onCree={() => void tableQuery.refetch()} />
        </Space>
      }
    >
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

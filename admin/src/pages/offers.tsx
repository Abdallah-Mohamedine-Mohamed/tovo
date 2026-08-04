import { useCallback, useEffect, useState } from 'react';
import { List } from '@refinedev/antd';
import { useNotification } from '@refinedev/core';
import {
  Alert,
  Button,
  Drawer,
  Form,
  Input,
  InputNumber,
  Popconfirm,
  Space,
  Switch,
  Table,
  Tag,
  Typography,
} from 'antd';
import { appelerBackend } from '../backend';

/**
 * Prix de la concurrence.
 *
 * Le comparateur de Tovo est hybride : les boutiques partenaires sont
 * commandables, ces offres-ci seulement consultables — le client voit
 * « Voir » et non « Commander ».
 *
 * Ces écritures passent par le backend et non par PostgREST : chaque offre
 * doit être vectorisée pour ressortir dans une comparaison, et la clé Gemini
 * n'a rien à faire dans un bundle web. Une offre sans vecteur serait visible
 * ici et invisible pour les clients, sans aucun signal.
 */

interface Offre {
  id: string;
  source: string;
  source_url: string | null;
  title: string;
  price: number;
  in_stock: boolean;
  expires_at: string;
  embedded_at: string | null;
}

const xof = (v: unknown) =>
  `${Number(v ?? 0).toLocaleString('fr-FR').replace(/ | /g, ' ')} F`;

const joursRestants = (iso: string) =>
  Math.ceil((new Date(iso).getTime() - Date.now()) / 86_400_000);

export const OfferList = () => {
  const { open } = useNotification();
  const [offres, setOffres] = useState<Offre[]>([]);
  const [chargement, setChargement] = useState(true);
  const [erreur, setErreur] = useState<string | null>(null);
  const [ouvert, setOuvert] = useState(false);
  const [enCours, setEnCours] = useState(false);
  const [form] = Form.useForm();

  const charger = useCallback(async () => {
    setChargement(true);
    try {
      const r = await appelerBackend<{ offers: Offre[] }>('GET', '/admin/external-offers');
      setOffres(r.offers ?? []);
      setErreur(null);
    } catch (cause) {
      setErreur((cause as Error).message);
    } finally {
      setChargement(false);
    }
  }, []);

  useEffect(() => {
    void charger();
  }, [charger]);

  const enregistrer = async () => {
    const valeurs = await form.validateFields();
    setEnCours(true);
    try {
      await appelerBackend('POST', '/admin/external-offers', {
        ...valeurs,
        source_url: valeurs.source_url || null,
        in_stock: valeurs.in_stock ?? true,
        valid_days: valeurs.valid_days ?? 30,
      });
      open?.({ type: 'success', message: 'Offre enregistrée' });
      setOuvert(false);
      form.resetFields();
      await charger();
    } catch (cause) {
      open?.({
        type: 'error',
        message: 'Enregistrement refusé',
        description: (cause as Error).message,
      });
    } finally {
      setEnCours(false);
    }
  };

  const supprimer = async (id: string) => {
    try {
      await appelerBackend('DELETE', `/admin/external-offers/${id}`);
      open?.({ type: 'success', message: 'Offre retirée' });
      await charger();
    } catch (cause) {
      open?.({ type: 'error', message: 'Suppression refusée', description: (cause as Error).message });
    }
  };

  return (
    <List
      title="Prix concurrents"
      headerButtons={<Button type="primary" onClick={() => setOuvert(true)}>Relever un prix</Button>}
    >
      {erreur && (
        <Alert type="error" showIcon style={{ marginBottom: 16 }} message={erreur} />
      )}

      <Alert
        type="info"
        showIcon
        style={{ marginBottom: 16 }}
        message="Ces prix ne sont pas commandables"
        description="Ils apparaissent dans les comparaisons à côté des boutiques partenaires, avec un bouton « Voir » qui renvoie vers le vendeur. Ils servent à montrer au client qu'il compare vraiment, pas à vendre."
      />

      <Table dataSource={offres} loading={chargement} rowKey="id" size="small" pagination={false}>
        <Table.Column dataIndex="title" title="Produit" ellipsis />
        <Table.Column dataIndex="source" title="Vendeur" />
        <Table.Column dataIndex="price" title="Prix" render={xof} align="right" />
        <Table.Column
          dataIndex="in_stock"
          title="Dispo."
          render={(v: boolean) => (v ? <Tag color="green">Oui</Tag> : <Tag>Non</Tag>)}
        />
        <Table.Column
          title="Visible"
          render={(_, r: Offre) =>
            // Sans vecteur, l'offre n'apparaît dans aucune comparaison. Le
            // dire ici évite de chercher pourquoi les clients ne la voient
            // pas alors qu'elle figure bien dans ce tableau.
            r.embedded_at ? (
              <Tag color="green">Indexée</Tag>
            ) : (
              <Tag color="red">Non indexée</Tag>
            )
          }
        />
        <Table.Column
          dataIndex="expires_at"
          title="Expire dans"
          align="right"
          render={(v: string) => {
            const jours = joursRestants(v);
            return (
              <Typography.Text type={jours <= 3 ? 'danger' : undefined}>
                {jours <= 0 ? 'Expirée' : `${jours} j`}
              </Typography.Text>
            );
          }}
        />
        <Table.Column
          title=""
          align="right"
          render={(_, r: Offre) => (
            <Space size={4}>
              {r.source_url && (
                <Button size="small" type="link" href={r.source_url} target="_blank">
                  Voir
                </Button>
              )}
              <Popconfirm title="Retirer ce prix ?" onConfirm={() => supprimer(r.id)}>
                <Button size="small" danger>
                  Retirer
                </Button>
              </Popconfirm>
            </Space>
          )}
        />
      </Table>

      <Drawer
        title="Relever un prix concurrent"
        open={ouvert}
        onClose={() => setOuvert(false)}
        width={420}
        extra={
          <Button type="primary" loading={enCours} onClick={enregistrer}>
            Enregistrer
          </Button>
        }
      >
        <Form form={form} layout="vertical" initialValues={{ valid_days: 30, in_stock: true }}>
          <Form.Item
            name="title"
            label="Produit"
            rules={[{ required: true, message: 'Indiquez le produit' }]}
            extra="Le libellé sert à retrouver l'offre : écrivez-le comme un client le chercherait."
          >
            <Input placeholder="Ventilateur brasseur d’air 16 pouces" />
          </Form.Item>
          <Form.Item
            name="source"
            label="Vendeur"
            rules={[{ required: true, message: 'Indiquez le vendeur' }]}
          >
            <Input placeholder="Jumia Niger, Marché Katako…" />
          </Form.Item>
          <Form.Item
            name="price"
            label="Prix (F CFA)"
            rules={[{ required: true, message: 'Indiquez le prix' }]}
          >
            <InputNumber min={0} step={500} style={{ width: '100%' }} />
          </Form.Item>
          <Form.Item name="source_url" label="Lien (facultatif)">
            <Input placeholder="https://…" />
          </Form.Item>
          <Form.Item
            name="valid_days"
            label="Valable (jours)"
            extra="Passé ce délai, le prix disparaît des comparaisons plutôt que d'induire le client en erreur."
          >
            <InputNumber min={1} max={365} style={{ width: '100%' }} />
          </Form.Item>
          <Form.Item name="in_stock" label="En stock chez le vendeur" valuePropName="checked">
            <Switch />
          </Form.Item>
        </Form>
      </Drawer>
    </List>
  );
};

import { Edit, useForm } from '@refinedev/antd';
import { Alert, Card, Col, Form, InputNumber, Row, Select } from 'antd';

/**
 * Grille tarifaire et paramètres de plateforme.
 *
 * Tout ce qui est métier vit ici, jamais dans le code. C'est la conséquence
 * directe du principe « l'admin configure tout » : sinon changer une
 * commission demanderait une migration et un déploiement.
 *
 * Une seule ligne existe dans `platform_settings` — clé primaire booléenne
 * valant toujours `true`, ce qui interdit structurellement qu'une seconde
 * apparaisse.
 */
export const SettingsEdit = () => {
  const { formProps, saveButtonProps } = useForm({
    resource: 'platform_settings',
    id: 'true',
    action: 'edit',
    redirect: false,
  });

  return (
    <Edit
      title="Paramètres de la plateforme"
      saveButtonProps={saveButtonProps}
      recordItemId="true"
      canDelete={false}
      breadcrumb={false}
    >
      <Alert
        type="info"
        showIcon
        style={{ marginBottom: 24 }}
        message="Les commandes déjà passées ne sont pas affectées"
        description="Commission, versement boutique et rémunération livreur sont figés sur chaque commande au moment où elle est passée. Modifier cette grille ne change que les commandes à venir."
      />

      <Form {...formProps} layout="vertical">
        <Row gutter={16}>
          <Col xs={24} lg={12}>
            <Card title="Commission Tovo" size="small" style={{ marginBottom: 16 }}>
              <Form.Item
                label="Mode de calcul"
                name="commission_mode"
                rules={[{ required: true }]}
              >
                <Select
                  options={[
                    { value: 'percent', label: 'Pourcentage du panier' },
                    { value: 'flat', label: 'Forfait par commande' },
                  ]}
                />
              </Form.Item>

              <Form.Item label="Pourcentage (%)" name="commission_percent">
                <InputNumber min={0} max={100} step={0.5} style={{ width: '100%' }} />
              </Form.Item>

              <Form.Item label="Forfait (XOF)" name="commission_flat">
                <InputNumber min={0} step={50} style={{ width: '100%' }} />
              </Form.Item>
            </Card>

            <Card title="Rémunération des livreurs" size="small">
              <Form.Item label="Mode de calcul" name="driver_pay_mode">
                <Select
                  options={[
                    { value: 'flat', label: 'Forfait par course' },
                    { value: 'distance', label: 'Forfait + distance' },
                  ]}
                />
              </Form.Item>

              <Form.Item label="Base par course (XOF)" name="driver_pay_base">
                <InputNumber min={0} step={50} style={{ width: '100%' }} />
              </Form.Item>

              <Form.Item label="Par kilomètre (XOF)" name="driver_pay_per_km">
                <InputNumber min={0} step={25} style={{ width: '100%' }} />
              </Form.Item>
            </Card>
          </Col>

          <Col xs={24} lg={12}>
            <Card title="Service coursier" size="small" style={{ marginBottom: 16 }}>
              <Form.Item label="Prise en charge (XOF)" name="courier_base">
                <InputNumber min={0} step={50} style={{ width: '100%' }} />
              </Form.Item>
              <Form.Item label="Par kilomètre (XOF)" name="courier_per_km">
                <InputNumber min={0} step={25} style={{ width: '100%' }} />
              </Form.Item>
              <Form.Item label="Supplément colis moyen" name="courier_medium_surcharge">
                <InputNumber min={0} step={50} style={{ width: '100%' }} />
              </Form.Item>
              <Form.Item label="Supplément grand colis" name="courier_large_surcharge">
                <InputNumber min={0} step={50} style={{ width: '100%' }} />
              </Form.Item>
              <Form.Item label="Prix plancher" name="courier_minimum">
                <InputNumber min={0} step={50} style={{ width: '100%' }} />
              </Form.Item>
            </Card>

            <Card title="Dispatch et recherche" size="small">
              <Form.Item
                label="Livreurs notifiés par course"
                name="dispatch_candidates"
                tooltip="Les N plus proches sont notifiés en même temps ; le premier qui accepte obtient la course."
              >
                <InputNumber min={1} max={10} style={{ width: '100%' }} />
              </Form.Item>
              <Form.Item label="Rayon de dispatch (m)" name="dispatch_max_radius_m">
                <InputNumber min={500} step={500} style={{ width: '100%' }} />
              </Form.Item>
              <Form.Item label="Rayon de recherche client (m)" name="search_radius_m">
                <InputNumber min={500} step={500} style={{ width: '100%' }} />
              </Form.Item>
              <Form.Item
                label="Frais de livraison par défaut (XOF)"
                name="default_delivery_fee"
                tooltip="Appliqué hors de toute zone. Les zones ont chacune leur propre tarif."
              >
                <InputNumber min={0} step={50} style={{ width: '100%' }} />
              </Form.Item>
            </Card>
          </Col>
        </Row>
      </Form>
    </Edit>
  );
};

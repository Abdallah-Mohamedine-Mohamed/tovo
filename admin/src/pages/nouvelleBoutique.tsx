import { useEffect, useState } from 'react';
import { useNotification } from '@refinedev/core';
import { Alert, Button, Drawer, Form, Input, InputNumber, Select, Space } from 'antd';
import { appelerBackend } from '../backend';
import { supabaseClient } from '../supabaseClient';

/**
 * Ouverture d'une boutique par l'administration.
 *
 * Le seul chemin qui existait passait par la migration depuis 6ammart. Une
 * enseigne démarchée aujourd'hui n'avait aucun moyen d'entrer : il fallait
 * insérer la ligne à la main en base, puis créer le compte du propriétaire,
 * puis relier les deux.
 *
 * Deux numéros sont demandés, et les confondre serait une faute :
 * le numéro PUBLIC est celui qu'on affiche au client ; celui du
 * PROPRIÉTAIRE ouvre la session dans l'app boutique. Ils sont souvent
 * identiques — rien ne l'impose.
 */

interface Categorie {
  id: string;
  name: string;
}

export const NouvelleBoutique = ({ onCreee }: { onCreee: () => void }) => {
  const { open } = useNotification();
  const [ouvert, setOuvert] = useState(false);
  const [occupe, setOccupe] = useState(false);
  const [categories, setCategories] = useState<Categorie[]>([]);
  const [form] = Form.useForm();

  useEffect(() => {
    if (!ouvert || categories.length > 0) return;
    void (async () => {
      // Les modules seulement — une boutique appartient à « Restaurants »,
      // pas à « PIZZA », qui est un rayon à l'intérieur.
      const { data } = await supabaseClient
        .from('categories')
        .select('id, name')
        .is('parent_id', null)
        .eq('is_active', true)
        .order('sort_order');
      setCategories((data ?? []) as Categorie[]);
    })();
  }, [ouvert, categories.length]);

  const enregistrer = async () => {
    const valeurs = await form.validateFields();
    setOccupe(true);
    try {
      const reponse = await appelerBackend<{ content?: string }>('POST', '/admin/merchants', {
        ...valeurs,
        lat: Number(valeurs.lat),
        lng: Number(valeurs.lng),
      });
      open?.({
        type: 'success',
        message: 'Boutique créée',
        description: reponse.content ?? '',
      });
      form.resetFields();
      setOuvert(false);
      onCreee();
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
        Ajouter une boutique
      </Button>
      <Drawer
        title="Nouvelle boutique"
        open={ouvert}
        onClose={() => setOuvert(false)}
        width={480}
        extra={
          <Button type="primary" loading={occupe} onClick={() => void enregistrer()}>
            Créer
          </Button>
        }
      >
        <Alert
          type="info"
          showIcon
          style={{ marginBottom: 16 }}
          message="Elle sera approuvée mais fermée"
          description="Le boutiquier l'ouvre lui-même depuis son application, quand il est prêt à recevoir des commandes."
        />

        <Form form={form} layout="vertical" initialValues={{ prep_time_min: 20 }}>
          <Form.Item
            name="name"
            label="Nom de la boutique"
            rules={[{ required: true, min: 2, message: 'Le nom est obligatoire.' }]}
          >
            <Input placeholder="Otakoss" />
          </Form.Item>

          <Form.Item
            name="category_id"
            label="Module"
            rules={[{ required: true, message: 'Choisissez un module.' }]}
          >
            <Select
              placeholder="Restaurants, Boutiques, Grocery…"
              options={categories.map((c) => ({ value: c.id, label: c.name }))}
              notFoundContent="Chargement…"
            />
          </Form.Item>

          <Form.Item
            name="phone"
            label="Téléphone public"
            extra="Affiché au client pour joindre le commerce."
            rules={[{ required: true, min: 6, message: 'Le numéro public est obligatoire.' }]}
          >
            <Input placeholder="90 00 00 00" />
          </Form.Item>

          <Form.Item
            name="owner_name"
            label="Nom du propriétaire"
            rules={[{ required: true, min: 2, message: 'Le nom est obligatoire.' }]}
          >
            <Input placeholder="Amadou Souley" />
          </Form.Item>

          <Form.Item
            name="owner_phone"
            label="Téléphone de connexion (facultatif)"
            extra="Celui qui ouvre la session dans l'app boutique. Vide = le numéro public."
          >
            <Input placeholder="Laisser vide si identique" />
          </Form.Item>

          <Form.Item
            name="address_hint"
            label="Repère"
            extra="À Niamey l'adresse postale n'existe pas : décrivez comme on l'explique à un livreur."
            rules={[{ required: true, min: 2, message: 'Le repère est obligatoire.' }]}
          >
            <Input placeholder="Yantala, face à la station Oryx" />
          </Form.Item>

          {/* La position décide de tout le dispatch : c'est elle qui place la
              boutique dans une zone, donc qui rend ses commandes visibles aux
              livreurs. Un repère seul ne suffit pas. */}
          <Space.Compact style={{ width: '100%' }}>
            <Form.Item
              name="lat"
              label="Latitude"
              style={{ width: '50%' }}
              rules={[{ required: true, message: 'Latitude obligatoire.' }]}
            >
              <InputNumber style={{ width: '100%' }} step={0.0001} placeholder="13.5137" />
            </Form.Item>
            <Form.Item
              name="lng"
              label="Longitude"
              style={{ width: '50%' }}
              rules={[{ required: true, message: 'Longitude obligatoire.' }]}
            >
              <InputNumber style={{ width: '100%' }} step={0.0001} placeholder="2.1098" />
            </Form.Item>
          </Space.Compact>

          <Form.Item
            name="prep_time_min"
            label="Temps de préparation (minutes)"
            extra="Sert à annoncer un délai au client."
          >
            <InputNumber min={0} max={180} style={{ width: '100%' }} />
          </Form.Item>
        </Form>
      </Drawer>
    </>
  );
};

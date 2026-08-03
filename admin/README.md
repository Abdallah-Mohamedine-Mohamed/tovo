# Tovo — Administration

Refine.js + Ant Design + Supabase. React 18, Vite, TypeScript strict.

```bash
cd admin
cp .env.example .env.local     # renseigner URL + clé publishable
npm install
npm run dev                    # http://localhost:5173
```

---

## Accès

La connexion se fait avec un compte Supabase dont `profiles.role = 'admin'`.
Aucun compte n'a ce rôle par défaut : le trigger `handle_new_user` force
`client` à l'inscription, précisément pour qu'on ne puisse pas s'auto-promouvoir.

Pour créer le premier administrateur, dans le SQL Editor de Supabase :

```sql
update profiles set role = 'admin'
where id = (select id from auth.users where email = 'mohamedine@tovoapp.com');
```

Puis se connecter avec cet e-mail et son mot de passe.

---

## Sécurité

Cette interface parle **directement à Supabase**, sans passer par le backend
Node. Chaque écran est une lecture ou une écriture simple, et la RLS fait
déjà le contrôle d'accès — y intercaler une API n'ajouterait qu'un
intermédiaire à maintenir.

La clé utilisée est la clé **publishable**. Elle est compilée dans le bundle
et donc publique : c'est normal et sans danger, tant qu'on comprend que
**toute la sécurité repose sur la RLS**. Ne jamais mettre la clé secrète dans
un fichier `VITE_*`.

Le contrôle de rôle dans `authProvider.ts` est du confort, pas une barrière :
il évite qu'un boutiquier tombe sur une interface vide et déroutante. Même
contourné, la base ne renverrait que ce que `is_admin()` autorise.

---

## Écrans

| Écran | Ce qu'il permet |
|---|---|
| **Commandes** | Suivi temps réel, avec commission, dû boutique, dû livreur et marge Tovo par commande |
| **Boutiques** | Approuver ou retirer une boutique du catalogue |
| **Livreurs** | Qui est en ligne, disponible, et depuis quand il n'a plus donné signe |
| **Collectes** | Registre des espèces : encaissements et versements |
| **Paramètres** | Commission, rémunération livreur, tarifs coursier, dispatch, rayons de recherche |

Les tableaux se mettent à jour seuls via Supabase Realtime (`liveMode: auto`).

---

## Ce qui n'est pas fait

**Le tracé des zones.** `delivery_zones.area` est un polygone PostGIS ; le
modifier demande une carte interactive, pas un formulaire. Les zones du seed
sont des cercles approximatifs, à retracer avec les livreurs avant le
lancement — pour l'instant en SQL.

**La gestion du catalogue.** Elle appartient au boutiquier, dans son app.
L'admin n'a pas vocation à saisir les produits à sa place.

**Les analytics.** Volume par jour, panier moyen, taux d'acceptation. À faire
quand il y aura des données réelles à observer.

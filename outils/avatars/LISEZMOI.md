# Avatars de la carte

Le point « Vous » de la carte devient l'avatar du client. Il attend, marche ou
court selon sa vitesse réelle, de jour comme de nuit. Décision du 07/10/2026,
vidéos validées.

Comme la moto du suivi (`mobile/assets/carte/scooter/`, 144 vues), Google Maps
n'affiche pas de 3D. On **précalcule** donc des images du personnage sous tous
les angles, et l'application affiche celle qui correspond à l'instant présent.

## Générer

```
cd outils/avatars
npm install
node generer.cjs                 # les 4 avatars, ~10 min
node generer.cjs femme capuche   # ou seulement ceux-là
```

Il faut Google Chrome installé : il sert au rendu 3D, sans fenêtre. Pour un
autre emplacement de Chrome, définir la variable `CHROME=chemin/vers/chrome`.

## Ce qui sort (`images/`, non versionné : on le régénère)

- **Une bande par animation × inclinaison × direction**, par exemple
  `femme/walk_t45_090.webp` :
  - toutes les images d'un cycle côte à côte, 240 × 240 px chacune ;
  - format WebP transparent.
- **Les animations** : `idle` (arrêt), `walk` (marche), `run` (course, aussi en
  voiture ou à moto), `wave` (salut). Homme n'a pas de salut.
- **Les inclinaisons** : 0, 30, 45 et 60°, comme la caméra du suivi.
- **Les directions** : tous les 15°.
  - C'est le cap de l'avatar **vu de la caméra**, soit cap − rotation de la
    carte.
  - 0 = il s'éloigne vers le haut de l'écran, 90 = il va vers la droite.
- **`manifest.json`** :
  - la durée de chaque cycle ;
  - la **foulée** (en mètres par cycle) ;
  - l'**ancrage** : les pieds sont à `y = 0.851` de la hauteur de l'image.

## Pour l'application : des pas qui ne glissent pas

L'image affichée ne dépend pas du temps, mais de la **distance parcourue** :

    image = floor((distance_parcourue / foulée) × nombre_d'images) mod nombre_d'images

Un pas affiché correspond ainsi à un pas réel. À l'arrêt et pour le salut, on
avance au rythme du temps.

## Les modèles (`modeles/`)

Personnages de Quaternius, publiés en domaine public (CC0). À vérifier sur leur
page d'origine.

| Fichier | Personnage |
|---|---|
| `femme.glb` | Animated Woman |
| `capuche.glb` | Hoodie Character |
| `aventurier.glb` | Adventurer |
| `homme.glb` | Animated Human (sans couleurs) |

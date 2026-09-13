# Revue visuelle client — septembre 2026

## Périmètre

Cette itération porte sur le parcours client : conversation, catalogue des
enseignes, carte d'une enseigne, fiche produit, panier et confirmation de commande.
Le thème est propre au client ; les applications marchand et livreur conservent
leur thème. Les écrans d'authentification, de suivi et le formulaire coursier
n'ont pas fait l'objet d'une refonte complète dans cette itération.

## Direction

- Fond blanc, texte sombre, accent teal pour les états et interactions.
- DM Sans embarquée, hiérarchie par taille et graisse plutôt que cartes imbriquées.
- Enseigne identifiable par son nom et son logo ; photos réelles des produits.
- Recherche de carte fixe, catégories accessibles et liste paginée indépendante du chat.
- Fiche produit avec photo agrandissable, options en lignes, prix et quantité fixes en bas.
- Retour à la carte sans perdre sa position ; la navigation ne devient pas une conversation.
- Panier indépendant, quantités et totaux confirmés par le serveur, mutations sérialisées.
- Livraison indiquée « À calculer » tant que l'adresse est inconnue. Le récapitulatif
  final affiche le devis du serveur et exige un geste explicite de confirmation.
- Aucun faux avis, promotion, temps de livraison ou description ajouté pour décorer.

## Vérification

`mobile/test/design_review_test.dart` exécute les vrais écrans Flutter avec des
réponses réseau simulées. Les photos, noms et prix de Garba d'Or proviennent du
catalogue public et sont conservés dans `mobile/test/fixtures/design/` pour rendre
les essais reproductibles sans réseau. L'ouverture du commerce, le panier,
l'adresse et les frais de livraison sont des états de démonstration, pas des
informations en temps réel. Aucun de ces tests ne passe une commande réelle.

Pour produire les captures dans `mobile/build/design-review/`, exécuter depuis
`mobile/` :

```powershell
flutter test --no-pub test/design_review_test.dart --dart-define=TOVO_RENDER_PREVIEW=true
```

Les tests `catalog_screen_test.dart`, `product_screen_test.dart` et
`cart_screen_test.dart` couvrent pagination, retour, prix des options, quantité,
indisponibilité, panier mono-enseigne, lenteur réseau et reprise après échec.
La revue visuelle couvre aussi un petit écran avec texte agrandi.

## APK de test approuvé

La direction visuelle a été validée le 10 septembre 2026. L'APK client est disponible
dans `mobile/build/releases/Tovo-client-refonte-2026-09-10.apk` ; le précédent est
conservé dans `mobile/build/releases/Tovo-client-avant-refonte-2026-09-10.apk`.

La compilation release est réussie. L'identifiant `com.unique.tovo.user` et la
signature locale sont identiques à ceux du précédent APK de test. Il s'agit de la
signature de développement, pas d'un artefact signé pour publication en boutique.
Les deux URL et la clé publique Supabase ont été vérifiées dans le binaire compilé,
sans afficher leur contenu. La route catalogue déployée répond HTTP 200.

Les 42 tests ciblés et l'analyse statique sont réussis ; l'installation et les
interactions sur un téléphone Android réel restent à vérifier. Aucune publication
Play Store/TestFlight, aucun déploiement backend et aucune migration n'ont été
effectués dans cette itération. Le catalogue utilise la route et la migration 0050
préparées lors du chantier précédent ; voir `docs/catalogue_navigation.md`.

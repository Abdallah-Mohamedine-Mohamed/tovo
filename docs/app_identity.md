# Identité des applications publiées

Valeurs relevées le 01/08/2026 dans App Store Connect et la Play Console.
**Elles ne sont pas modifiables.** Le nouveau projet Flutter doit les
reprendre à l'identique, sinon la mise à jour devient une nouvelle fiche
store et les utilisateurs existants sont perdus.

## App client

| | iOS | Android |
|---|---|---|
| Identifiant | `com.tovoapp.UserApp` | `com.unique.tovo.user` |
| Apple ID | `6740201431` | — |
| SKU | `com.tovo` | — |
| Nom affiché | Tovo | Tovo |
| Langue principale | Français | — |
| Catégorie | Économie et entreprise / Shopping | — |

**Les deux identifiants diffèrent.** Ce n'est pas une erreur à corriger :
ce sont deux espaces de noms indépendants, et les deux sont déjà publiés.
Dans le projet Flutter, ils se configurent séparément :

- Android → `android/app/build.gradle` → `applicationId "com.unique.tovo.user"`
- iOS → `ios/Runner.xcodeproj` → `PRODUCT_BUNDLE_IDENTIFIER = com.tovoapp.UserApp`

Attention à la casse du côté iOS : `UserApp`, pas `userapp`.

Les deux valeurs sont vérifiées : l'iOS depuis App Store Connect, l'Android
depuis l'URL de la fiche publique —
`play.google.com/store/apps/details?id=com.unique.tovo.user`.

## Apps livreur et boutiquier

Ni l'une ni l'autre n'est publiée sur les stores — aucune contrainte de ce
côté. Mais leurs identifiants existent déjà dans le projet Firebase, hérités
de l'ancienne stack. On les reprend plutôt que d'en inventer :

| App | Identifiant | Publié |
|---|---|---|
| Tovo Livreur | `com.tovo.delivery` | non |
| Tovo Boutique | `com.tovo.store` | non |

L'intérêt est pratique : un seul `google-services.json`, celui du projet,
couvre les trois flavors Android. Créer de nouveaux identifiants aurait
imposé de déclarer deux applications Firebase supplémentaires pour rien.

## Firebase

Projet : **`tovoapp-4903b`** (« TovoApp »), forfait Blaze.
Compte de service : `firebase-adminsdk-j1xaf@tovoapp-4903b.iam.gserviceaccount.com`

Applications déclarées utiles au projet :

| Nom dans la console | Identifiant | Plateforme |
|---|---|---|
| tovo user new | `com.unique.tovo.user` | Android |
| tovo ios | `com.tovoapp.UserApp` | iOS |
| Tovo Delivery | `com.tovo.delivery` | Android |
| Tovo Store | `com.tovo.store` | Android |

Les autres entrées (`com.tovoapp.user` en Android et iOS, l'app Web) sont des
vestiges d'itérations antérieures. Les laisser ne coûte rien ; les supprimer
pourrait casser quelque chose qu'on ne connaît pas.

## Version publiée

- Version : **2.0.0**, build **4** (importé le 04/04/2025)
- Taille d'installation : 35,4 Mo

La prochaine version doit avoir un `versionCode` **strictement supérieur à
4** côté Android, et un numéro de build supérieur côté iOS. Dans Flutter,
`version: 2.1.0+5` dans `pubspec.yaml` couvre les deux.

## Contraintes techniques héritées

| Élément | Valeur actuelle | Conséquence |
|---|---|---|
| API minimale | 24 (Android 7.0) | à conserver ou relever, jamais abaisser |
| SDK cible | 34 | à relever selon l'exigence Play en vigueur |
| ABI | `arm64-v8a`, `armeabi-v7a`, `x86_64` | garder `armeabi-v7a` : beaucoup d'appareils d'entrée de gamme au Niger sont encore 32 bits |
| Pages mémoire 16 Ko | **non compatible** | voir ci-dessous |
| Localisations | 87 | on ne repart pas de là — français d'abord, langues locales ensuite |

### Le point 16 Ko

Le bundle actuel est marqué « non compatible avec les pages de 16 Ko ».
Google Play impose cette compatibilité aux applications ciblant les versions
récentes d'Android. À vérifier dans la Play Console **avant** de préparer la
soumission : si l'exigence est active, il faut des versions récentes du NDK
et du plugin Gradle Android, ce qui se règle dans la configuration Flutter —
mais mieux vaut le découvrir maintenant qu'au moment de publier.

## Signature Android — vérifié le 01/08/2026

**Play App Signing est actif.** Google détient la clé de signature
d'application, sur ses serveurs, hors d'atteinte de quiconque — y compris de
l'ancien prestataire. L'app ne peut donc pas être perdue.

Empreintes de la **clé de signature d'application** (certificats publics, à
enregistrer auprès de Firebase et de tout fournisseur d'API) :

```
SHA-1    F5:AF:C7:18:93:10:E8:34:3E:82:11:7A:A9:6C:B8:91:E2:96:D7:7E
SHA-256  D0:AB:82:4F:9F:44:C4:08:AD:65:24:FD:3F:0C:3E:DF:AD:C9:81:DB:1F:DF:DF:B1:82:DF:37:A9:A0:34:09:09
```

Empreintes de la **clé d'importation** (celle qui sert à téléverser un
build) :

```
SHA-1    7B:1E:1D:2B:F7:28:C1:FE:42:04:1B:6A:2E:73:19:EB:34:46:ED:82
SHA-256  B9:AB:82:D5:62:3B:6E:7B:2D:D0:79:7E:3D:24:48:83:D2:58:8D:CD:68:D6:F2:04:0F:E9:D5:05:6E:54:1F:2C
```

### Seul point ouvert : le keystore d'importation

Le fichier `.jks` correspondant à la clé d'importation, et ses mots de passe,
sont chez le prestataire. Deux issues :

1. Il les transmet — rien à faire de plus.
2. Il ne répond pas, ou les a perdus → Play Console → Protégé avec Play →
   Signature d'application → **« Demander la réinitialisation de la clé
   d'importation »**. On génère un nouveau keystore, on envoie le certificat,
   Google bascule sous 48 h. La clé de signature d'application, elle, ne
   change pas : les utilisateurs ne voient rien.

Le délai de 48 h est la seule raison de ne pas attendre le dernier moment.

Côté iOS, tant que le compte Apple Developer appartient à Mohamedine, les
certificats se régénèrent sans difficulté.

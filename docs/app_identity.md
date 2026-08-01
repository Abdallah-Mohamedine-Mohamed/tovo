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

## Ce qui reste à vérifier

**La clé de signature Android.** Une mise à jour doit être signée avec la
même clé que la version publiée. Sans elle, le package name ne sert à rien.

Play Console → Test et versions → Intégrité de l'application → Signature de
l'app.

- Si **Play App Signing** est activé, Google détient la clé et une
  réinitialisation de la clé d'upload est possible. Aucun risque.
- Sinon, il faut récupérer le keystore auprès du prestataire
  (`sanjayjangid1404`). À traiter tôt : c'est le seul point de ce document
  qui dépend d'un tiers.

Côté iOS, tant que le compte Apple Developer appartient à Mohamedine, les
certificats se régénèrent sans difficulté.

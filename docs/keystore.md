# Clé de signature Android — procédure complète

Deux clés existent, et les confondre est l'erreur la plus courante.

**La clé de signature d'application** est détenue par Google (Play App Signing
est actif sur ce compte). Elle signe ce que les utilisateurs installent. Elle
ne change jamais, on n'y touche pas, on ne peut pas la perdre.

**La clé d'importation** sert uniquement à téléverser un build vers la Play
Console. C'est celle-ci qui est chez l'ancien prestataire, et c'est celle-ci
qu'on remplace.

Réinitialiser la clé d'importation **n'a aucun effet visible** pour les
utilisateurs : ils continuent de recevoir des mises à jour signées par la
même clé de signature d'application.

---

## Prérequis

`keytool` est fourni avec le JDK. Sur cette machine il est déjà dans le PATH
(Eclipse Adoptium JDK 17). Vérification :

```powershell
keytool -help
```

Si la commande est introuvable, elle se trouve dans
`C:\Program Files\Android\Android Studio\jbr\bin\`.

---

## 1. Générer le keystore

```powershell
cd $env:USERPROFILE\tovo-keys
keytool -genkeypair -v -keystore tovo-upload.jks -storetype JKS -keyalg RSA -keysize 2048 -validity 10000 -alias upload
```

L'outil pose une série de questions :

| Question | Quoi répondre |
|---|---|
| Entrez le mot de passe du fichier de clés | **choisis-en un solide, note-le tout de suite** |
| Ressaisissez le nouveau mot de passe | le même |
| Quels sont vos nom et prénom ? | `Mohamedine` |
| Quel est le nom de votre unité organisationnelle ? | `Tovo` |
| Quel est le nom de votre organisation ? | `Tovo` |
| Quel est le nom de votre ville de résidence ? | `Niamey` |
| Quel est le nom de votre état ou province ? | `Niamey` |
| Quel est le code pays à deux lettres ? | `NE` |
| Est-ce correct ? | `oui` |
| Mot de passe de la clé (appuyez sur Entrée…) | **Entrée** — même mot de passe |

`-validity 10000` fait environ 27 ans. Google exige une validité qui dépasse
2033 ; ne descends pas en dessous.

**Ce fichier et son mot de passe sont irremplaçables.** Mets-les dans un
gestionnaire de mots de passe avant de continuer. Les perdre imposerait une
nouvelle demande de réinitialisation.

## 2. Vérifier

```powershell
keytool -list -v -keystore tovo-upload.jks -alias upload
```

Le mot de passe est demandé. La sortie doit afficher un bloc
`Empreintes du certificat` avec des lignes `SHA1:` et `SHA256:`.

## 3. Exporter le certificat pour Google

```powershell
keytool -export -rfc -keystore tovo-upload.jks -alias upload -file upload_certificate.pem
```

Le fichier obtenu doit commencer par `-----BEGIN CERTIFICATE-----`. C'est un
certificat **public** : contrairement au `.jks`, il n'est pas secret.

```powershell
Get-Content upload_certificate.pem -TotalCount 1
```

## 4. Demander la réinitialisation

Play Console → l'app **Tovo** → **Protégé avec Play** → section **Signature
d'application** → **Demander la réinitialisation de la clé d'importation**.

Le formulaire demande :

- **Motif** : « Clé d'importation perdue » (*Lost upload key*)
- **Certificat** : téléverser `upload_certificate.pem`

Google traite la demande sous 48 h ouvrées et confirme par e-mail. L'ancienne
clé d'importation devient alors inutilisable — c'est l'effet recherché.

## 5. Brancher la clé au projet

```powershell
Copy-Item mobile\android\key.properties.example mobile\android\key.properties
```

Puis renseigner, avec des **doubles antislashs** dans le chemin :

```properties
storeFile=C:\\Users\\abdal\\tovo-keys\\tovo-upload.jks
storePassword=<mot de passe>
keyAlias=upload
keyPassword=<mot de passe>
```

`key.properties`, `*.jks` et `*.keystore` sont exclus du dépôt par le
`.gitignore`.

## 6. Vérifier que la signature est prise en compte

```powershell
cd mobile
flutter build apk --release --flavor client -t lib/main_client.dart
```

Sans `key.properties`, la compilation retombe silencieusement sur la clé de
debug. Pour lever le doute :

```powershell
keytool -printcert -jarfile build\app\outputs\flutter-apk\app-client-release.apk
```

L'empreinte SHA-1 affichée doit correspondre à celle de `tovo-upload.jks`
(étape 2), et non à celle du keystore de debug.

---

## Sauvegarde

Trois choses à conserver ensemble, hors de la machine de développement :

1. `tovo-upload.jks`
2. son mot de passe
3. l'alias (`upload`)

Un gestionnaire de mots de passe qui accepte les pièces jointes convient. Le
dossier `~/tovo-keys` n'est pas une sauvegarde : un disque qui lâche emporte
tout.

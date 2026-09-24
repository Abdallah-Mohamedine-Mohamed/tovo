# Suivi iOS des commandes

Le client Flutter démarre une Live Activity quand la carte de suivi d'une commande active apparaît. Le serveur envoie les changements de statut par FCM, sans notification supplémentaire pour les étapes intermédiaires. La commande livrée ou annulée termine l'activité. La déconnexion la ferme aussi sur l'appareil.

Avant une release, sans Mac personnel :

1. Dans Apple Developer, activer Push Notifications pour `com.tovoapp.UserApp` et créer ou réutiliser une clé APNs `.p8`.
2. Dans le projet Firebase `tovoapp-4903b`, importer cette clé pour l'app iOS `com.tovoapp.UserApp` dans Cloud Messaging. Fournir aussi à Codemagic le fichier `GoogleService-Info.plist` de cette app, encodé en base64 dans la variable secrète `GOOGLE_SERVICE_INFO_PLIST_B64` du groupe `tovo_config`.
3. Dans Apple Developer, enregistrer l'identifiant de l'extension `com.tovoapp.UserApp.TovoOrderWidget`. Dans Codemagic, ajouter les profils App Store de l'app et de cette extension ; régénérer celui de l'app après l'activation des notifications.
4. Sur le serveur, configurer `FCM_SERVICE_ACCOUNT_JSON` avec le JSON d'un compte de service Firebase, et appliquer `supabase/migrations/0061_order_live_activities.sql`.
5. Lancer le workflow `ios-client-testflight` de `codemagic.yaml`. Tester une commande repas et une course de bout en bout sur un iPhone avec Dynamic Island : application ouverte, verrouillée, puis fermée. Sur les iPhone sans Dynamic Island, le suivi apparaît sur l'écran verrouillé. La fonction demande iOS 16.2 ou plus récent.

La mise à jour dépend du réseau et d'iOS ; elle suit les étapes importantes, pas la position GPS du livreur en continu.

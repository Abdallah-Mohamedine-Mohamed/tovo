import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    // Lit google-services.json et en fait les ressources dont Firebase a
    // besoin pour s'initialiser. Il choisit l'entrée correspondant à
    // l'applicationId du flavor compilé — d'où l'importance que les trois
    // identifiants figurent bien dans le fichier.
    id("com.google.gms.google-services")
}

// ----------------------------------------------------------------------
// Clé de signature
// ----------------------------------------------------------------------
// Les identifiants vivent dans android/key.properties, hors du dépôt.
// Un keystore ou son mot de passe versionné, c'est la capacité de publier
// une fausse mise à jour à tous les utilisateurs.
//
// Le fichier n'existe pas encore : la compilation retombe alors sur la clé
// de debug, ce qui permet de développer. Une release signée en debug est
// refusée par le Play Store — c'est voulu, mieux vaut un refus au dépôt
// qu'une mise à jour impossible à installer.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    // Le namespace est celui de l'app CLIENT publiée. Il ne doit pas changer :
    // voir docs/app_identity.md.
    namespace = "com.unique.tovo.user"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // minSdk 24 : c'est ce que cible l'app publiée. On ne l'abaisse pas,
        // et on ne le relève pas sans raison — au Niger, une part réelle du
        // parc tourne encore sur d'anciennes versions d'Android.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // armeabi-v7a conservé volontairement : beaucoup d'appareils
        // d'entrée de gamme sont encore 32 bits. Les retirer économiserait
        // quelques mégaoctets au prix d'une partie du marché.
        ndk {
            abiFilters.addAll(listOf("armeabi-v7a", "arm64-v8a", "x86_64"))
        }
    }

    // ------------------------------------------------------------------
    // Trois applications, une seule base de code.
    // ------------------------------------------------------------------
    // « client » reprend l'identifiant publié sur les stores.
    // « driver » et « merchant » reprennent ceux déjà déclarés dans le projet
    // Firebase : rien n'est publié de ce côté, mais réutiliser les
    // identifiants existants évite de créer deux apps Firebase de plus, et un
    // seul google-services.json couvre alors les trois flavors.
    flavorDimensions += "app"

    productFlavors {
        create("client") {
            dimension = "app"
            applicationId = "com.unique.tovo.user"
            resValue("string", "app_name", "Tovo")
        }
        create("driver") {
            dimension = "app"
            applicationId = "com.tovo.delivery"
            resValue("string", "app_name", "Tovo Livreur")
        }
        create("merchant") {
            dimension = "app"
            applicationId = "com.tovo.store"
            resValue("string", "app_name", "Tovo Boutique")
        }
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                // Pas de keystore : on signe en debug pour que
                // `flutter build --release` reste possible en local. Le Play
                // Store refusera ce binaire, et c'est très bien ainsi.
                signingConfigs.getByName("debug")
            }
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }
}

flutter {
    source = "../.."
}

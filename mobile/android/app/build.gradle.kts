plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
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

    buildTypes {
        release {
            // TODO — signature de production.
            // L'app client DOIT être signée avec la clé de la version déjà
            // publiée, sinon la mise à jour est refusée par le Play Store.
            // Voir docs/app_identity.md § clé de signature.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}

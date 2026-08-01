# Flutter et les plugins gèrent leur propre obfuscation.
# Règles minimales pour éviter que R8 ne retire ce dont on a besoin.

-keep class io.flutter.** { *; }
-keep class com.google.firebase.** { *; }

# Les modèles sérialisés en JSON traversent des réflexions côté plugins.
-keepattributes Signature
-keepattributes *Annotation*

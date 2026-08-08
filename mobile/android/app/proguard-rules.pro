# Flutter et les plugins gèrent leur propre obfuscation.
# Règles minimales pour éviter que R8 ne retire ce dont on a besoin.

-keep class io.flutter.** { *; }
-keep class com.google.firebase.** { *; }

# Les modèles sérialisés en JSON traversent des réflexions côté plugins.
-keepattributes Signature
-keepattributes *Annotation*

# ---------------------------------------------------------------------
# Play Feature Delivery — référencé par Flutter, jamais utilisé par Tovo.
#
# Le moteur Flutter embarque de quoi télécharger des modules à la demande.
# R8 voit ces références, ne trouve pas la bibliothèque Play Core, et refuse
# de compiler la release — alors que ce code ne s'exécutera jamais : Tovo est
# livrée d'un bloc, sans module différé.
#
# On ne fait donc PAS entrer `com.google.android.play:core` : ce serait
# ajouter une dépendance, du poids et une surface d'attaque pour taire un
# avertissement sur du code mort.
-dontwarn com.google.android.play.core.**

# ---------------------------------------------------------------------
# Plugins natifs joints par réflexion.
#
# Ces classes sont atteintes depuis Dart par les canaux de méthode, jamais
# par un appel Java direct : R8 ne voit aucun chemin vers elles et peut les
# retirer. L'app compile alors, s'installe, et échoue au premier usage — le
# micro qui ne démarre pas, la position qui ne vient jamais. Un défaut qui
# n'existe qu'en release, donc qu'on découvre après publication.
-keep class com.llfbandit.record.** { *; }
-keep class com.baseflow.geolocator.** { *; }
-keep class io.flutter.plugins.imagepicker.** { *; }

# Sans ces attributs, une trace d'erreur en production devient une suite de
# lettres et le journal ne sert plus à rien.
-keepattributes SourceFile,LineNumberTable

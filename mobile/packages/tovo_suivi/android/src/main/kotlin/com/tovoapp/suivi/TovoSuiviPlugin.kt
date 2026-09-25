package com.tovoapp.suivi

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.BitmapFactory
import android.graphics.drawable.Icon
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.core.app.NotificationCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Le suivi de commande sur Android.
 *
 * UNE notification par commande, mise à jour SUR PLACE à chaque étape (même
 * identifiant) : jamais une pile de notifications. Elle montre la phrase de
 * l'étape, l'étape en un mot, une barre de progression et le temps écoulé
 * depuis la commande, qu'Android fait défiler tout seul (chronomètre).
 *
 * Sur Android 16 et plus, elle devient une « Live Update » : ProgressStyle
 * en 4 segments avec le scooter qui avance dessus, et promotion — pastille
 * dans la barre d'état, en tête des notifications, sur l'écran verrouillé
 * (la « Now Bar » chez Samsung). L'équivalent Android de la Dynamic Island.
 *
 * Le module est un plugin (et non du code de l'activité) pour être présent
 * aussi dans le moteur d'arrière-plan de Firebase : la notification se met à
 * jour app fermée, à la réception du message du serveur.
 */
class TovoSuiviPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
  private lateinit var canal: MethodChannel
  private lateinit var contexte: Context

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    contexte = binding.applicationContext
    canal = MethodChannel(binding.binaryMessenger, "tovo/suivi")
    canal.setMethodCallHandler(this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    canal.setMethodCallHandler(null)
  }

  override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
    try {
      when (call.method) {
        "afficher" -> {
          val arguments = call.arguments as? Map<*, *>
          if (arguments == null) {
            result.error("arguments", "suivi sans données", null)
          } else {
            Suivi.afficher(contexte, arguments)
            result.success(true)
          }
        }
        "retirer" -> {
          Suivi.retirer(contexte, call.argument<String>("id").orEmpty())
          result.success(true)
        }
        "liveUpdates" -> result.success(Build.VERSION.SDK_INT >= 36)
        else -> result.notImplemented()
      }
    } catch (cause: Exception) {
      result.error("suivi", cause.message, null)
    }
  }
}

internal object Suivi {
  private const val CANAL = "tovo_suivi_commande"
  private const val ETIQUETTE = "tovo_suivi"
  private const val ECHELLE = 1000
  private const val SEGMENTS = 4
  private const val VERT = 0xFF006666.toInt()
  private const val GRIS = 0xFFBDBDBD.toInt()

  /** Notification.EXTRA_REQUEST_PROMOTED_ONGOING (Android 16). */
  private const val DEMANDE_PROMOTION = "android.requestPromotedOngoing"

  /** Les illustrations 3D, les mêmes que sur iPhone. */
  private val illustrations = mapOf(
    "acceptee" to R.drawable.suivi_acceptee,
    "annule" to R.drawable.suivi_annule,
    "arrivee" to R.drawable.suivi_arrivee,
    "attente" to R.drawable.suivi_attente,
    "colis" to R.drawable.suivi_colis,
    "cuisine" to R.drawable.suivi_cuisine,
    "maison" to R.drawable.suivi_maison,
    "recherche" to R.drawable.suivi_recherche,
    "repas" to R.drawable.suivi_repas,
    "scooter" to R.drawable.suivi_scooter,
  )

  fun afficher(ctx: Context, a: Map<*, *>) {
    val id = (a["id"] as? String).orEmpty()
    if (id.isEmpty()) return
    val phrase = (a["phrase"] as? String).orEmpty()
    val etape = (a["etape"] as? String).orEmpty()
    val court = (a["court"] as? String).orEmpty()
    val image = illustrations[a["image"] as? String] ?: R.drawable.suivi_scooter
    val index = (a["index"] as? Number)?.toInt() ?: 0
    val debut = (a["debut"] as? Number)?.toLong() ?: System.currentTimeMillis()
    val fin = (a["fin"] as? Number)?.toLong() ?: (debut + 40 * 60_000L)
    val fini = a["fini"] == true
    val annule = a["annule"] == true
    val alerte = a["alerte"] == true

    creerCanal(ctx)
    val valeur = progression(index, debut, fin, fini)
    val ouvrir = ouverture(ctx, id)
    val notification = if (Build.VERSION.SDK_INT >= 36) {
      liveUpdate(ctx, phrase, etape, court, image, valeur, debut, fini, annule, alerte, ouvrir)
    } else {
      classique(ctx, phrase, etape, image, valeur, debut, fini, alerte, ouvrir)
    }
    val gestionnaire = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    try {
      gestionnaire.notify(ETIQUETTE, id.hashCode(), notification)
    } catch (_: SecurityException) {
      // Notifications refusées par l'utilisateur : rien à afficher.
    }
  }

  fun retirer(ctx: Context, id: String) {
    if (id.isEmpty()) return
    val gestionnaire = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    gestionnaire.cancel(ETIQUETTE, id.hashCode())
  }

  /**
   * La position sur la barre : le temps écoulé rapporté à l'arrivée
   * prévue, tenu dans le segment de l'étape en cours — la barre ne court
   * jamais devant l'étape réelle, ni ne recule.
   */
  private fun progression(index: Int, debut: Long, fin: Long, fini: Boolean): Int {
    if (fini) return ECHELLE
    val segment = ECHELLE / SEGMENTS
    val total = (fin - debut).coerceAtLeast(60_000L)
    val fait = ((System.currentTimeMillis() - debut).toDouble() / total).coerceIn(0.0, 1.0)
    val bas = index.coerceIn(0, SEGMENTS - 1) * segment + 12
    val haut = (index.coerceIn(0, SEGMENTS - 1) + 1) * segment - 12
    return (fait * ECHELLE).toInt().coerceIn(bas, haut)
  }

  private fun ouverture(ctx: Context, id: String): PendingIntent? {
    val intent = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: return null
    intent.putExtra("order_id", id)
    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
    return PendingIntent.getActivity(
      ctx,
      id.hashCode(),
      intent,
      PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )
  }

  private fun creerCanal(ctx: Context) {
    if (Build.VERSION.SDK_INT < 26) return
    val gestionnaire = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
    if (gestionnaire.getNotificationChannel(CANAL) != null) return
    // Importance haute : une étape qui compte s'affiche en bannière. Les
    // mises à jour silencieuses (le temps, les étapes mineures) ne sonnent
    // pas : elles sont marquées « silencieuses » une à une.
    val canal = NotificationChannel(CANAL, "Suivi de commande", NotificationManager.IMPORTANCE_HIGH)
    canal.description = "Où en est votre commande, en direct."
    canal.setShowBadge(false)
    gestionnaire.createNotificationChannel(canal)
  }

  /** Android 16 et plus : la Live Update. */
  @RequiresApi(36)
  private fun liveUpdate(
    ctx: Context,
    phrase: String,
    etape: String,
    court: String,
    image: Int,
    valeur: Int,
    debut: Long,
    fini: Boolean,
    annule: Boolean,
    alerte: Boolean,
    ouvrir: PendingIntent?,
  ): Notification {
    val segment = ECHELLE / SEGMENTS
    val style = Notification.ProgressStyle()
      .setStyledByProgress(true)
      .setProgressSegments(
        List(SEGMENTS) { Notification.ProgressStyle.Segment(segment).setColor(if (annule) GRIS else VERT) },
      )
      .setProgressPoints(
        List(SEGMENTS - 1) { i -> Notification.ProgressStyle.Point((i + 1) * segment).setColor(VERT) },
      )
      .setProgress(valeur)
      // Le petit scooter qui avance sur la barre.
      .setProgressTrackerIcon(Icon.createWithResource(ctx, R.drawable.suivi_scooter_mini))

    val builder = Notification.Builder(ctx, CANAL)
      .setSmallIcon(R.drawable.ic_suivi)
      .setContentTitle(phrase)
      .setContentText(etape)
      .setLargeIcon(Icon.createWithResource(ctx, image))
      .setStyle(style)
      .setColor(VERT)
      .setCategory(Notification.CATEGORY_PROGRESS)
      .setOnlyAlertOnce(!alerte)
    // Une mise à jour silencieuse (le temps, une étape mineure) ne sonne
    // pas : l'API native n'a pas de « silencieux », on passe par le groupe —
    // un membre de groupe qui laisse l'alerte au résumé reste muet.
    if (!alerte) {
      builder
        .setGroup("tovo_suivi_silencieux")
        .setGroupAlertBehavior(Notification.GROUP_ALERT_SUMMARY)
    }
    if (ouvrir != null) builder.setContentIntent(ouvrir)
    if (fini) {
      builder
        .setAutoCancel(true)
        .setTimeoutAfter(20 * 60_000L)
        .setShowWhen(false)
      if (court.isNotEmpty()) builder.setShortCriticalText(court)
    } else {
      builder
        .setOngoing(true)
        // La pastille de la barre d'état et la notification montrent le
        // temps écoulé depuis la commande, qui défile tout seul.
        .setUsesChronometer(true)
        .setWhen(debut)
        .setShowWhen(true)
      // La demande de promotion (Live Update). Posée par sa clé : la
      // méthode setRequestPromotedOngoing n'existe pas dans toutes les
      // révisions du SDK 36, la clé si.
      builder.extras.putBoolean(DEMANDE_PROMOTION, true)
    }
    return builder.build()
  }

  /** Android 15 et avant : une notification de suivi unique et permanente. */
  private fun classique(
    ctx: Context,
    phrase: String,
    etape: String,
    image: Int,
    valeur: Int,
    debut: Long,
    fini: Boolean,
    alerte: Boolean,
    ouvrir: PendingIntent?,
  ): Notification {
    val builder = NotificationCompat.Builder(ctx, CANAL)
      .setSmallIcon(R.drawable.ic_suivi)
      .setContentTitle(phrase)
      .setContentText(etape)
      .setLargeIcon(BitmapFactory.decodeResource(ctx.resources, image))
      .setColor(VERT)
      .setCategory(NotificationCompat.CATEGORY_PROGRESS)
      .setPriority(if (alerte) NotificationCompat.PRIORITY_HIGH else NotificationCompat.PRIORITY_DEFAULT)
      .setOnlyAlertOnce(!alerte)
      .setSilent(!alerte)
      .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
    if (ouvrir != null) builder.setContentIntent(ouvrir)
    if (fini) {
      builder
        .setAutoCancel(true)
        .setTimeoutAfter(20 * 60_000L)
        .setShowWhen(false)
    } else {
      builder
        .setOngoing(true)
        .setProgress(ECHELLE, valeur, false)
        .setUsesChronometer(true)
        .setWhen(debut)
        .setShowWhen(true)
    }
    return builder.build()
  }
}

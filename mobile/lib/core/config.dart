/// Configuration d'exécution.
///
/// Les valeurs arrivent par `--dart-define` plutôt que par un fichier
/// d'assets : un `.env` embarqué dans un APK est lisible par quiconque le
/// décompresse. Ici, rien de secret ne doit figurer — la clé publishable de
/// Supabase est faite pour être distribuée, la RLS fait le travail.
///
/// Exemple :
///   flutter run --flavor client -t lib/main_client.dart \
///     --dart-define=SUPABASE_URL=https://xxx.supabase.co \
///     --dart-define=SUPABASE_ANON_KEY=sb_publishable_... \
///     --dart-define=API_BASE_URL=https://tovo.up.railway.app
class TovoConfig {
  const TovoConfig._();

  static const String supabaseUrl = String.fromEnvironment('SUPABASE_URL');
  static const String supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

  /// Backend Tovo. En développement sur émulateur Android, `localhost`
  /// désigne l'émulateur lui-même : utiliser 10.0.2.2 pour joindre la
  /// machine hôte.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://10.0.2.2:3000',
  );

  /// Version du contrat UI comprise par ce client. Envoyée au backend, qui
  /// n'émet que des composants supportés par cette version.
  static const int contractVersion = 1;

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseAnonKey.isNotEmpty;

  /// Message d'erreur explicite plutôt qu'un écran blanc au démarrage.
  static String get configurationError =>
      'Configuration manquante. Lancez avec --dart-define=SUPABASE_URL=... '
      'et --dart-define=SUPABASE_ANON_KEY=...';
}

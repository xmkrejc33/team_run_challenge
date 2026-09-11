import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'screens/auth_screen.dart';
import 'screens/dashboard_screen.dart';

const String kSupabaseUrl = 'https://xfnfzgragzlwhefniawp.supabase.co';
const String kSupabasePublishableKey =
  'sb_publishable_3BzkICJSF9v52DDBZwPcrg_Zyi_JgJi';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Inicializace Supabase s poskytnutými URL a klíčem
  await Supabase.initialize(
    url: kSupabaseUrl,
    publishableKey: kSupabasePublishableKey,
  );

  // Spuštění aplikace TeamChallengeApp
  runApp(const TeamChallengeApp());
}

class TeamChallengeApp extends StatelessWidget {
  const TeamChallengeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Týmová Výzva',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        useMaterial3: true,
      ),
      // Nastavení domovského widgetu na AuthScreen, pokud uživatel není přihlášen, jinak ChallengeDashboard
      home: Supabase.instance.client.auth.currentUser == null
          ? const AuthScreen()
          : const ChallengeDashboard(syncOnStart: true),
    );
  }
}

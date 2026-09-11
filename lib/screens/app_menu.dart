import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'dashboard_screen.dart';
import 'auth_screen.dart';
import 'challenges_screen.dart';
import 'profile_screen.dart';
import 'settings_screen.dart';
import 'teams_screen.dart';

Widget buildBackToDashboardButton(BuildContext context) {
  return IconButton(
    icon: const Icon(Icons.arrow_back, color: Colors.white),
    onPressed: () {
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const ChallengeDashboard()),
        (route) => false,
      );
    },
  );
}

// Funkce pro vytvoření menu s možnostmi
Widget buildAppMenu(BuildContext context) {
  return PopupMenuButton<String>(
    icon: const Icon(Icons.more_vert, color: Colors.white),
    onSelected: (value) async {
      final supabase = Supabase.instance.client;
      switch (value) {
        case 'challenges':
          Navigator.push(context, MaterialPageRoute(builder: (_) => const ChallengesScreen()));
          break;
        case 'teams':
          Navigator.push(context, MaterialPageRoute(builder: (_) => const TeamsScreen()));
          break;
        case 'settings':
          Navigator.push(context, MaterialPageRoute(builder: (_) => const SettingsScreen()));
          break;
        case 'profile':
          Navigator.push(context, MaterialPageRoute(builder: (_) => const ProfileScreen()));
          break;
        case 'logout':
          await supabase.auth.signOut();
          if (context.mounted) {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (context) => const AuthScreen()),
              (route) => false,
            );
          }
          break;
      }
    },
    itemBuilder: (context) => const [
      PopupMenuItem(value: 'teams', child: Text('Týmy')),
      PopupMenuItem(value: 'challenges', child: Text('Výzvy')),
      PopupMenuItem(value: 'profile', child: Text('Profil')),
      PopupMenuItem(value: 'settings', child: Text('Nastavení')),
      PopupMenuItem(value: 'logout', child: Text('Odhlásit se')),
    ],
  );
}

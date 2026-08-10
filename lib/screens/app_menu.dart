import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';
import 'dashboard_screen.dart';
import 'auth_screen.dart';
import 'challenges_screen.dart';
import 'teams_screen.dart';

// Třída pro nastavení profilu uživatele
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

// Stavová třída pro nastavení profilu uživatele
class _SettingsScreenState extends State<SettingsScreen> {
  final _supabase = Supabase.instance.client;
  final _nameController = TextEditingController();
  String? _avatarBase64;
  bool _isLoading = true;
  List<Map<String, dynamic>> _availableTeams = [];
  int? _selectedTeamId;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  // Metoda pro načtení dat uživatele a týmů
  Future<void> _loadData() async {
    final user = _supabase.auth.currentUser;
    if (user != null) {
      final metadata = user.userMetadata ?? {};
      _nameController.text = metadata['runner_name'] ?? '';
      _avatarBase64 = metadata['avatar_base64']?.toString();
      _selectedTeamId = metadata['team_id'] is int ? metadata['team_id'] : int.tryParse(metadata['team_id']?.toString() ?? '');
    }
    final teams = await SupabaseService.loadTeamsSafe();
    setState(() { _availableTeams = teams; _isLoading = false; });
  }

  // Metoda pro uložení změn v profilu uživatele
  Future<void> _saveProfile() async {
    try {
      final selectedTeam = _availableTeams.firstWhere((t) => t['id'] == _selectedTeamId);
      await _supabase.auth.updateUser(UserAttributes(data: {
        'runner_name': _nameController.text.trim(),
        'avatar_base64': _avatarBase64,
        'team_id': _selectedTeamId,
        'team_name': selectedTeam['name'],
      }));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Profil uložen.')));
    } catch (e) { debugPrint(e.toString()); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profil'), backgroundColor: Colors.orange,
        leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const ChallengeDashboard()), (r) => false)),
        actions: [buildAppMenu(context)],
      ),
      body: _isLoading ? const Center(child: CircularProgressIndicator()) : SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          CircleAvatar(radius: 46, backgroundImage: _avatarBase64 != null ? MemoryImage(base64Decode(_avatarBase64!)) : null, child: _avatarBase64 == null ? const Icon(Icons.person, size: 46) : null),
          const SizedBox(height: 16),
          TextField(controller: _nameController, decoration: const InputDecoration(labelText: 'Jméno', border: OutlineInputBorder())),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _selectedTeamId,
            items: _availableTeams.map((t) => DropdownMenuItem<int>(value: t['id'] as int, child: Text(t['name']))).toList(),
            onChanged: (v) => setState(() => _selectedTeamId = v),
            decoration: const InputDecoration(labelText: 'Tým', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          ElevatedButton(onPressed: _saveProfile, style: ElevatedButton.styleFrom(backgroundColor: Colors.orange), child: const Text('Uložit změny')),
        ]),
      ),
    );
  }
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
      PopupMenuItem(value: 'settings', child: Text('Profil')),
      PopupMenuItem(value: 'logout', child: Text('Odhlásit se')),
    ],
  );
}

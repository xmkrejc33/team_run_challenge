import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';
import '../utils/helpers.dart';
import 'dashboard_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _isSignUp = false;
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nameController = TextEditingController();

  List<Map<String, dynamic>> _availableTeams = [];
  bool _isLoadingTeams = true;
  int? _selectedTeamId;

  final _supabase = Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _fetchTeamsFromDatabase();
  }

  Future<void> _fetchTeamsFromDatabase() async {
    try {
      final data = await SupabaseService.loadTeamsSafe(ascending: true);
      setState(() {
        _availableTeams = data;
        if (_availableTeams.isNotEmpty) {
          _selectedTeamId = _availableTeams.first['id'] as int;
        }
        _isLoadingTeams = false;
      });
    } catch (e) {
      debugPrint(formatBackendError(e, context: 'Chyba při načítání týmů z DB'));
      setState(() => _isLoadingTeams = false);
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _submit() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final name = _nameController.text.trim();

    if (email.isEmpty || password.isEmpty) return;

    try {
      if (_isSignUp) {
        if (_selectedTeamId == null) return;

        final selectedTeam = _availableTeams.firstWhere((t) => t['id'] == _selectedTeamId);
        final String teamName = selectedTeam['name'] ?? 'Neznámý tým';
        final String runnerName = name.isEmpty ? 'Anonymní běžec' : name;

        final response = await _supabase.auth.signUp(
          email: email,
          password: password,
          data: {
            'runner_name': runnerName,
            'team_id': _selectedTeamId,
            'team_name': teamName,
          },
        );

        final userId = response.user?.id;
        if (userId != null) {
          try {
            final existing = await _supabase.from('team_members').select('id').eq('team_id', _selectedTeamId as int).eq('user_id', userId).limit(1);
            if ((existing as List).isEmpty) {
              await _supabase.from('team_members').insert({
                'team_id': _selectedTeamId,
                'user_id': userId,
                'runner_name': runnerName,
              });
            } else {
              await _supabase.from('team_members').update({'runner_name': runnerName}).eq('team_id', _selectedTeamId as int).eq('user_id', userId);
            }
          } catch (e) {
            debugPrint('team_members při registraci přeskočeno: $e');
          }
        }
      } else {
        await _supabase.auth.signInWithPassword(email: email, password: password);
      }

      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => const ChallengeDashboard(syncOnStart: true)),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Chyba: ${e.toString()}'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isSignUp ? 'Registrace do Výzvy' : 'Přihlášení'), backgroundColor: Colors.orange),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: Card(
            elevation: 4,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(controller: _emailController, decoration: const InputDecoration(labelText: 'E-mail', border: OutlineInputBorder()), keyboardType: TextInputType.emailAddress),
                  const SizedBox(height: 12),
                  TextField(controller: _passwordController, decoration: const InputDecoration(labelText: 'Heslo', border: OutlineInputBorder()), obscureText: true),
                  if (_isSignUp) ...[
                    const SizedBox(height: 12),
                    TextField(controller: _nameController, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Vaše jméno', border: OutlineInputBorder())),
                    const SizedBox(height: 16),
                    const Align(alignment: Alignment.centerLeft, child: Padding(padding: EdgeInsets.only(bottom: 8.0), child: Text('Vyberte svůj tým:', style: TextStyle(fontWeight: FontWeight.bold)))),
                    _isLoadingTeams
                        ? const CircularProgressIndicator()
                        : _availableTeams.isEmpty
                            ? const Text('V databázi nebyly nalezeny žádné týmy.', style: TextStyle(color: Colors.red))
                            : DropdownButtonFormField<int>(
                                initialValue: _selectedTeamId,
                                decoration: const InputDecoration(labelText: 'Vyberte svůj tým', border: OutlineInputBorder()),
                                items: _availableTeams.map((team) => DropdownMenuItem<int>(value: team['id'] as int, child: Text(team['name'] ?? 'Tým'))).toList(),
                                onChanged: (value) => setState(() => _selectedTeamId = value),
                              ),
                  ],
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, minimumSize: const Size.fromHeight(45)),
                    child: Text(_isSignUp ? 'Zaregistrovat se' : 'Přihlást se', style: const TextStyle(color: Colors.white)),
                  ),
                  TextButton(onPressed: () => setState(() => _isSignUp = !_isSignUp), child: Text(_isSignUp ? 'Už máte účet? Přihlaste se' : 'Nemáte účet? Zaregistrujte se')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

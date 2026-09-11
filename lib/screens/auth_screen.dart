import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';
import '../utils/helpers.dart';
import 'dashboard_screen.dart';

// Třída pro přihlášení nebo registraci uživatele
class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

// Stavová třída pro přihlášení nebo registraci uživatele
class _AuthScreenState extends State<AuthScreen> {
  bool _isSignUp = false; // Indikuje, zda se jedná o registraci nebo přihlášení
  final _emailController = TextEditingController(); // Kontroler pro vstup e-mailu
  final _passwordController = TextEditingController(); // Kontroler pro vstup hesla
  final _nameController = TextEditingController(); // Kontroler pro vstup jména (pouze při registraci)

  List<Map<String, dynamic>> _availableTeams = []; // Seznam dostupných týmů
  bool _isLoadingTeams = true; // Indikuje, zda se načítávají týmy
  int? _selectedTeamId; // Vybraný tým (pouze při registraci)

  final _supabase = Supabase.instance.client; // Instance Supabase klienta

  @override
  void initState() {
    super.initState();
    _fetchTeamsFromDatabase(); // Načítá dostupné týmy ze databáze
  }

  // Metoda pro načtení dostupných týmů ze databáze
  Future<void> _fetchTeamsFromDatabase() async {
    try {
      final data = await SupabaseService.loadTeamsSafe(ascending: true); // Načítá týmy ze databáze
      setState(() {
        _availableTeams = data; // Nastaví dostupné týmy
        if (_availableTeams.isNotEmpty) {
          _selectedTeamId = _availableTeams.first['id'] as int; // Vybere první dostupný tým jako výchozí
        }
        _isLoadingTeams = false; // Označí, že se načítání ukončilo
      });
    } catch (e) {
      debugPrint(formatBackendError(e, context: 'Chyba při načítání týmů z DB')); // Vypíše chybu
      setState(() => _isLoadingTeams = false); // Označí, že se načítání ukončilo s chybou
    }
  }

  @override
  void dispose() {
    _emailController.dispose(); // Uvolní kontroler e-mailu
    _passwordController.dispose(); // Uvolní kontroler hesla
    _nameController.dispose(); // Uvolní kontroler jména (pouze při registraci)
    super.dispose();
  }

  // Metoda pro odeslání formuláře (registrace nebo přihlášení)
  void _submit() async {
    final email = _emailController.text.trim(); // Získá e-mail z kontroleru
    final password = _passwordController.text.trim(); // Získá heslo z kontroleru
    final name = _nameController.text.trim(); // Získá jméno z kontroleru (pouze při registraci)

    if (email.isEmpty || password.isEmpty) return; // Pokud je e-mail nebo heslo prázdné, ukončí metodu

    try {
      if (_isSignUp) { // Pokud se jedná o registraci
        if (_selectedTeamId == null) return; // Pokud není vybrán žádný tým, ukončí metodu

        final selectedTeam = _availableTeams.firstWhere((t) => t['id'] == _selectedTeamId); // Získá vybraný tým
        final String teamName = selectedTeam['name'] ?? 'Neznámý tým'; // Nastaví název týmu
        final String runnerName = name.isEmpty ? 'Anonymní běžec' : name; // Nastaví jméno uživatele

        final response = await _supabase.auth.signUp( // Registrováje uživatele
          email: email,
          password: password,
          data: {
            'runner_name': runnerName, // Přidá jméno uživatele do metadat
            'team_id': _selectedTeamId, // Přidá ID týmu do metadat
            'team_name': teamName, // Přidá název týmu do metadat
          },
        );

        final userId = response.user?.id; // Získá ID uživatele
        if (userId != null) { // Pokud je ID uživatele platné
          try {
            await _supabase.from('profiles').upsert({
              'user_id': userId,
              'runner_name': runnerName,
              'team_id': _selectedTeamId,
              'team_name': teamName,
            }, onConflict: 'user_id');
          } catch (e) {
                debugPrint('profiles při registraci přeskočeno: $e'); // Vypíše chybu
          }
        }
      } else { // Pokud se jedná o přihlášení
        await _supabase.auth.signInWithPassword(email: email, password: password); // Přihlásí uživatele
      }

      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (context) => const ChallengeDashboard(syncOnStart: true)), // Přesměruje na domovskou stránku po úspěšném přihlášení nebo registraci
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Chyba: ${e.toString()}'), backgroundColor: Colors.red), // Vypíše chybu uživateli
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isSignUp ? 'Registrace do Výzvy' : 'Přihlášení'), backgroundColor: Colors.orange), // Nastaví titulek stránky
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0), // Přidá odsazování k obsahu
          child: Card(
            elevation: 4, // Nastaví stíhání kartičky
            child: Padding(
              padding: const EdgeInsets.all(16.0), // Přidá odsazování k obsahu kartičky
              child: Column(
                mainAxisSize: MainAxisSize.min, // Nastaví výšku sloupce na minimální
                children: [
                  TextField(controller: _emailController, decoration: const InputDecoration(labelText: 'E-mail', border: OutlineInputBorder()), keyboardType: TextInputType.emailAddress), // Přidá pole pro e-mail
                  const SizedBox(height: 12), // Přidá mezery mezi poli
                  TextField(controller: _passwordController, decoration: const InputDecoration(labelText: 'Heslo', border: OutlineInputBorder()), obscureText: true), // Přidá pole pro heslo
                  if (_isSignUp) ...[
                    const SizedBox(height: 12), // Přidá mezery mezi poli
                    TextField(controller: _nameController, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Vaše jméno', border: OutlineInputBorder())), // Přidá pole pro jméno (pouze při registraci)
                    const SizedBox(height: 16), // Přidá mezery mezi poli
                    const Align(alignment: Alignment.centerLeft, child: Padding(padding: EdgeInsets.only(bottom: 8.0), child: Text('Vyberte svůj tým:', style: TextStyle(fontWeight: FontWeight.bold)))), // Přidá text pro výběr týmu (pouze při registraci)
                    _isLoadingTeams
                        ? const CircularProgressIndicator() // Zobrazí indikátor načítání, pokud se načítávají týmy
                        : _availableTeams.isEmpty
                            ? const Text('V databázi nebyly nalezeny žádné týmy.', style: TextStyle(color: Colors.red)) // Zobrazí text, pokud není žádný tým dostupný
                            : DropdownButtonFormField<int>(
                                initialValue: _selectedTeamId,
                                decoration: const InputDecoration(labelText: 'Vyberte svůj tým', border: OutlineInputBorder()), // Přidá pole pro výběr týmu (pouze při registraci)
                                items: _availableTeams.map((team) => DropdownMenuItem<int>(value: team['id'] as int, child: Text(team['name'] ?? 'Tým'))).toList(), // Vygeneruje položky pro výběr týmu (pouze při registraci)
                                onChanged: (value) => setState(() => _selectedTeamId = value), // Nastaví vybraný tým
                              ),
                  ],
                  const SizedBox(height: 20), // Přidá mezery mezi poli
                  ElevatedButton(
                    onPressed: _submit, // Nastaví akci při stisknutí tlačítka
                    style: ElevatedButton.styleFrom(backgroundColor: Colors.orange, minimumSize: const Size.fromHeight(45)), // Nastaví styl tlačítka
                    child: Text(_isSignUp ? 'Zaregistrovat se' : 'Přihlásit se', style: const TextStyle(color: Colors.white)), // Zobrazí text na tlačítku (pouze při registraci nebo přihlášení)
                  ),
                  TextButton(onPressed: () => setState(() => _isSignUp = !_isSignUp), child: Text(_isSignUp ? 'Už máte účet? Přihlaste se' : 'Nemáte účet? Zaregistrujte se')), // Přidá tlačítko pro přepnutí mezi registrací a přihlášením
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

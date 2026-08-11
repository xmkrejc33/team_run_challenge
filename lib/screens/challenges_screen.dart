import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';
import '../utils/helpers.dart';
import 'app_menu.dart';

// Třída pro zobrazení seznamu výzv a jejich stavů
class ChallengesScreen extends StatefulWidget {
  const ChallengesScreen({super.key});

  @override
  State<ChallengesScreen> createState() => _ChallengesScreenState();
}

// Stavová třída pro zobrazení seznamu výzv a jejich stavů
class _ChallengesScreenState extends State<ChallengesScreen> {
  final _supabase = Supabase.instance.client; // Instance Supabase klienta
  bool _isLoading = true; // Indikuje, zda se načítávají výzvy
  String? _loadError; // Chyba při načítání výzv
  List<Map<String, dynamic>> _challenges = []; // Seznam výzv
  Map<int, bool> _challengeCompleted = {}; // Stavové informace o dokončení výzv

  @override
  void initState() {
    super.initState();
    _loadData(); // Načítá data po inicializaci widgetu
  }

  // Metoda pro načtení dat ze Supabase
  Future<void> _loadData() async {
    try {
      final challengeList = await SupabaseService.loadChallengesSafe(ascending: true); // Načítá výzvy ze databáze
      final activities = await SupabaseService.loadActivitiesSafe(ascending: false); // Načítá aktivity ze databáze
      final completedMap = _buildChallengeCompletionMap(challengeList, activities); // Vytvoří mapu s informacemi o dokončení výzv
      await _syncChallengeStatus(challengeList, completedMap); // Synchronizuje stav výzv

      setState(() {
        _challenges = challengeList; // Nastaví seznam výzv
        _challengeCompleted = completedMap; // Nastaví mapu s informacemi o dokončení výzv
        _isLoading = false; // Označí, že se načítání ukončilo
      });
    } catch (e) {
      setState(() { _loadError = formatBackendError(e); _isLoading = false; }); // Zpracuje chybu při načítání dat
    }
  }

  // Metoda pro vytvoření mapy s informacemi o dokončení výzv
  Map<int, bool> _buildChallengeCompletionMap(List<Map<String, dynamic>> challenges, List<Map<String, dynamic>> activities) {
    final map = <int, bool>{};
    for (var c in challenges) {
      final id = c['id'] as int; // ID výzvy
      final teams = parseCsvLowerSet(c['team_names'] ?? ''); // Seznam týmů pro danou výzvu
      final start = DateTime.tryParse(c['start_date'] ?? '')?.toLocal(); // Datum začátku výzvy
      final target = (c['distance'] as num?)?.toDouble() ?? 0.0; // Cílová vzdálenost pro danou výzvu
      final kmMap = { for (var t in teams) t: 0.0 }; // Mapa s aktuálními vzdálenostmi pro každý tým

      for (var a in activities) {
        final tName = (a['team_name'] ?? '').toString().trim().toLowerCase(); // Název týmu ze aktivity
        if (!teams.contains(tName)) continue; // Ignoruje aktivitu, pokud neleží do daného týmu
        final aTime = DateTime.tryParse((a['start_time'] ?? a['created_at'] ?? '').toString())?.toLocal(); // Datum začátku aktivity
        if (start != null && aTime != null && aTime.isBefore(start)) continue; // Ignoruje aktivitu, pokud je před začátkem výzvy
        kmMap[tName] = (kmMap[tName] ?? 0.0) + (a['km'] as num).toDouble(); // Přidá vzdálenost aktivity k mapě týmů
      }
      map[id] = kmMap.values.any((km) => km >= target); // Označí, zda je výzva dokončena pro daný tým
    }
    return map;
  }

  // Metoda pro synchronizaci stavu výzv s databází
  Future<void> _syncChallengeStatus(List<Map<String, dynamic>> challenges, Map<int, bool> completed) async {
    for (var c in challenges) {
      final id = c['id'] as int; // ID výzvy
      final isActive = !(completed[id] ?? false); // Nový stav aktivity
      if (c['is_active'] != isActive) { // Pokud se změnil stav, aktualizuje ho v databázi
        await _supabase.from('challenges').update({'is_active': isActive}).eq('id', id);
        c['is_active'] = isActive; // Aktualizuje stav výzvy ve seznamu
      }
    }
  }

  // Metoda pro zobrazení dialogu pro vytvoření nové výzvy (pouze pro přehlednost)
  void _showCreateDialog() async {
    final teams = await SupabaseService.loadTeamsSafe(); // Načítá dostupné týmy ze databáze
    if (!mounted) return;
    // (Zde by byl dialog pro vytvoření výzvy - zkráceno pro přehlednost)
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Výzvy'), actions: [buildAppMenu(context)]), // Nastaví titulek stránky a menu
      body: _isLoading ? const Center(child: CircularProgressIndicator()) : ListView.builder( // Zobrazení seznamu výzv
        itemCount: _challenges.length,
        itemBuilder: (context, i) {
          final c = _challenges[i]; // Aktuální výzva
          return Card(margin: const EdgeInsets.all(8), child: ListTile(
            title: Text(c['name'], style: const TextStyle(fontWeight: FontWeight.bold)), // Název výzvy
            subtitle: Text('Start: ${c['start_date']}\nTýmy: ${c['team_names']}'), // Informace o výzve
            trailing: Text('${c['distance']} km', style: const TextStyle(fontWeight: FontWeight.bold)), // Cílová vzdálenost výzvy
          ));
        },
      ),
      floatingActionButton: FloatingActionButton(onPressed: _showCreateDialog, backgroundColor: Colors.orange, child: const Icon(Icons.add)), // Tlačítko pro přidání nové výzvy
    );
  }
}

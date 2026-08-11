import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';
import '../utils/helpers.dart';
import 'app_menu.dart';
// import 'dashboard_screen.dart'; // Removido por conflito de importação caso não exista no novo escopo
class ChallengesScreen extends StatefulWidget {
  const ChallengesScreen({super.key});

  @override
  State<ChallengesScreen> createState() => _ChallengesScreenState();
}

class _ChallengesScreenState extends State<ChallengesScreen> {
  final _supabase = Supabase.instance.client;
  bool _isLoading = true;
  String? _loadError;
  List<Map<String, dynamic>> _challenges = [];
  Map<int, bool> _challengeCompleted = {};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final challengeList = await SupabaseService.loadChallengesSafe(ascending: true);
      final activities = await SupabaseService.loadActivitiesSafe(ascending: false);
      final completedMap = _buildChallengeCompletionMap(challengeList, activities);
      await _syncChallengeStatus(challengeList, completedMap);

      setState(() {
        _challenges = challengeList;
        _challengeCompleted = completedMap;
        _isLoading = false;
      });
    } catch (e) {
      setState(() { _loadError = formatBackendError(e); _isLoading = false; });
    }
  }

  Map<int, bool> _buildChallengeCompletionMap(List<Map<String, dynamic>> challenges, List<Map<String, dynamic>> activities) {
    final map = <int, bool>{};
    for (var c in challenges) {
      final id = c['id'] as int;
      final teams = parseCsvLowerSet(c['team_names'] ?? '');
      final start = DateTime.tryParse(c['start_date'] ?? '')?.toLocal();
      final target = (c['distance'] as num?)?.toDouble() ?? 0.0;
      final kmMap = { for (var t in teams) t: 0.0 };

      for (var a in activities) {
        final tName = (a['team_name'] ?? '').toString().trim().toLowerCase();
        if (!teams.contains(tName)) continue;
        final aTime = DateTime.tryParse((a['start_time'] ?? a['created_at'] ?? '').toString())?.toLocal();
        if (start != null && aTime != null && aTime.isBefore(start)) continue;
        kmMap[tName] = (kmMap[tName] ?? 0.0) + (a['km'] as num).toDouble();
      }
      map[id] = kmMap.values.any((km) => km >= target);
    }
    return map;
  }

  Future<void> _syncChallengeStatus(List<Map<String, dynamic>> challenges, Map<int, bool> completed) async {
    for (var c in challenges) {
      final id = c['id'] as int;
      final isActive = !(completed[id] ?? false);
      if (c['is_active'] != isActive) {
        await _supabase.from('challenges').update({'is_active': isActive}).eq('id', id);
        c['is_active'] = isActive;
      }
    }
  }

  void _showCreateDialog() async {
    final teams = await SupabaseService.loadTeamsSafe();
    if (!mounted) return;
    // (Zde by byl dialog pro vytvoření výzvy - zkráceno pro přehlednost)
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        appBar: AppBar(
        title: const Text('Výzvy'),
          actions: [buildAppMenu(context)],
        ),
      body: _isLoading ? const Center(child: CircularProgressIndicator()) : ListView.builder(
        itemCount: _challenges.length,
      itemBuilder: (context, i) {
          final c = _challenges[i];
        return Card(margin: const EdgeInsets.all(8), child: ListTile(
          title: Text(c['name'], style: const TextStyle(fontWeight: FontWeight.bold)),
          subtitle: Text('Start: ${c['start_date']}\nTýmy: ${c['team_names']}'),
          trailing: Text('${c['distance']} km', style: const TextStyle(fontWeight: FontWeight.bold)),
        ));
      },
      ),
      floatingActionButton: FloatingActionButton(onPressed: _showCreateDialog, backgroundColor: Colors.orange, child: const Icon(Icons.add)),
    );
  }
}


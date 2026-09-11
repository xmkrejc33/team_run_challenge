import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/supabase_service.dart';
import '../utils/helpers.dart';
import '../utils/health_helper.dart';
import 'app_menu.dart'; // Správný import pro buildAppMenu

// Třída pro zobrazení domovské stránky s přehledem výzv a aktivit
class ChallengeDashboard extends StatefulWidget {
  final bool syncOnStart;
  const ChallengeDashboard({super.key, this.syncOnStart = false});

  @override
  State<ChallengeDashboard> createState() => _ChallengeDashboardState();
}

// Stavová třída pro zobrazení domovské stránky s přehledem výzv a aktivit
class _ChallengeDashboardState extends State<ChallengeDashboard> {
  final double _defaultTargetKm = 500.0; // Výchozí cílová vzdálenost pro výzvu
  static const String _selectedChallengePrefsKey = 'selected_challenge_id'; // Klíč pro uložení ID vybrané výzvy do SharedPreferences
  DateTime? _lastSyncAt; // Čas poslední synchronizace dat z Health Connect
  bool _isSyncingHealth = false; // Indikuje, zda se probíhá synchronizace s Health Connect
  bool _isChallengesLoading = true; // Indikuje, zda se načítávají výzvy
  List<Map<String, dynamic>> _dashboardChallenges = []; // Seznam výzv pro domovskou stránku
  int? _selectedChallengeId; // ID vybrané výzvy
  String? _dashboardChallengesError; // Chyba při načítání výzv pro domovskou stránku
  String? _dashboardActivitiesError; // Chyba při načítání aktivit pro domovskou stránku

  @override
  void initState() {
    super.initState();
    _loadChallengesForDashboard(); // Načítá výzvy pro domovskou stránku
    _initializeDashboard();
  }

  Future<void> _initializeDashboard() async {
    await _loadLastSyncTime();
    if (!mounted || !widget.syncOnStart) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncGoogleHealthConnect(); // Synchronizuje data z Health Connect při prvním načtení stránky
      }
    });
  }

  Future<void> _loadChallengesForDashboard() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedSelectedId = prefs.getInt(_selectedChallengePrefsKey);
      final challengeList = await SupabaseService.loadChallengesSafe(ascending: false); // Načítá výzvy ze databáze

      int? selectedId = _selectedChallengeId ?? storedSelectedId;
      if (challengeList.isNotEmpty) {
        final selectedExists = selectedId != null && challengeList.any((c) => c['id'] == selectedId);
        if (!selectedExists) {
          final active = challengeList.where((c) => c['is_active'] == true).toList();
          selectedId = (active.isNotEmpty ? active.first : challengeList.first)['id'] as int;
        }
      } else {
        selectedId = null;
      }

      if (selectedId == null) {
        await prefs.remove(_selectedChallengePrefsKey);
      } else {
        await prefs.setInt(_selectedChallengePrefsKey, selectedId);
      }

      if (!mounted) return;
      setState(() {
        _dashboardChallenges = challengeList; // Nastaví seznam výzv pro domovskou stránku
        _selectedChallengeId = selectedId; // Nastaví ID vybrané výzvy
        _dashboardChallengesError = null; // Resetuje chybu při načítání výzv pro domovskou stránku
        _isChallengesLoading = false; // Označí, že se načítání ukončilo
      });
    } catch (e) {
      debugPrint(formatBackendError(e, context: 'Chyba načítání výzev na dashboardu')); // Vypíše chybu při načítání výzv pro domovskou stránku
      if (!mounted) return;
      setState(() {
        _dashboardChallengesError = formatBackendError(e, context: 'challenges query failed'); // Nastaví chybu při načítání výzv pro domovskou stránku
        _isChallengesLoading = false; // Označí, že se načítání ukončilo s chybou
      });
    }
  }

  Future<void> _saveSelectedChallengeId(int? challengeId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (challengeId == null) {
        await prefs.remove(_selectedChallengePrefsKey);
      } else {
        await prefs.setInt(_selectedChallengePrefsKey, challengeId);
      }
    } catch (e) {
      debugPrint('Chyba ukládání vybrané výzvy: $e');
    }
  }

  Map<String, dynamic>? _selectedChallenge() {
    if (_selectedChallengeId == null) return null;
    for (final challenge in _dashboardChallenges) {
      if (challenge['id'] == _selectedChallengeId) return challenge; // Vrátí vybranou výzvu
    }
    return null;
  }

  List<String> _selectedChallengeTeamLabels() {
    return parseCsvLabels(((_selectedChallenge()?['team_names']) ?? '').toString()); // Vrátí názvy týmů pro vybranou výzvu jako seznam
  }

  Set<String> _selectedChallengeTeamNames() {
    return parseCsvLowerSet(((_selectedChallenge()?['team_names']) ?? '').toString()); // Vrátí názvy týmů pro vybranou výzvu jako množinu malých písmen
  }

  double _selectedTargetKm() {
    final challenge = _selectedChallenge();
    return (challenge?['distance'] as num?)?.toDouble() ?? _defaultTargetKm; // Vrátí cílovou vzdálenost pro vybranou výzvu nebo výchozí hodnotu
  }

  String _formatDateTime(DateTime? dateTime) {
    return dateTime == null ? 'Zatím neproběhla' : formatDateTimeOrDash(dateTime);
  }

  String _formatIsoDateTime(String? iso) {
    return formatDateTimeOrDash(DateTime.tryParse(iso ?? '')?.toLocal()); // Formátuje ISO datum a čas nebo vrátí "-"
  }

  Future<List<Map<String, dynamic>>> _fetchActivitiesForDashboard() async {
    try {
      final data = await SupabaseService.loadActivitiesSafe(ascending: false); // Načítá aktivity ze databáze
      final profiles = await _supabaseProfilesForAvatars();
      final avatarByRunner = <String, String>{
        for (final profile in profiles)
          if ((profile['runner_name'] ?? '').toString().trim().isNotEmpty &&
              (profile['avatar_base64'] ?? '').toString().trim().isNotEmpty)
            profile['runner_name'].toString().trim().toLowerCase(): profile['avatar_base64'].toString(),
      };
      for (final activity in data) {
        activity['avatar_base64'] = avatarByRunner[activity['runner_name'].toString().trim().toLowerCase()];
      }
      _dashboardActivitiesError = null; // Resetuje chybu při načítání aktivit pro domovskou stránku
      return data;
    } catch (e) {
      debugPrint(formatBackendError(e, context: 'Dashboard activities safe load failed')); // Vypíše chybu při načítání aktivit pro domovskou stránku
      _dashboardActivitiesError = formatBackendError(e, context: 'activities query failed'); // Nastaví chybu při načítání aktivit pro domovskou stránku
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> _supabaseProfilesForAvatars() async {
    try {
      final rows = await SupabaseService.client
          .from('profiles')
          .select('runner_name, avatar_base64');
      return List<Map<String, dynamic>>.from(rows);
    } catch (e) {
      debugPrint('Dashboard avatar profiles load failed: $e');
      return const [];
    }
  }

  ImageProvider? _activityAvatar(String? avatarBase64) {
    final avatar = avatarBase64?.trim() ?? '';
    if (avatar.isEmpty) return null;
    try {
      return MemoryImage(base64Decode(avatar));
    } on FormatException {
      return null;
    }
  }

  Future<void> _loadLastSyncTime() async {
    try {
      final profile = await SupabaseService.loadCurrentProfile();
      final stored = profile['last_sync_at']?.toString();
      DateTime? lastSyncAt = DateTime.tryParse(stored ?? '')?.toLocal();
      lastSyncAt ??= (await SupabaseService.loadLastActivityUploadAt(
        runnerName: (profile['runner_name'] ?? '').toString(),
        teamName: (profile['team_name'] ?? '').toString(),
      ))?.toLocal();
      if (mounted) setState(() => _lastSyncAt = lastSyncAt);
    } catch (e) {
      debugPrint('Chyba načítání poslední synchronizace: $e');
    }
  }

  Future<void> _saveLastSyncTime(DateTime time) async {
    try {
      await SupabaseService.saveLastActivitySync(time);
    } catch (e) {
      debugPrint('Chyba ukládání poslední synchronizace: $e');
    }
  }

  Future<void> _syncGoogleHealthConnect() async {
    if (!mounted) return;
    setState(() => _isSyncingHealth = true);

    try {
      final profile = await SupabaseService.loadCurrentProfile();
      final runnerName = (profile['runner_name'] ?? 'Anonymní běžec').toString();
      final teamName = (profile['team_name'] ?? 'Neznámý tým').toString();
      debugPrint('Health sync: using shared restoreActivities handler');

      final insertedCount = await SupabaseService.restoreActivities(
        runnerName: runnerName,
        teamName: teamName,
        startTime: _lastSyncAt!,
        onStatusUpdate: (status) => debugPrint('Health sync: $status'),
      );

      if (!mounted) return;
      await _markSyncCompleted(DateTime.now());
      _showSnackBar(
        insertedCount > 0
        ? 'Úspěšně synchronizováno. Uloženo $insertedCount aktivit z ${HealthHelper.providerName}.'
            : 'Synchronizace dokončena. Nové aktivity nebyly nalezeny.',
        insertedCount > 0 ? Colors.green : Colors.blue,
      );
    } catch (e) {
      debugPrint('Chyba synchronizace zdraví: $e');
      if (mounted) {
        _showSnackBar('Chyba při komunikaci s ${HealthHelper.providerName}: $e', Colors.red);
      }
    } finally {
      if (mounted) setState(() => _isSyncingHealth = false);
    }
  }

  Future<void> _markSyncCompleted(DateTime completedAt) async {
    if (mounted) {
      setState(() => _lastSyncAt = completedAt);
    }
    await _saveLastSyncTime(completedAt);
  }

  void _showSnackBar(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: color,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Týmové výzvy',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: Colors.orange,
        centerTitle: true,
        actions: [buildAppMenu(context)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Card(
                color: Colors.orange[50],
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: Colors.orange),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14.0, horizontal: 16.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const Text(
                              'Datum poslední synchronizace',
                              style: TextStyle(fontSize: 14, color: Colors.black87),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _formatDateTime(_lastSyncAt),
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.black87,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                      if (_isSyncingHealth)
                        const Padding(
                          padding: EdgeInsets.only(left: 12.0),
                          child: SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(strokeWidth: 3),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Vybraná výzva',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              if (_isChallengesLoading)
                const Center(child: CircularProgressIndicator())
              else if (_dashboardChallenges.isEmpty)
                const Text('Nejsou dostupné žádné výzvy.')
              else
                DropdownButtonFormField<int>(
                  key: ValueKey(_selectedChallengeId),
                  initialValue: _selectedChallengeId,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  ),
                  items: _dashboardChallenges.map((challenge) {
                    final name = (challenge['name'] ?? 'Výzva').toString();
                    final dateValue = challenge['start_date']?.toString() ?? '';
                    final date = DateTime.tryParse(dateValue)?.toLocal();
                    final label = date != null
                        ? '$name (${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year})'
                        : name;
                    return DropdownMenuItem<int>(
                      value: challenge['id'] as int,
                      child: Text(label),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedChallengeId = value;
                    });
                    _saveSelectedChallengeId(value);
                  },
                ),
              if (_dashboardChallengesError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(
                    'Diagnostika výzev: ${_dashboardChallengesError!}',
                    style: const TextStyle(color: Colors.red, fontSize: 12),
                  ),
                ),
              const SizedBox(height: 16),
              const Text(
                'Průběžný stav závodu',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _fetchActivitiesForDashboard(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return const Text('Průběžný stav závodu se nepodařilo načíst.');
                  }

                  final selectedChallenge = _selectedChallenge();
                  final selectedTeamNames = _selectedChallengeTeamNames();
                  final selectedTeamLabels = _selectedChallengeTeamLabels();
                  final challengeStartValue = selectedChallenge?['start_date']?.toString() ?? '';
                  final challengeStartDate = DateTime.tryParse(challengeStartValue)?.toLocal();

                  if (selectedTeamLabels.isEmpty) {
                    return const Text('Pro vybranou výzvu nejsou přiřazeny žádné týmy.');
                  }

                  final activities = snapshot.data ?? const <Map<String, dynamic>>[];
                  final kmByTeam = {
                    for (final label in selectedTeamLabels) label.toLowerCase(): 0.0,
                  };

                  for (final act in activities) {
                    final teamNameRaw = (act['team_name'] ?? '').toString().trim();
                    final teamNameKey = teamNameRaw.toLowerCase();
                    if (!selectedTeamNames.contains(teamNameKey)) continue;

                    if (challengeStartDate != null) {
                      final rawTime = (act['start_time'] ?? act['created_at'] ?? '').toString();
                      final activityTime = DateTime.tryParse(rawTime)?.toLocal();
                      if (activityTime == null || activityTime.isBefore(challengeStartDate)) {
                        continue;
                      }
                    }

                    final kmValue = (act['km'] as num?)?.toDouble() ?? 0.0;
                    kmByTeam[teamNameKey] = (kmByTeam[teamNameKey] ?? 0.0) + kmValue;
                  }

                  final targetKm = _selectedTargetKm();

                  return ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: selectedTeamLabels.length,
                    itemBuilder: (context, index) {
                      final String name = selectedTeamLabels[index];
                      final double km = kmByTeam[name.toLowerCase()] ?? 0.0;

                      final List<Color> teamColors = [
                        Colors.blue,
                        Colors.green,
                        Colors.purple,
                        Colors.teal,
                      ];
                      final color = teamColors[index % teamColors.length];

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12.0),
                        child: _buildTeamCard(
                          name,
                          km,
                          targetKm,
                          color,
                        ),
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 16),
              const Text(
                'Historie aktivit',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _fetchActivitiesForDashboard(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return const Text('Historii aktivit se nepodařilo načíst.');
                  }

                  final selectedChallenge = _selectedChallenge();
                  final selectedTeamNames = _selectedChallengeTeamNames();
                  final challengeStartValue = selectedChallenge?['start_date']?.toString() ?? '';
                  final challengeStartDate = DateTime.tryParse(challengeStartValue)?.toLocal();

                  final activities = (snapshot.data ?? const <Map<String, dynamic>>[])
                      .where((act) {
                    final tName = (act['team_name'] ?? '').toString().trim().toLowerCase();
                    if (selectedTeamNames.isNotEmpty && !selectedTeamNames.contains(tName)) {
                      return false;
                    }

                    if (challengeStartDate == null) return true;

                    final rawTime = (act['start_time'] ?? act['end_time'] ?? act['created_at'] ?? '').toString();
                    if (rawTime.isEmpty) return false;
                    final activityTime = DateTime.tryParse(rawTime)?.toLocal();
                    if (activityTime == null) return false;
                    return !activityTime.isBefore(challengeStartDate);
                  }).toList();

                  if (activities.isEmpty) {
                    return Center(
                      child: Text(
                        _dashboardActivitiesError == null
                            ? 'Pro vybranou výzvu zatím nejsou zapsány žádné aktivity.'
                            : 'Pro vybranou výzvu zatím nejsou zapsány žádné aktivity.\n${_dashboardActivitiesError!}',
                        style: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic),
                        textAlign: TextAlign.center,
                      ),
                    );
                  }

                  return ListView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: activities.length,
                    itemBuilder: (context, index) {
                      final act = activities[index];
                      final String tName = act['team_name'] ?? 'Neznámý tým';
                      final String runnerName = act['runner_name'] ?? 'Anonymní běžec';
                      final double kmValue = (act['km'] as num).toDouble();

                      final String startAtRaw = (act['start_time'] ?? '').toString();
                      final String endAtRaw = (act['end_time'] ?? '').toString();

                        final avatarImage = _activityAvatar(act['avatar_base64']?.toString());

                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.orange.withValues(alpha: 0.15),
                            backgroundImage: avatarImage,
                            child: avatarImage == null
                                ? const Icon(Icons.directions_run, color: Colors.orange)
                                : null,
                          ),
                          title: Text(
                            runnerName,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          subtitle: Text(
                            'Tým: $tName\nStart: ${_formatIsoDateTime(startAtRaw)}\nKonec: ${_formatIsoDateTime(endAtRaw)}',
                            style: TextStyle(color: Colors.grey[700]),
                          ),
                          trailing: Text(
                            '+${kmValue.toStringAsFixed(1)} km',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.orange,
                            ),
                          ),
                          isThreeLine: true,
                        ),
                      );
                    },
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTeamCard(String name, double current, double target, Color color) {
    final safeTarget = target <= 0 ? 1.0 : target;
    final percentage = (current / safeTarget).clamp(0.0, 1.0);

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  name,
                  style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  '${current.toStringAsFixed(1)} / ${safeTarget.toInt()} km',
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: percentage,
                minHeight: 10,
                backgroundColor: color.withValues(alpha: 0.15),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '${(percentage * 100).toStringAsFixed(0)}%',
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
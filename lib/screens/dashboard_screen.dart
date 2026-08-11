import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:health/health.dart';

import '../services/supabase_service.dart';
import '../utils/helpers.dart';
import '../utils/health_helper.dart';
import 'app_menu.dart'; // Správný import pro buildAppMenu

class ChallengeDashboard extends StatefulWidget {
  final bool syncOnStart;
  const ChallengeDashboard({super.key, this.syncOnStart = false});

  @override
  State<ChallengeDashboard> createState() => _ChallengeDashboardState();
}

class _ChallengeDashboardState extends State<ChallengeDashboard> {
  final double _defaultTargetKm = 500.0;
  static const String _selectedChallengePrefsKey = 'selected_challenge_id';
  final _supabase = Supabase.instance.client;

  DateTime? _lastSyncAt;
  bool _isSyncingHealth = false;
  bool _isChallengesLoading = true;
  List<Map<String, dynamic>> _dashboardChallenges = [];
  int? _selectedChallengeId;
  String? _dashboardChallengesError;
  String? _dashboardActivitiesError;
  String _currentRunnerName = '';
  String? _currentRunnerAvatarBase64;

  @override
  void initState() {
    super.initState();
    _loadLastSyncTime();
    _loadChallengesForDashboard();
    _loadCurrentRunnerVisuals();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.syncOnStart) {
        _syncGoogleHealthConnect();
      }
    });
  }

  void _loadCurrentRunnerVisuals() {
    final user = _supabase.auth.currentUser;
    final metadata = user?.userMetadata ?? {};
    _currentRunnerName = (metadata['runner_name'] ?? '').toString().trim();
    final avatarRaw = (metadata['avatar_base64'] ?? '').toString().trim();
    _currentRunnerAvatarBase64 = avatarRaw.isEmpty ? null : avatarRaw;
  }

  Future<void> _loadChallengesForDashboard() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedSelectedId = prefs.getInt(_selectedChallengePrefsKey);
      final challengeList = await SupabaseService.loadChallengesSafe(ascending: false);

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
        _dashboardChallenges = challengeList;
        _selectedChallengeId = selectedId;
        _dashboardChallengesError = null;
        _isChallengesLoading = false;
      });
    } catch (e) {
      debugPrint(formatBackendError(e, context: 'Chyba načítání výzev na dashboardu'));
      if (!mounted) return;
      setState(() {
        _dashboardChallengesError = formatBackendError(e, context: 'challenges query failed');
        _isChallengesLoading = false;
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
      if (challenge['id'] == _selectedChallengeId) return challenge;
    }
    return null;
  }

  List<String> _selectedChallengeTeamLabels() {
    return parseCsvLabels(((_selectedChallenge()?['team_names']) ?? '').toString());
  }

  Set<String> _selectedChallengeTeamNames() {
    return parseCsvLowerSet(((_selectedChallenge()?['team_names']) ?? '').toString());
  }

  double _selectedTargetKm() {
    final challenge = _selectedChallenge();
    return (challenge?['distance'] as num?)?.toDouble() ?? _defaultTargetKm;
  }

  String _formatDateTime(DateTime? dateTime) {
    return formatDateTimeOrDash(dateTime);
  }

  String _formatIsoDateTime(String? iso) {
    return formatDateTimeOrDash(DateTime.tryParse(iso ?? '')?.toLocal());
  }

  Future<List<Map<String, dynamic>>> _fetchActivitiesForDashboard() async {
    try {
      final data = await SupabaseService.loadActivitiesSafe(ascending: false);
      _dashboardActivitiesError = null;
      return data;
    } catch (e) {
      debugPrint(formatBackendError(e, context: 'Dashboard activities safe load failed'));
      _dashboardActivitiesError = formatBackendError(e, context: 'activities query failed');
      return [];
    }
  }

  Future<void> _loadLastSyncTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('last_sync_time');
      if (stored != null) {
        setState(() {
          _lastSyncAt = DateTime.tryParse(stored)?.toLocal();
        });
        return;
      }

      final user = _supabase.auth.currentUser;
      final userMetadata = user?.userMetadata ?? {};
      final String loggedInRunnerName = userMetadata['runner_name'] ?? '';
      final String loggedInTeamName = userMetadata['team_name'] ?? '';

      if (loggedInRunnerName.isEmpty || loggedInTeamName.isEmpty) return;

      final response = await _supabase
          .from('activities')
          .select('created_at')
          .eq('runner_name', loggedInRunnerName)
          .eq('team_name', loggedInTeamName)
          .order('created_at', ascending: false)
          .limit(1)
          .maybeSingle();

      if (response != null && response['created_at'] != null) {
        setState(() {
          _lastSyncAt = DateTime.parse(response['created_at']).toLocal();
        });
  }
    } catch (e) {
      debugPrint('Chyba načítání poslední synchronizace: $e');
    }
  }

  Future<void> _saveLastSyncTime(DateTime time) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_sync_time', time.toUtc().toIso8601String());
    } catch (e) {
      debugPrint('Chyba ukládání poslední synchronizace: $e');
    }
  }

  Future<void> _syncGoogleHealthConnect() async {
    setState(() => _isSyncingHealth = true);

    final user = _supabase.auth.currentUser;
    final userMetadata = user?.userMetadata ?? {};
    final String loggedInRunnerName = userMetadata['runner_name'] ?? 'Anonymní běžec';
    final int loggedInTeamId = userMetadata['team_id'] ?? 0;
    final String loggedInTeamName = userMetadata['team_name'] ?? 'Neznámý tým';

    if (loggedInTeamId == 0) {
      _showSnackBar('Chyba: Nebyl nalezen váš tým v profilu.', Colors.red);
      setState(() => _isSyncingHealth = false);
      return;
    }

    try {
      if (!await HealthHelper.checkHealthConnectAvailability()) {
        _showSnackBar('Health Connect není na tomto zařízení dostupný. Otevři Health Connect a zkontroluj, zda je nainstalovaný a aktivní.', Colors.orange);
    if (!mounted) return;
        setState(() => _isSyncingHealth = false);
        return;
      }

      if (!await HealthHelper.requestDistanceAccess()) {
        _showSnackBar('Health Connect neudělil oprávnění. Otevři Health Connect a povol aplikaci přístup k datům o vzdálenosti.', Colors.orange);
        if (!mounted) return;
        setState(() => _isSyncingHealth = false);
        return;
      }

      final now = DateTime.now();
      final defaultStart = DateTime(now.year, now.month, now.day);
      var startTime = _lastSyncAt ?? defaultStart;

      List<HealthDataPoint> healthData = await HealthHelper.getHealthDataFromTypes(
        types: [HealthDataType.DISTANCE_DELTA],
        startTime: startTime,
        endTime: now,
                  );
      if (healthData.isEmpty && _lastSyncAt != null) {
        startTime = defaultStart;
        healthData = await HealthHelper.getHealthDataFromTypes(
          types: [HealthDataType.DISTANCE_DELTA],
          startTime: startTime,
          endTime: now,
        );
      }

      List<HealthDataPoint> workoutData = await HealthHelper.getHealthDataFromTypes(
        types: const [HealthDataType.WORKOUT],
        startTime: startTime,
        endTime: now,
      );

      final runningSessions = HealthHelper.extractRunningSessionRanges(workoutData);
      List<DateTimeRange> effectiveRunningSessions = runningSessions;
      if (effectiveRunningSessions.isEmpty) {
        effectiveRunningSessions = await HealthHelper.loadRunningSessionsFromNative(startTime, now);
  }

      if (effectiveRunningSessions.isEmpty) {
        _showSnackBar('Nenalezeny bezecke ExerciseSession. V Health Connect povol Cviceni/Treninky.', Colors.blue);
        if (!mounted) return;
        setState(() => _isSyncingHealth = false);
        return;
      }

      double totalMetersToday = 0.0;
      DateTime? activityStartTime;
      DateTime? activityEndTime;
      for (var dataPoint in healthData) {
        final pointStart = dataPoint.dateFrom;
        final pointEnd = dataPoint.dateTo;
        if (!HealthHelper.overlapsRunningSession(pointStart, pointEnd, effectiveRunningSessions)) {
          continue;
        }
        if (activityStartTime == null || pointStart.isBefore(activityStartTime)) {
          activityStartTime = pointStart;
        }
        if (activityEndTime == null || pointEnd.isAfter(activityEndTime)) {
          activityEndTime = pointEnd;
        }
        if (dataPoint.value is NumericHealthValue) {
          final numericValue = (dataPoint.value as NumericHealthValue).numericValue;
          totalMetersToday += numericValue.toDouble();
        }
      }

      final activityStart = activityStartTime ?? startTime;
      final activityEnd = activityEndTime ?? now;
      double totalKmFromPhoneToday = totalMetersToday / 1000.0;

      if (totalKmFromPhoneToday <= 0) {
        _showSnackBar('Dnes nemáte v telefonu zaznamenané žádné kilometry. Zvedněte se z gauče! 🏃‍♂️', Colors.blue);
        if (!mounted) return;
        setState(() => _isSyncingHealth = false);
        return;
      }

      final finalStartIso = startTime.toUtc().toIso8601String();
      final response = await _supabase
          .from('activities')
          .select('km')
          .eq('runner_name', loggedInRunnerName)
          .eq('team_name', loggedInTeamName)
          .gte('created_at', finalStartIso);

      double alreadySyncedKm = 0.0;
      for (var row in response) {
        alreadySyncedKm += (row['km'] as num).toDouble();
      }

      double deltaKm = totalKmFromPhoneToday - alreadySyncedKm;

      if (deltaKm <= 0.05) {
        _showSnackBar('Všechny kilometry z telefonu (${totalKmFromPhoneToday.toStringAsFixed(2)} km) už máte zapsané. 🎉', Colors.green);
        if (!mounted) return;
        setState(() => _isSyncingHealth = false);
        return;
      }

      final teamData = await _supabase
          .from('teams')
          .select('km')
          .eq('id', loggedInTeamId)
          .single();
      double currentTeamKm = (teamData['km'] as num).toDouble();
      final selectedTargetKm = _selectedTargetKm();
      double newTeamKm = (currentTeamKm + deltaKm).clamp(0.0, selectedTargetKm);

      await _supabase
          .from('teams')
          .update({'km': newTeamKm}).eq('id', loggedInTeamId);

      final activityData = {
        'team_name': loggedInTeamName,
        'km': deltaKm,
        'runner_name': loggedInRunnerName,
        'start_time': activityStart.toUtc().toIso8601String(),
        'end_time': activityEnd.toUtc().toIso8601String(),
      };

      try {
        await _supabase.from('activities').insert(activityData);
      } catch (e) {
        debugPrint('Chyba při vkládání aktivity se start_time/end_time: $e');
        try {
          await _supabase.from('activities').insert({
            'team_name': loggedInTeamName,
            'km': deltaKm,
            'runner_name': loggedInRunnerName,
            'start_time': activityStart.toUtc().toIso8601String(),
          });
        } catch (e2) {
          debugPrint('Fallback insert jen se start_time selhal: $e2');
          await _supabase.from('activities').insert({
            'team_name': loggedInTeamName,
            'km': deltaKm,
            'runner_name': loggedInRunnerName,
          });
        }
      }

      if (!mounted) return;
      setState(() {
        _lastSyncAt = now;
      });
      await _saveLastSyncTime(now);

      _showSnackBar('Úspěšně synchronizováno! Připsáno +${deltaKm.toStringAsFixed(2)} km z Health Connect.', Colors.green);
    } catch (e) {
      debugPrint('Chyba synchronizace zdraví: $e');
      _showSnackBar('Chyba při komunikaci s Health Connect: $e', Colors.red);
    }

    if (!mounted) return;
    setState(() => _isSyncingHealth = false);
  }

  void _showSnackBar(String message, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: color),
                    );
                  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Týmové výzvy', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
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
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.orange)),
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
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
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
                              child: CircularProgressIndicator(strokeWidth: 3)),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text('Vybraná výzva', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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
              const Text('Průběžný stav závodu', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
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
                  final Map<String, double> kmByTeam = {
                    for (final label in selectedTeamLabels)
                      label.toLowerCase(): 0.0,
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
                        Colors.teal
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
              const Text('Historie aktivit', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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

                      final sameRunner = runnerName.trim() == _currentRunnerName;
                      final ImageProvider? avatarImage = sameRunner && _currentRunnerAvatarBase64 != null
                              ? MemoryImage(base64Decode(_currentRunnerAvatarBase64!))
                              : null;

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
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.orange),
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
    double percentage = (current / target).clamp(0.0, 1.0);
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                Text('${current.toStringAsFixed(1)} / ${target.toInt()} km',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500)),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: percentage,
                minHeight: 15,
                backgroundColor: Colors.grey[300],
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
            const SizedBox(height: 12),
            Text('${(percentage * 100).toStringAsFixed(1)}% hotovo',
                style: TextStyle(color: Colors.grey[600], fontSize: 13)),
          ],
        ),
      ),
    );
  }
}


import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../services/supabase_service.dart';
import '../utils/helpers.dart';
import 'app_menu.dart';

class ChallengesScreen extends StatefulWidget {
  const ChallengesScreen({super.key});

  @override
  State<ChallengesScreen> createState() => _ChallengesScreenState();
}

class _ChallengesScreenState extends State<ChallengesScreen> {
  final _supabase = Supabase.instance.client;
  bool _isLoading = true;
  List<Map<String, dynamic>> _challenges = [];
  Map<int, Map<String, double>> _challengeTeamKm = {};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final challengeList = await SupabaseService.loadChallengesSafe(ascending: true);
      final activities = await SupabaseService.loadActivitiesSafe(ascending: false);
      final teamKmByChallenge = _buildChallengeTeamKmMap(challengeList, activities);
      await _syncChallengeStatus(challengeList, activities);

      setState(() {
        _challenges = challengeList;
        _challengeTeamKm = teamKmByChallenge;
        _isLoading = false;
      });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  Map<int, Map<String, double>> _buildChallengeTeamKmMap(
    List<Map<String, dynamic>> challenges,
    List<Map<String, dynamic>> activities,
  ) {
    final map = <int, Map<String, double>>{};
    for (var c in challenges) {
      final id = c['id'] as int;
      final teams = parseCsvLowerSet(c['team_names'] ?? '');
      final start = DateTime.tryParse(c['start_date'] ?? '')?.toLocal();
      final kmMap = { for (var t in teams) t: 0.0 };

      for (var a in activities) {
        final tName = (a['team_name'] ?? '').toString().trim().toLowerCase();
        if (!teams.contains(tName)) continue;
        final aTime = DateTime.tryParse((a['start_time'] ?? a['created_at'] ?? '').toString())?.toLocal();
        if (start != null && aTime != null && aTime.isBefore(start)) continue;
        kmMap[tName] = (kmMap[tName] ?? 0.0) + (a['km'] as num).toDouble();
      }
      map[id] = kmMap;
    }
    return map;
  }

  String _winnerLabel(Map<String, dynamic> challenge) {
    final storedWinner = (challenge['winner_team'] ?? '').toString().trim();
    if (storedWinner.isNotEmpty) {
      final winnerName = parseCsvLabels(challenge['team_names']?.toString() ?? '')
          .firstWhere((label) => label.toLowerCase() == storedWinner.toLowerCase(), orElse: () => storedWinner);
      return 'Vítězný tým: $winnerName';
    }

    final teamKm = _challengeTeamKm[challenge['id'] as int] ?? {};
    if (teamKm.isEmpty) return 'Vítězný tým: zatím bez aktivit';

    final highestKm = teamKm.values.reduce((left, right) => left > right ? left : right);
    final winners = teamKm.entries
        .where((entry) => (entry.value - highestKm).abs() < 0.001)
        .map((entry) => entry.key)
        .toList();
    final winnerNames = winners.map((winner) {
      return parseCsvLabels(challenge['team_names']?.toString() ?? '')
          .firstWhere((label) => label.toLowerCase() == winner, orElse: () => winner);
    }).join(', ');
    return winners.length == 1
        ? 'Vítězný tým: $winnerNames (${highestKm.toStringAsFixed(1)} km)'
        : 'Remíza: $winnerNames (${highestKm.toStringAsFixed(1)} km)';
  }

  Future<void> _syncChallengeStatus(
    List<Map<String, dynamic>> challenges,
    List<Map<String, dynamic>> activities,
  ) async {
    if (_supabase.auth.currentUser == null) return;

    for (var c in challenges) {
      final id = c['id'] as int;
      if (c['is_active'] != true && c['end_date'] != null && c['winner_team'] != null) continue;

      final completion = _findCompletion(c, activities);
      if (completion == null) continue;

      await _supabase.from('challenges').update({
        'is_active': false,
        'end_date': completion.endDate.toUtc().toIso8601String(),
        'winner_team': completion.winnerTeam,
      }).eq('id', id);
      c
        ..['is_active'] = false
        ..['end_date'] = completion.endDate.toUtc().toIso8601String()
        ..['winner_team'] = completion.winnerTeam;
    }
  }

  _ChallengeCompletion? _findCompletion(
    Map<String, dynamic> challenge,
    List<Map<String, dynamic>> activities,
  ) {
    final start = DateTime.tryParse((challenge['start_date'] ?? '').toString())?.toLocal();
    final target = (challenge['distance'] as num?)?.toDouble() ?? 0.0;
    final teams = parseCsvLowerSet(challenge['team_names'] ?? '');
    final totals = {for (final team in teams) team: 0.0};
    final relevantActivities = activities.where((activity) {
      final team = (activity['team_name'] ?? '').toString().trim().toLowerCase();
      final time = DateTime.tryParse((activity['start_time'] ?? activity['created_at'] ?? '').toString())?.toLocal();
      return teams.contains(team) && (start == null || time == null || !time.isBefore(start));
    }).toList()
      ..sort((left, right) {
        final leftTime = DateTime.tryParse((left['start_time'] ?? left['created_at'] ?? '').toString());
        final rightTime = DateTime.tryParse((right['start_time'] ?? right['created_at'] ?? '').toString());
        return (leftTime ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(rightTime ?? DateTime.fromMillisecondsSinceEpoch(0));
      });

    for (final activity in relevantActivities) {
      final team = (activity['team_name'] ?? '').toString().trim().toLowerCase();
      totals[team] = (totals[team] ?? 0.0) + (activity['km'] as num).toDouble();
      if (totals[team]! >= target) {
        final completionValue = activity['end_time'] ?? activity['start_time'] ?? activity['created_at'];
        final endDate = DateTime.tryParse(completionValue.toString())?.toLocal() ?? DateTime.now();
        return _ChallengeCompletion(team, endDate);
      }
    }
    return null;
  }

  Future<void> _showCreateDialog() async {
    final nameController = TextEditingController();
    final distanceController = TextEditingController();
    DateTime? startDate;
    String? validationError;
    bool isSaving = false;
    bool dialogOpen = true;
    final dialogStopwatch = Stopwatch()..start();

    void logCreateStep(String step, [String details = '']) {
      final suffix = details.isEmpty ? '' : ' | $details';
      debugPrint('[ChallengeCreate +${dialogStopwatch.elapsedMilliseconds}ms] $step$suffix');
    }

    logCreateStep('dialog_open');
    final created = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> selectStartDate() async {
              final today = DateTime.now();
              final todayOnly = DateTime(today.year, today.month, today.day);
              final selected = await showDatePicker(
                context: context,
                firstDate: todayOnly,
                lastDate: DateTime(2100),
                initialDate: startDate != null && !startDate!.isBefore(todayOnly)
                    ? startDate!
                    : todayOnly,
              );
              if (selected != null) {
                setDialogState(() => startDate = selected);
              }
            }

            Future<void> createChallenge() async {
              logCreateStep('submit_pressed');
              final name = nameController.text.trim();
              final distance = double.tryParse(distanceController.text.trim().replaceAll(',', '.'));
              final today = DateTime.now();
              final todayOnly = DateTime(today.year, today.month, today.day);
              logCreateStep(
                'input_parsed',
                'nameLength=${name.length}, hasStartDate=${startDate != null}, distance=$distance',
              );
              if (name.isEmpty || startDate == null || distance == null || distance <= 0) {
                logCreateStep('validation_failed');
                setDialogState(() {
                  validationError = 'Vyplňte název, datum začátku a kladný počet kilometrů.';
                });
                return;
              }
              if (startDate!.isBefore(todayOnly)) {
                logCreateStep('validation_failed', 'startDateIsInThePast=true');
                setDialogState(() {
                  validationError = 'Výzva může začínat nejdříve dnes.';
                });
                return;
              }

              setDialogState(() {
                validationError = null;
                isSaving = true;
              });
              logCreateStep('saving_state_enabled');

              try {
                logCreateStep('reading_auth_session');
                final userId = _supabase.auth.currentUser?.id;
                if (userId == null) {
                  logCreateStep('auth_session_missing');
                  throw Exception('Uživatel není přihlášen.');
                }
                logCreateStep('auth_session_ready');
                logCreateStep('loading_profile');
                final profile = await SupabaseService.loadCurrentProfile();
                final teamName = (profile['team_name'] ?? '').toString().trim();
                logCreateStep('profile_loaded', 'hasTeamName=${teamName.isNotEmpty}');
                if (teamName.isEmpty) {
                  logCreateStep('team_missing');
                  throw Exception('V profilu zadavatele není nastaven žádný tým.');
                }
                final startOfDayUtc = DateTime.utc(
                  startDate!.year,
                  startDate!.month,
                  startDate!.day,
                );
                logCreateStep(
                  'insert_start',
                  'startDateUtc=${startOfDayUtc.toIso8601String()}, teamNameLength=${teamName.length}',
                );
                final inserted = await _supabase.from('challenges').insert({
                  'name': name,
                  'start_date': startOfDayUtc.toIso8601String(),
                  'distance': distance,
                  'team_names': teamName,
                  'is_active': true,
                  'end_date': null,
                  'winner_team': null,
                  'originator_id': userId,
                }).select('id, name, start_date, end_date, distance, team_names, winner_team, is_active, originator_id').single();
                logCreateStep('insert_response_received', 'keys=${inserted.keys.toList()}');
                if (dialogOpen && context.mounted) {
                  logCreateStep('dialog_close_success');
                  FocusManager.instance.primaryFocus?.unfocus();
                  Navigator.of(context).pop(Map<String, dynamic>.from(inserted));
                } else {
                  logCreateStep('dialog_close_skipped', 'dialogOpen=$dialogOpen, mounted=${context.mounted}');
                }
              } catch (e) {
                logCreateStep('create_failed', formatBackendError(e));
                if (dialogOpen) {
                  setDialogState(() {
                    validationError = formatBackendError(e, context: 'Vytvoření výzvy selhalo');
                    isSaving = false;
                  });
                }
              }
            }

            return AlertDialog(
              title: const Text('Vytvořit novou výzvu'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(labelText: 'Název výzvy'),
                      textCapitalization: TextCapitalization.sentences,
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.calendar_today),
                      title: Text(startDate == null
                          ? 'Vyberte datum začátku'
                          : 'Začátek: ${formatDateTimeOrDash(startDate, includeTime: false)}'),
                      onTap: isSaving ? null : selectStartDate,
                    ),
                    TextField(
                      controller: distanceController,
                      decoration: const InputDecoration(labelText: 'Cílová vzdálenost (km)'),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    ),
                    if (validationError != null) ...[
                      const SizedBox(height: 12),
                      Text(validationError!, style: const TextStyle(color: Colors.red)),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    logCreateStep('cancel_pressed', 'isSaving=$isSaving');
                    dialogOpen = false;
                    FocusManager.instance.primaryFocus?.unfocus();
                    Navigator.of(context).pop();
                  },
                  child: const Text('Zrušit'),
                ),
                ElevatedButton(
                  onPressed: isSaving ? null : createChallenge,
                  child: isSaving
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Vytvořit'),
                ),
              ],
            );
          },
        );
      },
    );

    logCreateStep('dialog_result', 'created=${created != null}');
    await Future<void>.delayed(const Duration(milliseconds: 250));
    nameController.dispose();
    distanceController.dispose();

    if (created != null && mounted) {
      logCreateStep('list_update_start');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        setState(() {
          _challenges = [..._challenges, created];
        });
        logCreateStep('list_update_complete', 'challengeCount=${_challenges.length}');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Výzva byla vytvořena.'), backgroundColor: Colors.green),
        );
        logCreateStep('success_snackbar_shown');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentChallenges = _challenges.where((challenge) => challenge['is_active'] == true).toList();
    final completedChallenges = _challenges.where((challenge) => challenge['is_active'] != true).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Výzvy'),
        backgroundColor: Colors.orange,
        leading: buildBackToDashboardButton(context),
        actions: [buildAppMenu(context)],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : DefaultTabController(
              length: 2,
              child: Column(
                children: [
                  Material(
                    color: Colors.orange[50],
                    child: const TabBar(
                      labelColor: Colors.orange,
                      unselectedLabelColor: Colors.black54,
                      indicatorColor: Colors.orange,
                      tabs: [
                        Tab(text: 'Aktuální'),
                        Tab(text: 'Ukončené'),
                      ],
                    ),
                  ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildChallengeList(currentChallenges),
                        _buildChallengeList(completedChallenges),
                      ],
                    ),
                  ),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(onPressed: _showCreateDialog, backgroundColor: Colors.orange, child: const Icon(Icons.add)),
    );
  }

  Widget _buildChallengeList(List<Map<String, dynamic>> challenges) {
    if (challenges.isEmpty) {
      return const Center(child: Text('Žádné výzvy.'));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: challenges.map(_buildChallengeCard).toList(),
    );
  }

  Widget _buildChallengeCard(Map<String, dynamic> challenge) {
    final isActive = challenge['is_active'] == true;
    final subtitle = [
      'Start: ${formatDateTimeOrDash(DateTime.tryParse((challenge['start_date'] ?? '').toString())?.toLocal(), includeTime: false)}',
      'Týmy: ${challenge['team_names']}',
      if (!isActive) 'Konec: ${formatDateTimeOrDash(DateTime.tryParse((challenge['end_date'] ?? '').toString())?.toLocal(), includeTime: false)}',
      if (!isActive) _winnerLabel(challenge),
    ].join('\n');
    return Card(
      margin: const EdgeInsets.all(8),
      child: ListTile(
        leading: Icon(isActive ? Icons.flag : Icons.check_circle, color: isActive ? Colors.orange : Colors.green),
        title: Text(challenge['name'].toString(), style: const TextStyle(fontWeight: FontWeight.bold)),
        subtitle: Text(subtitle),
        trailing: Text('${challenge['distance']} km', style: const TextStyle(fontWeight: FontWeight.bold)),
        onTap: isActive ? () => _showChallengeDetails(challenge) : null,
      ),
    );
  }

  Future<void> _showChallengeDetails(Map<String, dynamic> challenge) async {
    if (challenge['is_active'] != true) return;

    final isActive = challenge['is_active'] == true;
    final profile = await SupabaseService.loadCurrentProfile();
    if (!mounted) return;

    final myTeam = (profile['team_name'] ?? '').toString().trim();
    if (myTeam.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('V profilu nemáte nastavený tým.'), backgroundColor: Colors.orange),
      );
      return;
    }

    var teams = parseCsvLabels((challenge['team_names'] ?? '').toString());
    var isUpdating = false;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final isTeamAdded = teams.any((team) => team.toLowerCase() == myTeam.toLowerCase());

          Future<void> updateTeamMembership(bool addTeam) async {
            setDialogState(() => isUpdating = true);
            final updatedTeams = [...teams];
            if (addTeam && !isTeamAdded) {
              updatedTeams.add(myTeam);
            } else if (!addTeam) {
              updatedTeams.removeWhere((team) => team.toLowerCase() == myTeam.toLowerCase());
            }
            try {
              await _supabase
                  .from('challenges')
                  .update({'team_names': updatedTeams.join(', ')})
                  .eq('id', challenge['id']);
              teams = updatedTeams;
              challenge['team_names'] = updatedTeams.join(', ');
              if (mounted) setState(() {});
              setDialogState(() => isUpdating = false);
            } catch (e) {
              if (!mounted) return;
              setDialogState(() => isUpdating = false);
              ScaffoldMessenger.of(this.context).showSnackBar(
                SnackBar(content: Text(formatBackendError(e, context: 'Úprava týmů výzvy selhala')), backgroundColor: Colors.red),
              );
            }
          }

          return AlertDialog(
            title: Text(challenge['name'].toString()),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Začátek: ${formatDateTimeOrDash(DateTime.tryParse((challenge['start_date'] ?? '').toString())?.toLocal(), includeTime: false)}'),
                const SizedBox(height: 12),
                const Text('Přiřazené týmy:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(teams.isEmpty ? 'Zatím žádný tým' : teams.join(', ')),
                const SizedBox(height: 16),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Účastnit se výzvy'),
                  value: isTeamAdded,
                  onChanged: isActive && !isUpdating ? updateTeamMembership : null,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _ChallengeCompletion {
  const _ChallengeCompletion(this.winnerTeam, this.endDate);

  final String winnerTeam;
  final DateTime endDate;
}

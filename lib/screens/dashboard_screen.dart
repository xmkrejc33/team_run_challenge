import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:health/health.dart';

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
  final _supabase = Supabase.instance.client; // Instance Supabase klienta

  DateTime? _lastSyncAt; // Čas poslední synchronizace dat z Health Connect
  bool _isSyncingHealth = false; // Indikuje, zda se probíhá synchronizace s Health Connect
  bool _isChallengesLoading = true; // Indikuje, zda se načítávají výzvy
  List<Map<String, dynamic>> _dashboardChallenges = []; // Seznam výzv pro domovskou stránku
  int? _selectedChallengeId; // ID vybrané výzvy
  String? _dashboardChallengesError; // Chyba při načítání výzv pro domovskou stránku
  String? _dashboardActivitiesError; // Chyba při načítání aktivit pro domovskou stránku
  String _currentRunnerName = ''; // Jméno aktuálního uživatele
  String? _currentRunnerAvatarBase64; // Bázový64 kód obrázku profilu aktuálního uživatele

  @override
  void initState() {
    super.initState();
    _loadLastSyncTime(); // Načítá čas poslední synchronizace ze SharedPreferences
    _loadChallengesForDashboard(); // Načítá výzvy pro domovskou stránku
    _loadCurrentRunnerVisuals(); // Načítá vizuální informace aktuálního uživatele (jméno a obrázek)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.syncOnStart) {
        _syncGoogleHealthConnect(); // Synchronizuje data z Health Connect při prvním načtení stránky
      }
    });
  }

  void _loadCurrentRunnerVisuals() {
    final user = _supabase.auth.currentUser;
    final metadata = user?.userMetadata ?? {};
    _currentRunnerName = (metadata['runner_name'] ?? '').toString().trim(); // Nastaví jméno aktuálního uživatele
    final avatarRaw = (metadata['avatar_base64'] ?? '').toString().trim();
    _currentRunnerAvatarBase64 = avatarRaw.isEmpty ? null : avatarRaw; // Nastaví bázový64 kód obrázku profilu aktuálního uživatele
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
    return formatDateTimeOrDash(dateTime); // Formátuje datum a čas nebo vrátí "-"
  }

  String _formatIsoDateTime(String? iso) {
    return formatDateTimeOrDash(DateTime.tryParse(iso ?? '')?.toLocal()); // Formátuje ISO datum a čas nebo vrátí "-"
  }

  Future<List<Map<String, dynamic>>> _fetchActivitiesForDashboard() async {
    try {
      final data = await SupabaseService.loadActivitiesSafe(ascending: false); // Načítá aktivity ze databáze
      _dashboardActivitiesError = null; // Resetuje chybu při načítání aktivit pro domovskou stránku
      return data;
    } catch (e) {
      debugPrint(formatBackendError(e, context: 'Dashboard activities safe load failed')); // Vypíše chybu při načítání aktivit pro domovskou stránku
      _dashboardActivitiesError = formatBackendError(e, context: 'activities query failed'); // Nastaví chybu při načítání aktivit pro domovskou stránku
      return [];
    }
  }

  Future<void> _loadLastSyncTime() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('last_sync_time');
      if (stored != null) {
        setState(() {
          _lastSyncAt = DateTime.tryParse(stored)?.toLocal(); // Načítá čas poslední synchronizace ze SharedPreferences
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
          _lastSyncAt = DateTime.parse(response['created_at']).toLocal(); // Nastaví čas poslední synchronizace
        });
  }
    } catch (e) {
      debugPrint('Chyba načítání poslední synchronizace: $e');
    }
  }

  Future<void> _saveLastSyncTime(DateTime time) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_sync_time', time.toUtc().toIso8601String()); // Ukládá čas poslední synchronizace do SharedPreferences
    } catch (e) {
      debugPrint('Chyba ukládání poslední synchronizace: $e');
    }
  }

  Future<void> _syncGoogleHealthConnect() async {
    setState(() => _isSyncingHealth = true); // Nastaví indikátor synchronizace na true

    final user = _supabase.auth.currentUser;
    final userMetadata = user?.userMetadata ?? {};
    final String loggedInRunnerName = userMetadata['runner_name'] ?? 'Anonymní běžec'; // Nastaví jméno aktuálního uživatele nebo "Anonymní běžec", pokud není nastaveno
    final int loggedInTeamId = userMetadata['team_id'] ?? 0; // Nastaví ID týmu aktuálního uživatele nebo 0, pokud není nastaveno
    final String loggedInTeamName = userMetadata['team_name'] ?? 'Neznámý tým'; // Nastaví název týmu aktuálního uživatele nebo "Neznámý tým", pokud není nastaveno

    if (loggedInTeamId == 0) {
      _showSnackBar('Chyba: Nebyl nalezen váš tým v profilu.', Colors.red); // Zobrazí snackbar s chybou
      setState(() => _isSyncingHealth = false); // Nastaví indikátor synchronizace na false
      return;
    }

    try {
      if (!await HealthHelper.checkHealthConnectAvailability()) { // Kontroluje dostupnost Health Connect
        _showSnackBar('Health Connect není na tomto zařízení dostupný. Otevři Health Connect a zkontroluj, zda je nainstalovaný a aktivní.', Colors.orange); // Zobrazí snackbar s upozorněním
    if (!mounted) return;
        setState(() => _isSyncingHealth = false); // Nastaví indikátor synchronizace na false
        return;
      }

      if (!await HealthHelper.requestDistanceAccess()) { // Požaduje přístup k datům o vzdálenosti v Health Connect
        _showSnackBar('Health Connect neudělil oprávnění. Otevři Health Connect a povol aplikaci přístup k datům o vzdálenosti.', Colors.orange); // Zobrazí snackbar s upozorněním
        if (!mounted) return;
        setState(() => _isSyncingHealth = false); // Nastaví indikátor synchronizace na false
        return;
      }

      final now = DateTime.now(); // Aktuální čas
      final defaultStart = DateTime(now.year, now.month, now.day); // Výchozí datum začátku (dnešek)
      var startTime = _lastSyncAt ?? defaultStart; // Datum začátku synchronizace nebo výchozí datum

      List<HealthDataPoint> healthData = await HealthHelper.getHealthDataFromTypes(
        types: [HealthDataType.DISTANCE_DELTA], // Požadované typy dat (vzdálenost)
        startTime: startTime, // Datum začátku synchronizace
        endTime: now, // Aktuální datum
                  );
      if (healthData.isEmpty && _lastSyncAt != null) { // Pokud nejsou dostupná žádná data a je nastaveno poslední čas synchronizace
        startTime = defaultStart; // Nastaví datum začátku na výchozí datum
        healthData = await HealthHelper.getHealthDataFromTypes(
          types: [HealthDataType.DISTANCE_DELTA], // Požadované typy dat (vzdálenost)
          startTime: startTime, // Datum začátku synchronizace
          endTime: now, // Aktuální datum
        );
      }

      List<HealthDataPoint> workoutData = await HealthHelper.getHealthDataFromTypes(
        types: const [HealthDataType.WORKOUT], // Požadované typy dat (cvičení)
        startTime: startTime, // Datum začátku synchronizace
        endTime: now, // Aktuální datum
      );

      final runningSessions = HealthHelper.extractRunningSessionRanges(workoutData); // Extrahuje rozsahy běhu z dat cvičení
      List<DateTimeRange> effectiveRunningSessions = runningSessions;
      if (effectiveRunningSessions.isEmpty) {
        effectiveRunningSessions = await HealthHelper.loadRunningSessionsFromNative(startTime, now);
  }

      if (effectiveRunningSessions.isEmpty) {
        _showSnackBar('Nenalezeny bezecke ExerciseSession. V Health Connect povol Cviceni/Treninky.', Colors.blue); // Zobrazí snackbar s upozorněním
        if (!mounted) return;
        setState(() => _isSyncingHealth = false); // Nastaví indikátor synchronizace na false
        return;
      }

      double totalMetersToday = 0.0; // Celkový počet metrů dneška
      DateTime? activityStartTime;
      DateTime? activityEndTime;
      for (var dataPoint in healthData) {
        final pointStart = dataPoint.dateFrom; // Čas začátku datového bodu
        final pointEnd = dataPoint.dateTo; // Čas konce datového bodu
        if (!HealthHelper.overlapsRunningSession(pointStart, pointEnd, effectiveRunningSessions)) {
          continue; // Ignoruje datový bod, pokud neleží do rozsahu běhu
        }
        if (activityStartTime == null || pointStart.isBefore(activityStartTime)) {
          activityStartTime = pointStart; // Nastaví čas začátku aktivity
        }
        if (activityEndTime == null || pointEnd.isAfter(activityEndTime)) {
          activityEndTime = pointEnd; // Nastaví čas konce aktivity
        }
        if (dataPoint.value is NumericHealthValue) {
          final numericValue = (dataPoint.value as NumericHealthValue).numericValue;
          totalMetersToday += numericValue.toDouble(); // Přidá vzdálenost datového bodu k celkovému počtu metrů
        }
      }

      final activityStart = activityStartTime ?? startTime; // Čas začátku aktivity nebo výchozí datum
      final activityEnd = activityEndTime ?? now; // Čas konce aktivity nebo aktuální datum
      double totalKmFromPhoneToday = totalMetersToday / 1000.0; // Celkový počet kilometrů dneška

      if (totalKmFromPhoneToday <= 0) {
        _showSnackBar('Dnes nemáte v telefonu zaznamenané žádné kilometry. Zvedněte se z gauče! 🏃‍♂️', Colors.blue); // Zobrazí snackbar s upozorněním
        if (!mounted) return;
        setState(() => _isSyncingHealth = false); // Nastaví indikátor synchronizace na false
        return;
      }

      final finalStartIso = startTime.toUtc().toIso8601String(); // Čas začátku synchronizace v UTC formátu ISO 8601
      final response = await _supabase
          .from('activities')
          .select('km')
          .eq('runner_name', loggedInRunnerName)
          .eq('team_name', loggedInTeamName)
          .gte('created_at', finalStartIso);

      double alreadySyncedKm = 0.0; // Celkový počet synchronizovaných kilometrů
      for (var row in response) {
        alreadySyncedKm += (row['km'] as num).toDouble(); // Přidá synchronizované kilometry k celkovému počtu
      }

      double deltaKm = totalKmFromPhoneToday - alreadySyncedKm; // Rozdíl mezi celkovými a již synchronizovanými kilometrami

      if (deltaKm <= 0.05) {
        _showSnackBar('Všechny kilometry z telefonu (${totalKmFromPhoneToday.toStringAsFixed(2)} km) už máte zapsané. 🎉', Colors.green); // Zobrazí snackbar s upozorněním
        if (!mounted) return;
        setState(() => _isSyncingHealth = false); // Nastaví indikátor synchronizace na false
        return;
      }

      final teamData = await _supabase
          .from('teams')
          .select('km')
          .eq('id', loggedInTeamId)
          .single();
      double currentTeamKm = (teamData['km'] as num).toDouble(); // Celkový počet kilometrů týmu
      final selectedTargetKm = _selectedTargetKm(); // Cílová vzdálenost pro vybranou výzvu
      double newTeamKm = (currentTeamKm + deltaKm).clamp(0.0, selectedTargetKm); // Nový počet kilometrů týmu

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
        debugPrint('Chyba při vkládání aktivity se start_time/end_time: $e'); // Vypíše chybu
        try {
          await _supabase.from('activities').insert({
            'team_name': loggedInTeamName,
            'km': deltaKm,
            'runner_name': loggedInRunnerName,
            'start_time': activityStart.toUtc().toIso8601String(),
          });
        } catch (e2) {
          debugPrint('Fallback insert jen se start_time selhal: $e2'); // Vypíše chybu
          await _supabase.from('activities').insert({
            'team_name': loggedInTeamName,
            'km': deltaKm,
            'runner_name': loggedInRunnerName,
          });
        }
      }

      if (!mounted) return;
      setState(() {
        _lastSyncAt = now; // Nastaví čas poslední synchronizace
      });
      await _saveLastSyncTime(now); // Ukládá čas poslední synchronizace do SharedPreferences

      _showSnackBar('Úspěšně synchronizováno! Připsáno +${deltaKm.toStringAsFixed(2)} km z Health Connect.', Colors.green); // Zobrazí snackbar s upozorněním
    } catch (e) {
      debugPrint('Chyba synchronizace zdraví: $e'); // Vypíše chybu
      _showSnackBar('Chyba při komunikaci s Health Connect: $e', Colors.red); // Zobrazí snackbar s chybou
    }

    if (!mounted) return;
    setState(() => _isSyncingHealth = false); // Nastaví indikátor synchronizace na false
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
      appBar: AppBar(title: const Text('Týmové výzvy', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)), // Nastaví titulek stránky a barvu
        backgroundColor: Colors.orange,
        centerTitle: true,
        actions: [buildAppMenu(context)], // Přidá menu do AppBar
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0), // Přidá odsazování k obsahu
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(), // Nastaví fyzické chování pro horizontální posouvání
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, // Nastaví zarovnání položek v sloupci na začátku
          children: [
              Card(
                color: Colors.orange[50], // Nastaví barvu karty
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: const BorderSide(color: Colors.orange)), // Nastaví obrys a rohové úhly karty
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 14.0, horizontal: 16.0), // Přidá odsazování k obsahu karty
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center, // Nastaví zarovnání položek v sloupci na střed
                          children: [
                            const Text(
                              'Datum poslední synchronizace', // Nastaví text pro záhlaví karty
                              style: TextStyle(fontSize: 14, color: Colors.black87), // Nastaví styl textu pro záhlaví karty
                              textAlign: TextAlign.center, // Nastaví zarovnání textu na střed
                            ),
                            const SizedBox(height: 2), // Přidá mezery mezi položkami
                            Text(
                              _formatDateTime(_lastSyncAt), // Formátuje datum poslední synchronizace nebo zobrazí "-"
                              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87), // Nastaví styl textu pro datum poslední synchronizace
                              textAlign: TextAlign.center, // Nastaví zarovnání textu na střed
                            ),
                          ],
                        ),
                      ),
                      if (_isSyncingHealth)
                        const Padding(
                          padding: EdgeInsets.only(left: 12.0), // Přidá odsazování k indikátoru synchronizace
                          child: SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(strokeWidth: 3)), // Zobrazí indikátor synchronizace
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16), // Přidá mezery mezi položkami
              const Text('Vybraná výzva', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), // Nastaví text pro záhlaví vybrané výzvy
              const SizedBox(height: 8), // Přidá mezery mezi položkami
              if (_isChallengesLoading)
                const Center(child: CircularProgressIndicator()) // Zobrazí indikátor načítání, pokud se načítávají výzvy
              else if (_dashboardChallenges.isEmpty)
                const Text('Nejsou dostupné žádné výzvy.') // Zobrazí text, pokud není žádná výzva dostupná
              else
                DropdownButtonFormField<int>(
                  key: ValueKey(_selectedChallengeId), // Nastaví klíč pro DropdownButtonFormField
                  initialValue: _selectedChallengeId, // Nastaví vybrané ID výzvy jako výchozí hodnotu
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(), // Nastaví okraj pro pole
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10), // Přidá odsazování k obsahu pole
                  ),
                  items: _dashboardChallenges.map((challenge) {
                    final name = (challenge['name'] ?? 'Výzva').toString(); // Nastaví název výzvy
                    final dateValue = challenge['start_date']?.toString() ?? ''; // Nastaví datum začátku výzvy
                    final date = DateTime.tryParse(dateValue)?.toLocal(); // Formátuje datum začátku výzvy nebo vrátí null
                    final label = date != null
                        ? '$name (${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year})' // Nastaví text pro DropdownMenuItem
                        : name; // Pokud datum není platné, použije jen název výzvy
                    return DropdownMenuItem<int>(
                      value: challenge['id'] as int, // Nastaví ID výzvy jako hodnotu pro DropdownMenuItem
                      child: Text(label), // Nastaví text pro DropdownMenuItem
                    );
                  }).toList(), // Vytvoří seznam položek pro DropdownButtonFormField
                  onChanged: (value) {
                    setState(() {
                      _selectedChallengeId = value; // Nastaví vybrané ID výzvy
                    });
                    _saveSelectedChallengeId(value); // Ukládá vybrané ID výzvy do SharedPreferences
                  },
                ),
              if (_dashboardChallengesError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8), // Přidá odsazování k textu chyby
                  child: SelectableText(
                    'Diagnostika výzev: ${_dashboardChallengesError!}', // Zobrazí text chyby pro výzvy
                    style: const TextStyle(color: Colors.red, fontSize: 12), // Nastaví styl textu chyby
                  ),
                ),
              const SizedBox(height: 16), // Přidá mezery mezi položkami
              const Text('Průběžný stav závodu', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)), // Nastaví text pro záhlaví průběžného stavu závodu
              const SizedBox(height: 12), // Přidá mezery mezi položkami
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _fetchActivitiesForDashboard(), // Načítá aktivity pro domovskou stránku
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator()); // Zobrazí indikátor načítání, pokud se načítávají aktivity
  }
                  if (snapshot.hasError) {
                    return const Text('Průběžný stav závodu se nepodařilo načíst.'); // Zobrazí text, pokud dojde k chybě při načítání aktivity
}

                  final selectedChallenge = _selectedChallenge(); // Vrátí vybranou výzvu
                  final selectedTeamNames = _selectedChallengeTeamNames(); // Vrátí množinu názvů týmů pro vybranou výzvu
                  final selectedTeamLabels = _selectedChallengeTeamLabels(); // Vrátí seznam názvů týmů pro vybranou výzvu
                  final challengeStartValue = selectedChallenge?['start_date']?.toString() ?? ''; // Nastaví datum začátku vybrané výzvy nebo prázdný řetězec, pokud není nastaveno
                  final challengeStartDate = DateTime.tryParse(challengeStartValue)?.toLocal(); // Formátuje datum začátku vybrané výzvy nebo vrátí null

                  if (selectedTeamLabels.isEmpty) {
                    return const Text('Pro vybranou výzvu nejsou přiřazeny žádné týmy.'); // Zobrazí text, pokud není žádný tým přiřazen k vybrané výzve
                  }

                  final activities = snapshot.data ?? const <Map<String, dynamic>>[]; // Vrátí seznam aktivit nebo prázdný seznam, pokud není dostupný
                  final Map<String, double> kmByTeam = {
                    for (final label in selectedTeamLabels)
                      label.toLowerCase(): 0.0, // Inicializuje mapu s počtem kilometrů pro každý tým
                  };

                  for (final act in activities) {
                    final teamNameRaw = (act['team_name'] ?? '').toString().trim(); // Nastaví název týmu ze aktivity
                    final teamNameKey = teamNameRaw.toLowerCase(); // Převede název týmu na malá písmena a převede ho na text
                    if (!selectedTeamNames.contains(teamNameKey)) continue; // Ignoruje aktivitu, pokud neleží do vybraného týmu

                    if (challengeStartDate != null) {
                      final rawTime = (act['start_time'] ?? act['created_at'] ?? '').toString(); // Nastaví čas začátku aktivity nebo vytvoří prázdný řetězec, pokud není nastaveno
                      final activityTime = DateTime.tryParse(rawTime)?.toLocal(); // Formátuje datum a čas začátku aktivity nebo vrátí null
                      if (activityTime == null || activityTime.isBefore(challengeStartDate)) {
                        continue; // Ignoruje aktivitu, pokud je před datumem začátku vybrané výzvy
                      }
                    }

                    final kmValue = (act['km'] as num?)?.toDouble() ?? 0.0; // Nastaví hodnotu kilometrů ze aktivity nebo vrátí 0, pokud není nastaveno
                    kmByTeam[teamNameKey] = (kmByTeam[teamNameKey] ?? 0.0) + kmValue; // Přidá hodnotu kilometrů k celkovému počtu pro daný tým
                  }

                  final targetKm = _selectedTargetKm(); // Vrátí cílovou vzdálenost pro vybranou výzvu

                  return ListView.builder(
                    shrinkWrap: true, // Nastaví, aby se seznam nezvětšoval podle obsahu
                    physics: const NeverScrollableScrollPhysics(), // Nastaví fyzické chování pro horizontální posouvání
                    itemCount: selectedTeamLabels.length, // Nastaví počet položek v seznamu
                    itemBuilder: (context, index) {
                      final String name = selectedTeamLabels[index]; // Vrátí název týmu ze seznamu
                      final double km = kmByTeam[name.toLowerCase()] ?? 0.0; // Vrátí celkový počet kilometrů pro daný tým

                      final List<Color> teamColors = [
                        Colors.blue,
                        Colors.green,
                        Colors.purple,
                        Colors.teal
                      ];
                      final color = teamColors[index % teamColors.length]; // Nastaví barvu pro karty týmu

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12.0), // Přidá odsazování pod položkou
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
              const SizedBox(height: 16), // Přidá mezery mezi položkami
              const Text('Historie aktivit', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)), // Nastaví text pro záhlaví historie aktivit
              const SizedBox(height: 8), // Přidá mezery mezi položkami
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _fetchActivitiesForDashboard(), // Načítá aktivity pro domovskou stránku
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator()); // Zobrazí indikátor načítání, pokud se načítávají aktivity
                  }
                  if (snapshot.hasError) {
                    return const Text('Historii aktivit se nepodařilo načíst.'); // Zobrazí text, pokud dojde k chybě při načítání aktivity
                  }

                  final selectedChallenge = _selectedChallenge(); // Vrátí vybranou výzvu
                  final selectedTeamNames = _selectedChallengeTeamNames(); // Vrátí množinu názvů týmů pro vybranou výzvu
                  final challengeStartValue = selectedChallenge?['start_date']?.toString() ?? ''; // Nastaví datum začátku vybrané výzvy nebo prázdný řetězec, pokud není nastaveno
                  final challengeStartDate = DateTime.tryParse(challengeStartValue)?.toLocal(); // Formátuje datum začátku vybrané výzvy nebo vrátí null

                  final activities = (snapshot.data ?? const <Map<String, dynamic>>[])
                          .where((act) {
                    final tName = (act['team_name'] ?? '').toString().trim().toLowerCase(); // Nastaví název týmu ze aktivity
                    if (selectedTeamNames.isNotEmpty && !selectedTeamNames.contains(tName)) {
                      return false; // Ignoruje aktivitu, pokud neleží do vybraného týmu
                    }

                    if (challengeStartDate == null) return true; // Pokud není datum začátku vybrané výzvy nastaveno, zahrnuje všechny aktivity

                    final rawTime = (act['start_time'] ?? act['end_time'] ?? act['created_at'] ?? '').toString(); // Nastaví čas začátku nebo konce aktivity nebo vytvoří prázdný řetězec, pokud není nastaveno
                    if (rawTime.isEmpty) return false; // Ignoruje aktivitu, pokud je čas prázdný
                    final activityTime = DateTime.tryParse(rawTime)?.toLocal(); // Formátuje datum a čas začátku nebo konce aktivity nebo vrátí null
                    if (activityTime == null) return false; // Ignoruje aktivitu, pokud je čas null
                    return !activityTime.isBefore(challengeStartDate); // Zahrnuje aktivitu, pokud je datum začátku po datumu začátku vybrané výzvy
                  }).toList(); // Vrátí seznam aktivit, které splňují podmínky

                  if (activities.isEmpty) {
                    return Center(
                      child: Text(
                        _dashboardActivitiesError == null
                            ? 'Pro vybranou výzvu zatím nejsou zapsány žádné aktivity.' // Zobrazí text, pokud není žádná aktivita zapsaná pro vybranou výzvu
                            : 'Pro vybranou výzvu zatím nejsou zapsány žádné aktivity.\n${_dashboardActivitiesError!}', // Zobrazí text s chybou, pokud dojde k chybě při načítání aktivit
                        style: const TextStyle(color: Colors.grey, fontStyle: FontStyle.italic), // Nastaví styl textu
                        textAlign: TextAlign.center, // Nastaví zarovnání textu na střed
                      ),
                    );
                  }

                  return ListView.builder(
                    shrinkWrap: true, // Nastaví, aby se seznam nezvětšoval podle obsahu
                    physics: const NeverScrollableScrollPhysics(), // Nastaví fyzické chování pro horizontální posouvání
                    itemCount: activities.length, // Nastaví počet položek v seznamu
                    itemBuilder: (context, index) {
                      final act = activities[index]; // Vrátí aktivitu ze seznamu
                      final String tName = act['team_name'] ?? 'Neznámý tým'; // Nastaví název týmu nebo "Neznámý tým", pokud není nastaveno
                      final String runnerName = act['runner_name'] ?? 'Anonymní běžec'; // Nastaví jméno uživatele nebo "Anonymní běžec", pokud není nastaveno
                      final double kmValue = (act['km'] as num).toDouble(); // Nastaví hodnotu kilometrů ze aktivity

                      final String startAtRaw = (act['start_time'] ?? '').toString(); // Nastaví čas začátku ze aktivity nebo prázdný řetězec, pokud není nastaveno
                      final String endAtRaw = (act['end_time'] ?? '').toString(); // Nastaví čas konce ze aktivity nebo prázdný řetězec, pokud není nastaveno

                      final sameRunner = runnerName.trim() == _currentRunnerName; // Zjistí, zda je uživatel stejný jako aktuální uživatel
                      final ImageProvider? avatarImage = sameRunner && _currentRunnerAvatarBase64 != null
                              ? MemoryImage(base64Decode(_currentRunnerAvatarBase64!)) // Nastaví obrázek profilu aktuálního uživatele, pokud je stejný jako aktuální uživatel a má nastavený obrázek
                              : null; // Pokud není stejný jako aktuální uživatel nebo nemá nastavený obrázek, použije null

                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6), // Přidá odsazování pod kartou
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.orange.withValues(alpha: 0.15), // Nastaví pozadí pro CircleAvatar
                            backgroundImage: avatarImage, // Nastaví obrázek profilu
                            child: avatarImage == null
                                ? const Icon(Icons.directions_run, color: Colors.orange) // Pokud není nastavený obrázek, zobrazí ikonu běhu
                                : null, // Pokud je nastavený obrázek, nezobrazí žádnou ikonu
                          ),
                          title: Text(
                            runnerName,
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16), // Nastaví styl textu pro jméno uživatele
                          ),
                          subtitle: Text(
                            'Tým: $tName\nStart: ${_formatIsoDateTime(startAtRaw)}\nKonec: ${_formatIsoDateTime(endAtRaw)}', // Nastaví podtitulek s informacemi o aktivitě
                            style: TextStyle(color: Colors.grey[700]), // Nastaví styl textu pro podtitulek
                          ),
                          trailing: Text(
                            '+${kmValue.toStringAsFixed(1)} km', // Nastaví konečný text s počtem kilometrů
                            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.orange), // Nastaví styl konečného textu
                          ),
                          isThreeLine: true, // Nastaví, aby se podtitulek zobrazoval na třech řádcích
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
    double percentage = (current / target).clamp(0.0, 1.0); // Vypočítá procentuální průběh výzvy
    return Card(
      elevation: 4, // Nastaví stíhání karty
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)), // Nastaví obrys a rohové úhly karty
      child: Padding(
        padding: const EdgeInsets.all(16.0), // Přidá odsazování k obsahu karty
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start, // Nastaví zarovnání položek v sloupci na začátku
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween, // Nastaví rozložení položek mezi středem a okraji
              children: [
                Text(name, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)), // Nastaví text pro název týmu
                Text('${current.toStringAsFixed(1)} / ${target.toInt()} km',
                    style: const TextStyle(fontSize: 16, fontWeight: w
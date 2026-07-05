import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:health/health.dart'; // NOVÝ IMPORT 🚀
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:convert';
import 'dart:io';

const String kSupabaseUrl = 'https://xfnfzgragzlwhefniawp.supabase.co';
const String kSupabasePublishableKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhmbmZ6Z3JhZ3psd2hlZm5pYXdwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODI2NDIyNjMsImV4cCI6MjA5ODIxODI2M30.t-5OigDjP6Z0JCD8UneQo_-iyPIq-Z6wkTEOt5XMA4M';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // INICIALIZACE SUPABASE
  await Supabase.initialize(
    url: kSupabaseUrl,
    publishableKey: kSupabasePublishableKey,
  );

  runApp(const TeamChallengeApp());
}

class TeamChallengeApp extends StatelessWidget {
  const TeamChallengeApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Týmová Výzva',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.orange),
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        useMaterial3: true,
      ),
      home: Supabase.instance.client.auth.currentUser == null
          ? const AuthScreen()
          : const ChallengeDashboard(syncOnStart: true),
    );
  }
}

Widget buildAppMenu(BuildContext context) {
  return PopupMenuButton<String>(
    icon: const Icon(Icons.more_vert, color: Colors.white),
    onSelected: (value) async {
      final supabase = Supabase.instance.client;
      switch (value) {
        case 'challenges':
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const ChallengesScreen()));
          break;
        case 'teams':
          Navigator.push(
              context, MaterialPageRoute(builder: (_) => const TeamsScreen()));
          break;
        case 'settings':
          Navigator.push(context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()));
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

String formatBackendError(Object error, {String? context}) {
  final prefix = context == null || context.isEmpty ? '' : '$context: ';
  if (error is PostgrestException) {
    final code = error.code ?? '-';
    final message = error.message;
    final details = error.details ?? '-';
    final hint = error.hint ?? '-';
    return '${prefix}code=$code, message=$message, details=$details, hint=$hint';
  }
  return '$prefix$error';
}

Map<String, dynamic>? tryDecodeJwtPayload(String token) {
  try {
    final parts = token.split('.');
    if (parts.length < 2) return null;
    final normalized = base64Url.normalize(parts[1]);
    final payloadRaw = utf8.decode(base64Url.decode(normalized));
    final payload = jsonDecode(payloadRaw);
    if (payload is Map<String, dynamic>) return payload;
    return null;
  } catch (_) {
    return null;
  }
}

Future<String> requireAuthenticatedUserId(SupabaseClient supabase) async {
  await supabase.auth.refreshSession();

  final user = supabase.auth.currentUser;
  final session = supabase.auth.currentSession;
  final accessToken = session?.accessToken;
  if (user == null ||
      session == null ||
      accessToken == null ||
      accessToken.isEmpty) {
    throw Exception('Session missing (user/session/token)');
  }

  final payload = tryDecodeJwtPayload(accessToken);
  final role = (payload?['role'] ?? '').toString();
  final sub = (payload?['sub'] ?? '').toString();
  if (role != 'authenticated' || sub.isEmpty || sub != user.id) {
    throw Exception(
        'Invalid auth token context (role=$role, sub=$sub, user=${user.id})');
  }

  return user.id;
}

bool isRlsViolationError(Object error) {
  final lower = formatBackendError(error).toLowerCase();
  return lower.contains('42501') ||
      lower.contains('row-level security') ||
      lower.contains('rls');
}

Future<List<Map<String, dynamic>>> fetchPublicRows({
  required String table,
  required String select,
  String? orderColumn,
  bool ascending = true,
  Map<String, String>? extraQuery,
}) async {
  final query = <String, String>{
    'select': select,
  };
  if (extraQuery != null) {
    query.addAll(extraQuery);
  }
  if (orderColumn != null && orderColumn.isNotEmpty) {
    query['order'] = '$orderColumn.${ascending ? 'asc' : 'desc'}';
  }

  final uri =
      Uri.parse('$kSupabaseUrl/rest/v1/$table').replace(queryParameters: query);
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.headers.set('apikey', kSupabasePublishableKey);
    request.headers.set('Authorization', 'Bearer $kSupabasePublishableKey');
    request.headers.set('Accept', 'application/json');

    final response = await request.close();
    final body = await utf8.decodeStream(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
          'public REST $table failed: HTTP ${response.statusCode}, body=$body');
    }

    final decoded = jsonDecode(body);
    if (decoded is! List) {
      throw Exception('public REST $table returned non-list payload: $decoded');
    }

    return decoded.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  } finally {
    client.close(force: true);
  }
}

Future<void> insertRowViaRestWithSession({
  required SupabaseClient supabase,
  required String table,
  required Map<String, dynamic> payload,
}) async {
  final session = supabase.auth.currentSession;
  final accessToken = session?.accessToken;
  if (accessToken == null || accessToken.isEmpty) {
    throw Exception(
        'Missing authenticated session token for REST insert into $table');
  }

  Object? lastError;
  String? lastResponseBody;
  int? lastStatusCode;
  String? lastResponseHeaders;
  final uri = Uri.parse('$kSupabaseUrl/rest/v1/$table');
  final client = HttpClient();
  client.userAgent =
      'Mozilla/5.0 (Android 14; Mobile; rv:128.0) FlutterTeamRun/1.0';
  final bodiesToTry = [
    payload,
    [payload],
  ];
  try {
    for (final requestBody in bodiesToTry) {
      try {
        final request = await client.postUrl(uri);
        request.headers.set('apikey', kSupabasePublishableKey);
        request.headers.set('Authorization', 'Bearer $accessToken');
        request.headers.set('Content-Type', 'application/json; charset=utf-8');
        request.headers.set('Accept', 'application/json');
        request.headers.set('Accept-Language', 'cs-CZ,cs;q=0.9,en;q=0.8');
        request.headers.set('Accept-Profile', 'public');
        request.headers.set('Content-Profile', 'public');
        request.headers.set('Prefer', 'return=minimal');
        request.add(utf8.encode(jsonEncode(requestBody)));

        final response = await request.close();
        final body = await utf8.decodeStream(response);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          lastStatusCode = response.statusCode;
          lastResponseBody = body;
          final headers = <String>[];
          response.headers.forEach((name, values) {
            headers.add('$name=${values.join(',')}');
          });
          lastResponseHeaders = headers.join('; ');
          throw Exception(
              'REST insert $table HTTP ${response.statusCode}, body=$body, sent=${jsonEncode(requestBody)}');
        }
        return;
      } catch (e) {
        lastError = e;
      }
    }
  } finally {
    client.close(force: true);
  }

  final lowerHeaders = (lastResponseHeaders ?? '').toLowerCase();
  final lowerBody = (lastResponseBody ?? '').toLowerCase();
  final looksLikeEdgeBlock =
      lowerHeaders.contains('__cf_bm') || lowerBody == 'bad request';
  final edgeHint = looksLikeEdgeBlock
      ? 'Likely blocked before PostgREST (edge/WAF), response is generic Bad Request with Cloudflare marker.'
      : '-';

  throw Exception(
      'REST insert $table failed: $lastError | status=$lastStatusCode | body=$lastResponseBody | headers=$lastResponseHeaders | edgeHint=$edgeHint');
}

Future<List<Map<String, dynamic>>> loadTeamsSafe(
  SupabaseClient supabase, {
  bool ascending = true,
}) async {
  dynamic data;
  try {
    data = await fetchPublicRows(
      table: 'teams',
      select: 'id,name,km,originator_id',
      orderColumn: 'id',
      ascending: ascending,
    );
  } catch (e1) {
    debugPrint(
        formatBackendError(e1, context: 'teams public REST read failed'));
    try {
      data = await supabase
          .from('teams')
          .select('id, name, km, originator_id')
          .order('id', ascending: ascending);
    } catch (e2) {
      debugPrint(
          formatBackendError(e2, context: 'teams select(id,name,km) failed'));
      try {
        data = await supabase
            .from('teams')
            .select('id, name, km')
            .order('id', ascending: ascending);
      } catch (e3) {
        debugPrint(
            formatBackendError(e3, context: 'teams select(id,name) failed'));
        data = await supabase.from('teams').select('id, name');
      }
    }
  }

  final rows = List<Map<String, dynamic>>.from(data);
  return rows.map((row) {
    final normalized = Map<String, dynamic>.from(row);
    normalized['name'] = (normalized['name'] ?? '').toString();
    normalized['km'] = (normalized['km'] as num?)?.toDouble() ?? 0.0;
    normalized['originator_id'] = normalized['originator_id']?.toString();
    return normalized;
  }).toList();
}

Future<List<Map<String, dynamic>>> loadActivitiesSafe(
  SupabaseClient supabase, {
  String? runnerName,
  String? teamName,
  bool ascending = false,
}) async {
  dynamic data;
  PostgrestFilterBuilder<List<Map<String, dynamic>>> q =
      supabase.from('activities').select(
            'id, team_name, runner_name, km, start_time, end_time, created_at',
          );
  if (runnerName != null && runnerName.isNotEmpty) {
    q = q.eq('runner_name', runnerName);
  }
  if (teamName != null && teamName.isNotEmpty) {
    q = q.eq('team_name', teamName);
  }

  try {
    data = await q.order('created_at', ascending: ascending);
  } catch (e1) {
    debugPrint(
        formatBackendError(e1, context: 'activities select(full) failed'));
    PostgrestFilterBuilder<List<Map<String, dynamic>>> q2 = supabase
        .from('activities')
        .select('id, team_name, runner_name, km, created_at');
    if (runnerName != null && runnerName.isNotEmpty) {
      q2 = q2.eq('runner_name', runnerName);
    }
    if (teamName != null && teamName.isNotEmpty) {
      q2 = q2.eq('team_name', teamName);
    }

    try {
      data = await q2.order('created_at', ascending: ascending);
    } catch (e2) {
      debugPrint(formatBackendError(e2,
          context: 'activities select(fallback) failed'));
      final extraQuery = <String, String>{};
      if (runnerName != null && runnerName.isNotEmpty) {
        extraQuery['runner_name'] = 'eq.$runnerName';
      }
      if (teamName != null && teamName.isNotEmpty) {
        extraQuery['team_name'] = 'eq.$teamName';
      }
      data = await fetchPublicRows(
        table: 'activities',
        select: 'id,team_name,runner_name,km,start_time,end_time,created_at',
        orderColumn: 'created_at',
        ascending: ascending,
        extraQuery: extraQuery,
      );
    }
  }

  final rows = List<Map<String, dynamic>>.from(data);
  return rows.map((row) {
    final normalized = Map<String, dynamic>.from(row);
    normalized['team_name'] = (normalized['team_name'] ?? '').toString();
    normalized['runner_name'] = (normalized['runner_name'] ?? '').toString();
    normalized['km'] = (normalized['km'] as num?)?.toDouble() ?? 0.0;
    normalized['start_time'] = normalized['start_time']?.toString();
    normalized['end_time'] = normalized['end_time']?.toString();
    normalized['created_at'] = normalized['created_at']?.toString();
    return normalized;
  }).toList();
}

List<DateTimeRange> extractRunningSessionRanges(
    List<HealthDataPoint> workoutPoints) {
  final ranges = <DateTimeRange>[];
  for (final point in workoutPoints) {
    if (point.type != HealthDataType.WORKOUT) continue;
    final workoutTypeName = resolveWorkoutTypeName(point).toLowerCase();
    final isRunning = workoutTypeName.contains('running') ||
        workoutTypeName == 'run' ||
        workoutTypeName.contains('run_');
    if (!isRunning) continue;

    ranges.add(DateTimeRange(
        start: point.dateFrom.toLocal(), end: point.dateTo.toLocal()));
  }
  return ranges;
}

List<String> extractWorkoutTypeNames(List<HealthDataPoint> workoutPoints) {
  final names = <String>[];
  for (final point in workoutPoints) {
    if (point.type != HealthDataType.WORKOUT) continue;
    final typeName = resolveWorkoutTypeName(point);
    if (typeName.isNotEmpty) {
      names.add(typeName);
    }
  }
  return names;
}

String resolveWorkoutTypeName(HealthDataPoint point) {
  if (point.value is WorkoutHealthValue) {
    return (point.value as WorkoutHealthValue).workoutActivityType.name;
  }

  final summaryType = point.workoutSummary?.workoutType.trim();
  if (summaryType != null && summaryType.isNotEmpty) {
    return summaryType;
  }

  final metadata = point.metadata;
  if (metadata != null) {
    final candidates = [
      metadata['workout_type'],
      metadata['workoutType'],
      metadata['workoutActivityType'],
      metadata['exercise_type'],
      metadata['exerciseType'],
    ];
    for (final candidate in candidates) {
      final value = candidate?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
  }

  return '';
}

String compactWorkoutTypePreview(List<String> typeNames, {int limit = 3}) {
  if (typeNames.isEmpty) return 'zadne';
  final unique = typeNames.toSet().toList();
  final preview = unique.take(limit).join(', ');
  return unique.length > limit ? '$preview, ...' : preview;
}

bool overlapsRunningSession(
    DateTime start, DateTime end, List<DateTimeRange> sessions) {
  for (final session in sessions) {
    if (start.isBefore(session.end) && end.isAfter(session.start)) {
      return true;
    }
  }
  return false;
}

Future<List<DateTimeRange>> loadRunningSessionsFromNative(
  MethodChannel channel,
  DateTime start,
  DateTime end,
) async {
  final response = await channel.invokeMethod<Map<dynamic, dynamic>>(
    'getRunningSessionsInRange',
    {
      'startMillis': start.toUtc().millisecondsSinceEpoch,
      'endMillis': end.toUtc().millisecondsSinceEpoch,
    },
  );

  final sessionItems = (response?['runningSessions'] as List?) ?? const [];
  final ranges = <DateTimeRange>[];
  for (final item in sessionItems) {
    if (item is! Map) continue;
    final startMs = item['startMillis'] as int?;
    final endMs = item['endMillis'] as int?;
    if (startMs == null || endMs == null) continue;
    ranges.add(
      DateTimeRange(
        start:
            DateTime.fromMillisecondsSinceEpoch(startMs, isUtc: true).toLocal(),
        end: DateTime.fromMillisecondsSinceEpoch(endMs, isUtc: true).toLocal(),
      ),
    );
  }
  return ranges;
}

Future<List<Map<String, dynamic>>> loadChallengesSafe(
  SupabaseClient supabase, {
  bool ascending = false,
}) async {
  dynamic data;
  try {
    data = await fetchPublicRows(
      table: 'challenges',
      select: 'id,name,start_date,distance,team_names,is_active,originator_id',
      orderColumn: 'start_date',
      ascending: ascending,
    );
  } catch (e1) {
    debugPrint(
        formatBackendError(e1, context: 'challenges public REST read failed'));
    try {
      data = await supabase
          .from('challenges')
          .select(
              'id, name, start_date, distance, team_names, is_active, originator_id')
          .order('start_date', ascending: ascending);
    } catch (e2) {
      debugPrint(
          formatBackendError(e2, context: 'challenges select(full) failed'));
      try {
        data = await supabase
            .from('challenges')
            .select('id, name, start_date, distance, team_names, is_active')
            .order('start_date', ascending: ascending);
      } catch (e3) {
        debugPrint(formatBackendError(e3,
            context: 'challenges select(no is_active) failed'));
        data = await supabase
            .from('challenges')
            .select('id, name, start_date, distance, team_names');
      }
    }
  }

  final rows = List<Map<String, dynamic>>.from(data);
  return rows.map((row) {
    final normalized = Map<String, dynamic>.from(row);
    normalized['name'] = (normalized['name'] ?? '').toString();
    normalized['team_names'] = (normalized['team_names'] ?? '').toString();
    normalized['is_active'] = normalized['is_active'] == false ? false : true;
    normalized['distance'] =
        (normalized['distance'] as num?)?.toDouble() ?? 0.0;
    normalized['originator_id'] = normalized['originator_id']?.toString();
    return normalized;
  }).toList();
}

// ==========================================
// OBRAZOVKA PŘIHLÁŠENÍ / REGISTRACE
// ==========================================
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
      final data = await loadTeamsSafe(_supabase, ascending: true);
      setState(() {
        _availableTeams = data;
        if (_availableTeams.isNotEmpty) {
          _selectedTeamId = _availableTeams.first['id'] as int;
        }
        _isLoadingTeams = false;
      });
    } catch (e) {
      debugPrint(
          formatBackendError(e, context: 'Chyba při načítání týmů z DB'));
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

        final selectedTeam =
            _availableTeams.firstWhere((t) => t['id'] == _selectedTeamId);
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
            final existing = await _supabase
                .from('team_members')
                .select('id')
                .eq('team_id', _selectedTeamId as int)
                .eq('user_id', userId)
                .limit(1);

            if ((existing as List).isEmpty) {
              await _supabase.from('team_members').insert({
                'team_id': _selectedTeamId,
                'user_id': userId,
                'runner_name': runnerName,
              });
            } else {
              await _supabase
                  .from('team_members')
                  .update({'runner_name': runnerName})
                  .eq('team_id', _selectedTeamId as int)
                  .eq('user_id', userId);
            }
          } catch (e) {
            debugPrint('team_members při registraci přeskočeno: $e');
          }
        }
      } else {
        await _supabase.auth
            .signInWithPassword(email: email, password: password);
      }

      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
              builder: (context) =>
                  const ChallengeDashboard(syncOnStart: true)),
          (route) => false,
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Chyba: ${e.toString()}'),
              backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(_isSignUp ? 'Registrace do Výzvy' : 'Přihlášení'),
          backgroundColor: Colors.orange),
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
                  TextField(
                    controller: _emailController,
                    decoration: const InputDecoration(
                        labelText: 'E-mail', border: OutlineInputBorder()),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passwordController,
                    decoration: const InputDecoration(
                        labelText: 'Heslo', border: OutlineInputBorder()),
                    obscureText: true,
                  ),
                  if (_isSignUp) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _nameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                          labelText: 'Vaše jméno',
                          border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 16),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: EdgeInsets.only(bottom: 8.0),
                        child: Text('Vyberte svůj tým:',
                            style: TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ),
                    _isLoadingTeams
                        ? const CircularProgressIndicator()
                        : _availableTeams.isEmpty
                            ? const Text(
                                'V databázi nebyly nalezeny žádné týmy.',
                                style: TextStyle(color: Colors.red))
                            : DropdownButtonFormField<int>(
                                initialValue: _selectedTeamId,
                                decoration: const InputDecoration(
                                  labelText: 'Vyberte svůj tým',
                                  border: OutlineInputBorder(),
                                ),
                                items: _availableTeams.map((team) {
                                  return DropdownMenuItem<int>(
                                    value: team['id'] as int,
                                    child: Text(team['name'] ?? 'Tým'),
                                  );
                                }).toList(),
                                onChanged: (value) {
                                  setState(() {
                                    _selectedTeamId = value;
                                  });
                                },
                              ),
                  ],
                  const SizedBox(height: 20),
                  ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.orange,
                      minimumSize: const Size.fromHeight(45),
                    ),
                    child: Text(_isSignUp ? 'Zaregistrovat se' : 'Přihlásit se',
                        style: const TextStyle(color: Colors.white)),
                  ),
                  TextButton(
                    onPressed: () => setState(() => _isSignUp = !_isSignUp),
                    child: Text(_isSignUp
                        ? 'Už máte účet? Přihlaste se'
                        : 'Nemáte účet? Zaregistrujte se'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ==========================================
// HLAVNÍ DASHBOARD (S AUTOMATICKOU SYNCHRONIZACÍ)
// ==========================================
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
      final challengeList =
          await loadChallengesSafe(_supabase, ascending: false);
      int? selectedId = _selectedChallengeId ?? storedSelectedId;

      if (challengeList.isNotEmpty) {
        final selectedExists = selectedId != null &&
            challengeList.any((c) => c['id'] == selectedId);
        if (!selectedExists) {
          final active =
              challengeList.where((c) => c['is_active'] == true).toList();
          selectedId = (active.isNotEmpty
              ? active.first
              : challengeList.first)['id'] as int;
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
      debugPrint(
          formatBackendError(e, context: 'Chyba načítání výzev na dashboardu'));
      if (!mounted) return;
      setState(() {
        _dashboardChallengesError =
            formatBackendError(e, context: 'challenges query failed');
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
    final challenge = _selectedChallenge();
    final raw = (challenge?['team_names'] ?? '').toString();
    if (raw.isEmpty) return [];

    return raw
        .split(',')
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
  }

  Set<String> _selectedChallengeTeamNames() {
    final challenge = _selectedChallenge();
    final raw = (challenge?['team_names'] ?? '').toString();
    if (raw.isEmpty) return {};

    return raw
        .split(',')
        .map((name) => name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
  }

  double _selectedTargetKm() {
    final challenge = _selectedChallenge();
    return (challenge?['distance'] as num?)?.toDouble() ?? _defaultTargetKm;
  }

  String _formatDateTime(DateTime? dateTime) {
    if (dateTime == null) return '--.--.---- --:--';
    return '${dateTime.day.toString().padLeft(2, '0')}.${dateTime.month.toString().padLeft(2, '0')}.${dateTime.year} ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}';
  }

  String _formatIsoDateTime(String? iso) {
    if (iso == null || iso.isEmpty) return '--.--.---- --:--';
    return _formatDateTime(DateTime.tryParse(iso)?.toLocal());
  }

  Future<List<Map<String, dynamic>>> _fetchActivitiesForDashboard() async {
    try {
      final data = await loadActivitiesSafe(_supabase, ascending: false);
      _dashboardActivitiesError = null;
      return data;
    } catch (e) {
      debugPrint(formatBackendError(e,
          context: 'Dashboard activities safe load failed'));
      _dashboardActivitiesError =
          formatBackendError(e, context: 'activities query failed');
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

// JÁDRO PUDLA: Definitivně opravená synchronizace podle typové kontroly Dartu
  Future<void> _syncGoogleHealthConnect() async {
    setState(() => _isSyncingHealth = true);

    final user = _supabase.auth.currentUser;
    final userMetadata = user?.userMetadata ?? {};
    final String loggedInRunnerName =
        userMetadata['runner_name'] ?? 'Anonymní běžec';
    final int loggedInTeamId = userMetadata['team_id'] ?? 0;
    final String loggedInTeamName = userMetadata['team_name'] ?? 'Neznámý tým';

    if (loggedInTeamId == 0) {
      _showSnackBar('Chyba: Nebyl nalezen váš tým v profilu.', Colors.red);
      setState(() => _isSyncingHealth = false);
      return;
    }

    try {
      final MethodChannel healthChannel =
          const MethodChannel('team_run_challenge/health_connect');
      final Health health = Health();
      debugPrint('🔍 DEBUG: Spouštím Health Connect flow...');
      await health.configure();
      debugPrint('🔍 DEBUG: health.configure() hotovo');

      final types = [
        HealthDataType.DISTANCE_DELTA,
      ];

      debugPrint('🔍 DEBUG: Kontroluji dostupnost Health Connect...');
      final isAvailable = await healthChannel
              .invokeMethod<bool>('checkHealthConnectAvailability') ??
          false;
      debugPrint('🔍 DEBUG: isHealthConnectAvailable = $isAvailable');

      if (!isAvailable) {
        debugPrint('❌ DEBUG: Health Connect není dostupný na tomto zařízení.');
        _showSnackBar(
            'Health Connect není na tomto zařízení dostupný. Otevři Health Connect a zkontroluj, zda je nainstalovaný a aktivní.',
            Colors.orange);
        setState(() => _isSyncingHealth = false);
        return;
      }

      debugPrint('🔍 DEBUG: Vyžaduji oprávnění přes Android Health Connect...');
      final bool hasPermissions =
          await healthChannel.invokeMethod<bool>('requestDistanceAccess') ??
              false;
      debugPrint('🔍 DEBUG: native requestDistanceAccess = $hasPermissions');

      if (!hasPermissions) {
        debugPrint('❌ DEBUG: Permissions nejsou povolena!');
        _showSnackBar(
            'Health Connect neudělil oprávnění. Otevři Health Connect a povol aplikaci přístup k datům o vzdálenosti.',
            Colors.orange);
        setState(() => _isSyncingHealth = false);
        return;
      }

      final hasWorkoutPermissions = await health.requestAuthorization(
        [
          HealthDataType.DISTANCE_DELTA,
          HealthDataType.WORKOUT,
        ],
        permissions: [
          HealthDataAccess.READ,
          HealthDataAccess.READ,
        ],
      );
      if (!hasWorkoutPermissions) {
        _showSnackBar(
          'Health Connect neudělil oprávnění na ExerciseSession (WORKOUT). Bez toho nejde filtrovat pouze běh.',
          Colors.orange,
        );
        setState(() => _isSyncingHealth = false);
        return;
      }

      debugPrint('✅ DEBUG: Health Connect permissions OK!');

      final now = DateTime.now();
      final defaultStart = DateTime(now.year, now.month, now.day);
      var startTime = _lastSyncAt ?? defaultStart;

      debugPrint(
          '🔍 DEBUG: Načítám data z Health Connect od $startTime do $now...');
      List<HealthDataPoint> healthData = await health.getHealthDataFromTypes(
        types: types,
        startTime: startTime,
        endTime: now,
      );
      if (healthData.isEmpty && _lastSyncAt != null) {
        debugPrint(
            '🔍 DEBUG: Nula datapointů od poslední synchronizace, zkouším od začátku dne...');
        startTime = defaultStart;
        healthData = await health.getHealthDataFromTypes(
          types: types,
          startTime: startTime,
          endTime: now,
        );
      }

      List<HealthDataPoint> workoutData = [];
      try {
        workoutData = await health.getHealthDataFromTypes(
          types: const [HealthDataType.WORKOUT],
          startTime: startTime,
          endTime: now,
        );
      } catch (e) {
        debugPrint('Chyba načítání workout sessions: $e');
      }

      final runningSessions = extractRunningSessionRanges(workoutData);
      List<DateTimeRange> effectiveRunningSessions = runningSessions;
      if (effectiveRunningSessions.isEmpty) {
        try {
          effectiveRunningSessions = await loadRunningSessionsFromNative(
              healthChannel, startTime, now);
          debugPrint(
              'Native running sessions fallback count: ${effectiveRunningSessions.length}');
        } catch (e) {
          debugPrint('Native running sessions fallback failed: $e');
        }
      }

      if (effectiveRunningSessions.isEmpty) {
        final workoutTypeNames = extractWorkoutTypeNames(workoutData);
        final preview = compactWorkoutTypePreview(workoutTypeNames);
        _showSnackBar(
          'Nenalezeny bezecke ExerciseSession. Workout session: ${workoutData.length}, typy: $preview. V Health Connect povol Cviceni/Treninky.',
          Colors.blue,
        );
        setState(() => _isSyncingHealth = false);
        return;
      }

      debugPrint('🔍 DEBUG: Počet Health datapointů = ${healthData.length}');

      // 3. Spočítáme celkovou dnešní vzdálenost, začátek a konec aktivity
      double totalMetersToday = 0.0;
      DateTime? activityStartTime;
      DateTime? activityEndTime;
      for (var dataPoint in healthData) {
        final pointStart = dataPoint.dateFrom;
        final pointEnd = dataPoint.dateTo;
        if (!overlapsRunningSession(
            pointStart, pointEnd, effectiveRunningSessions)) {
          continue;
        }
        if (activityStartTime == null ||
            pointStart.isBefore(activityStartTime)) {
          activityStartTime = pointStart;
        }
        if (activityEndTime == null || pointEnd.isAfter(activityEndTime)) {
          activityEndTime = pointEnd;
        }
        if (dataPoint.value is NumericHealthValue) {
          final numericValue =
              (dataPoint.value as NumericHealthValue).numericValue;
          totalMetersToday += numericValue.toDouble();
        }
      }

      final activityStart = activityStartTime ?? startTime;
      final activityEnd = activityEndTime ?? now;
      double totalKmFromPhoneToday = totalMetersToday / 1000.0;

      if (totalKmFromPhoneToday <= 0) {
        _showSnackBar(
            'Dnes nemáte v telefonu zaznamenané žádné kilometry. Zvedněte se z gauče! 🏃‍♂️',
            Colors.blue);
        setState(() => _isSyncingHealth = false);
        return;
      }

      // 4. DELTA LOGIKA: Spočítáme, kolik kilometrů už uživatel DNES do Supabase odeslal
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

      // Vypočteme rozdíl (kolik nachodil navíc od poslední synchronizace)
      double deltaKm = totalKmFromPhoneToday - alreadySyncedKm;

      if (deltaKm <= 0.05) {
        _showSnackBar(
            'Všechny kilometry z telefonu (${totalKmFromPhoneToday.toStringAsFixed(2)} km) už máte zapsané. 🎉',
            Colors.green);
        setState(() => _isSyncingHealth = false);
        return;
      }

      // 5. ZÁPIS DO DATABÁZE
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

      setState(() {
        _lastSyncAt = now;
      });
      await _saveLastSyncTime(now);

      _showSnackBar(
          'Úspěšně synchronizováno! Připsáno +${deltaKm.toStringAsFixed(2)} km z Health Connect.',
          Colors.green);
    } catch (e) {
      debugPrint('Chyba synchronizace zdraví: $e');
      _showSnackBar('Chyba při komunikaci s Health Connect: $e', Colors.red);
    }

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
        title: const Text('Týmové výzvy',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: Colors.orange,
        centerTitle: true,
        actions: [
          buildAppMenu(context),
        ],
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
                    side: const BorderSide(color: Colors.orange)),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 14.0, horizontal: 16.0),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            const Text(
                              'Datum poslední synchronizace',
                              style: TextStyle(
                                  fontSize: 14, color: Colors.black87),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _formatDateTime(_lastSyncAt),
                              style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.black87),
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
              const Text('Vybraná výzva',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
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
                    contentPadding:
                        EdgeInsets.symmetric(horizontal: 12, vertical: 10),
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
              const Text('Průběžný stav závodu',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              FutureBuilder<List<Map<String, dynamic>>>(
                future: _fetchActivitiesForDashboard(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (snapshot.hasError) {
                    return const Text(
                        'Průběžný stav závodu se nepodařilo načíst.');
                  }

                  final selectedChallenge = _selectedChallenge();
                  final selectedTeamNames = _selectedChallengeTeamNames();
                  final selectedTeamLabels = _selectedChallengeTeamLabels();
                  final challengeStartValue =
                      selectedChallenge?['start_date']?.toString() ?? '';
                  final challengeStartDate =
                      DateTime.tryParse(challengeStartValue)?.toLocal();

                  if (selectedTeamLabels.isEmpty) {
                    return const Text(
                        'Pro vybranou výzvu nejsou přiřazeny žádné týmy.');
                  }

                  final activities =
                      snapshot.data ?? const <Map<String, dynamic>>[];
                  final Map<String, double> kmByTeam = {
                    for (final label in selectedTeamLabels)
                      label.toLowerCase(): 0.0,
                  };

                  for (final act in activities) {
                    final teamNameRaw =
                        (act['team_name'] ?? '').toString().trim();
                    final teamNameKey = teamNameRaw.toLowerCase();
                    if (!selectedTeamNames.contains(teamNameKey)) continue;

                    if (challengeStartDate != null) {
                      final rawTime =
                          (act['start_time'] ?? act['created_at'] ?? '')
                              .toString();
                      final activityTime =
                          DateTime.tryParse(rawTime)?.toLocal();
                      if (activityTime == null ||
                          activityTime.isBefore(challengeStartDate)) {
                        continue;
                      }
                    }

                    final kmValue = (act['km'] as num?)?.toDouble() ?? 0.0;
                    kmByTeam[teamNameKey] =
                        (kmByTeam[teamNameKey] ?? 0.0) + kmValue;
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
              const Text('Historie aktivit',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
                  final challengeStartValue =
                      selectedChallenge?['start_date']?.toString() ?? '';
                  final challengeStartDate =
                      DateTime.tryParse(challengeStartValue)?.toLocal();

                  final activities =
                      (snapshot.data ?? const <Map<String, dynamic>>[])
                          .where((act) {
                    final tName = (act['team_name'] ?? '')
                        .toString()
                        .trim()
                        .toLowerCase();
                    if (selectedTeamNames.isNotEmpty &&
                        !selectedTeamNames.contains(tName)) {
                      return false;
                    }

                    if (challengeStartDate == null) return true;

                    final rawTime = (act['start_time'] ??
                            act['end_time'] ??
                            act['created_at'] ??
                            '')
                        .toString();
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
                        style: const TextStyle(
                            color: Colors.grey, fontStyle: FontStyle.italic),
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
                      final String runnerName =
                          act['runner_name'] ?? 'Anonymní běžec';
                      final double kmValue = (act['km'] as num).toDouble();

                      final String startAtRaw =
                          (act['start_time'] ?? '').toString();
                      final String endAtRaw =
                          (act['end_time'] ?? '').toString();

                      final sameRunner =
                          runnerName.trim() == _currentRunnerName;
                      final ImageProvider? avatarImage =
                          sameRunner && _currentRunnerAvatarBase64 != null
                              ? MemoryImage(
                                  base64Decode(_currentRunnerAvatarBase64!))
                              : null;

                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                Colors.orange.withValues(alpha: 0.15),
                            backgroundImage: avatarImage,
                            child: avatarImage == null
                                ? const Icon(Icons.directions_run,
                                    color: Colors.orange)
                                : null,
                          ),
                          title: Text(
                            runnerName,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16),
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
                                color: Colors.orange),
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
}

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
  List<Map<String, dynamic>> _teams = [];
  Map<int, bool> _challengeCompleted = {};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  String? _currentUserId() {
    return _supabase.auth.currentUser?.id;
  }

  bool _isChallengeOriginator(Map<String, dynamic> challenge) {
    final currentUserId = _currentUserId();
    if (currentUserId == null || currentUserId.isEmpty) return false;
    final originatorId = (challenge['originator_id'] ?? '').toString();
    return originatorId.isNotEmpty && originatorId == currentUserId;
  }

  bool _canEditChallenge(Map<String, dynamic> challenge) {
    if (!_isChallengeOriginator(challenge)) return false;
    return !_isEndedChallenge(challenge);
  }

  Future<void> _deleteChallenge(Map<String, dynamic> challenge) async {
    if (!_canEditChallenge(challenge)) return;
    final challengeId = challenge['id'] as int?;
    if (challengeId == null) return;

    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            return AlertDialog(
              title: const Text('Smazat výzvu?'),
              content: const Text(
                  'Tato akce je nevratná. Výzva bude trvale odstraněna.'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Zrušit'),
                ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text('Smazat'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (!confirmed) return;

    try {
      await _supabase.from('challenges').delete().eq('id', challengeId);
      await _loadData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Výzva byla smazána.')),
      );
    } catch (e) {
      debugPrint('Chyba mazání výzvy: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nepodařilo se smazat výzvu.')),
      );
    }
  }

  Future<void> _showEditChallengeDialog(Map<String, dynamic> challenge) async {
    if (!_canEditChallenge(challenge)) return;
    final challengeId = challenge['id'] as int?;
    if (challengeId == null) return;

    final availableTeams = await _loadAvailableTeams();
    if (!mounted) return;

    final nameController =
        TextEditingController(text: (challenge['name'] ?? '').toString());
    final distanceController = TextEditingController(
      text: ((challenge['distance'] as num?)?.toDouble() ?? 0.0).toString(),
    );
    DateTime? startDate =
        DateTime.tryParse((challenge['start_date'] ?? '').toString())
            ?.toLocal();

    final selectedTeamNames = _challengeTeamNamesLower(challenge);
    final Set<int> selectedTeamIds = availableTeams
        .where((team) => selectedTeamNames
            .contains((team['name'] ?? '').toString().trim().toLowerCase()))
        .map((team) => team['id'] as int)
        .toSet();

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Upravit výzvu'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration:
                          const InputDecoration(labelText: 'Název výzvy'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: distanceController,
                      decoration:
                          const InputDecoration(labelText: 'Počet kilometrů'),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Datum začátku:'),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(startDate != null
                              ? '${startDate!.day.toString().padLeft(2, '0')}.${startDate!.month.toString().padLeft(2, '0')}.${startDate!.year}'
                              : 'Vyberte datum'),
                        ),
                        TextButton(
                          onPressed: () async {
                            final selected = await showDatePicker(
                              context: context,
                              initialDate: startDate ?? DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100),
                            );
                            if (selected != null) {
                              setState(() {
                                startDate = selected;
                              });
                            }
                          },
                          child: const Text('Vybrat'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Zúčastněné týmy:',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 220,
                      width: double.maxFinite,
                      child: availableTeams.isEmpty
                          ? const Center(child: Text('Žádné týmy k dispozici.'))
                          : ListView(
                              children: availableTeams.map((team) {
                                final id = team['id'] as int;
                                final name = (team['name'] ?? 'Tým').toString();
                                return CheckboxListTile(
                                  value: selectedTeamIds.contains(id),
                                  title: Text(name),
                                  onChanged: (checked) {
                                    setState(() {
                                      if (checked == true) {
                                        selectedTeamIds.add(id);
                                      } else {
                                        selectedTeamIds.remove(id);
                                      }
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Zrušit'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final dialogNavigator = Navigator.of(dialogContext);
                    final dialogMessenger = ScaffoldMessenger.of(dialogContext);
                    final name = nameController.text.trim();
                    final distance = double.tryParse(
                            distanceController.text.replaceAll(',', '.')) ??
                        0.0;
                    if (name.isEmpty ||
                        distance <= 0 ||
                        startDate == null ||
                        selectedTeamIds.isEmpty) {
                      dialogMessenger.showSnackBar(
                        const SnackBar(
                            content: Text('Vyplňte prosím všechny údaje.')),
                      );
                      return;
                    }

                    final selectedNames = availableTeams
                        .where((team) =>
                            selectedTeamIds.contains(team['id'] as int))
                        .map((team) => team['name'] ?? '')
                        .where((name) => name.toString().trim().isNotEmpty)
                        .join(', ');

                    try {
                      await _supabase.from('challenges').update({
                        'name': name,
                        'start_date': startDate!.toUtc().toIso8601String(),
                        'distance': distance,
                        'team_names': selectedNames,
                      }).eq('id', challengeId);
                      dialogNavigator.pop();
                      await _loadData();
                    } catch (e) {
                      debugPrint('Chyba při úpravě výzvy: $e');
                      dialogMessenger.showSnackBar(
                        const SnackBar(
                            content: Text('Nepodařilo se upravit výzvu.')),
                      );
                    }
                  },
                  child: const Text('Uložit'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _loadData() async {
    try {
      final challengeList =
          await loadChallengesSafe(_supabase, ascending: true);
      final teams = await loadTeamsSafe(_supabase, ascending: true);
      final Map<int, bool> completedById = _buildStatusFallback(challengeList);

      try {
        dynamic activities;
        try {
          activities = await _supabase
              .from('activities')
              .select('team_name, km, start_time, created_at')
              .order('id', ascending: false);
        } catch (e1) {
          debugPrint('Challenges activities select(start_time) failed: $e1');
          try {
            activities = await _supabase
                .from('activities')
                .select('team_name, km, created_at')
                .order('id', ascending: false);
          } catch (e2) {
            debugPrint('Challenges activities select(created_at) failed: $e2');
            activities =
                await _supabase.from('activities').select('team_name, km');
          }
        }

        final activityList = List<Map<String, dynamic>>.from(activities);
        completedById
          ..clear()
          ..addAll(_buildChallengeCompletionMap(challengeList, activityList));

        await _syncChallengeStatusToDatabase(challengeList, completedById);
      } catch (e) {
        debugPrint('Chyba výpočtu stavu výzev: $e');
      }

      setState(() {
        _challenges = challengeList;
        _teams = teams;
        _challengeCompleted = completedById;
        _loadError = null;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint(
          formatBackendError(e, context: 'Chyba načítání výzev nebo týmů'));
      setState(() {
        _loadError = formatBackendError(e);
        _isLoading = false;
      });
    }
  }

  Map<int, bool> _buildStatusFallback(
      List<Map<String, dynamic>> challengeList) {
    final Map<int, bool> fallback = {};
    for (final challenge in challengeList) {
      final int? challengeId = challenge['id'] as int?;
      if (challengeId == null) continue;
      fallback[challengeId] = challenge['is_active'] == false;
    }
    return fallback;
  }

  Map<int, bool> _buildChallengeCompletionMap(
    List<Map<String, dynamic>> challengeList,
    List<Map<String, dynamic>> activityList,
  ) {
    final Map<int, bool> completedById = {};

    for (final challenge in challengeList) {
      final int? challengeId = challenge['id'] as int?;
      if (challengeId == null) continue;

      final Set<String> challengeTeams = _challengeTeamNamesLower(challenge);
      final DateTime? startDate = _challengeStartDate(challenge);
      final double targetDistance = _challengeDistance(challenge);

      final Map<String, double> kmByTeam = {
        for (final name in challengeTeams) name: 0.0,
      };

      for (final activity in activityList) {
        final String teamName =
            (activity['team_name'] ?? '').toString().trim().toLowerCase();
        if (!challengeTeams.contains(teamName)) continue;
        if (!_isActivityInChallenge(activity, startDate)) continue;

        final double kmValue = (activity['km'] as num?)?.toDouble() ?? 0.0;
        kmByTeam[teamName] = (kmByTeam[teamName] ?? 0.0) + kmValue;
      }

      bool completed = false;
      for (final totalKm in kmByTeam.values) {
        if (totalKm >= targetDistance) {
          completed = true;
          break;
        }
      }
      completedById[challengeId] = completed;
    }

    return completedById;
  }

  Set<String> _challengeTeamNamesLower(Map<String, dynamic> challenge) {
    final raw = (challenge['team_names'] ?? '').toString();
    if (raw.isEmpty) return {};
    return raw
        .split(',')
        .map((name) => name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
  }

  DateTime? _challengeStartDate(Map<String, dynamic> challenge) {
    final raw = challenge['start_date']?.toString() ?? '';
    return DateTime.tryParse(raw)?.toLocal();
  }

  double _challengeDistance(Map<String, dynamic> challenge) {
    return (challenge['distance'] as num?)?.toDouble() ?? 0.0;
  }

  Future<void> _syncChallengeStatusToDatabase(
    List<Map<String, dynamic>> challengeList,
    Map<int, bool> completedById,
  ) async {
    final List<Future<void>> updates = [];

    for (final challenge in challengeList) {
      final int? challengeId = challenge['id'] as int?;
      if (challengeId == null) continue;

      final bool computedIsActive = !(completedById[challengeId] ?? false);
      final bool? storedIsActive = challenge['is_active'] as bool?;

      // Keep local list consistent with computed status even if DB update fails.
      challenge['is_active'] = computedIsActive;

      if (storedIsActive == computedIsActive) continue;

      updates.add(
        _supabase
            .from('challenges')
            .update({'is_active': computedIsActive})
            .eq('id', challengeId)
            .then((_) {}),
      );
    }

    if (updates.isEmpty) return;

    try {
      await Future.wait(updates);
    } catch (e) {
      debugPrint('Chyba synchronizace is_active do challenges: $e');
    }
  }

  bool _isActivityInChallenge(
      Map<String, dynamic> activity, DateTime? challengeStartDate) {
    if (challengeStartDate == null) return true;
    final raw =
        (activity['start_time'] ?? activity['created_at'] ?? '').toString();
    final activityTime = DateTime.tryParse(raw)?.toLocal();
    if (activityTime == null) return false;
    return !activityTime.isBefore(challengeStartDate);
  }

  bool _isActiveChallenge(Map<String, dynamic> challenge) {
    final int? challengeId = challenge['id'] as int?;
    if (challengeId == null) return challenge['is_active'] != false;
    return !(_challengeCompleted[challengeId] ?? false);
  }

  bool _isEndedChallenge(Map<String, dynamic> challenge) {
    final int? challengeId = challenge['id'] as int?;
    if (challengeId == null) return challenge['is_active'] == false;
    return _challengeCompleted[challengeId] ?? false;
  }

  Future<List<Map<String, dynamic>>> _loadAvailableTeams() async {
    try {
      final teamList = await loadTeamsSafe(_supabase, ascending: true);
      if (mounted) {
        setState(() {
          _teams = teamList;
        });
      }
      return teamList;
    } catch (e) {
      debugPrint('Chyba načítání dostupných týmů: $e');
      return List<Map<String, dynamic>>.from(_teams);
    }
  }

  Future<void> _showCreateChallengeDialog() async {
    final availableTeams = await _loadAvailableTeams();
    if (!mounted) return;
    final nameController = TextEditingController();
    final distanceController = TextEditingController();
    DateTime? startDate;
    final Set<int> selectedTeamIds = {};

    await showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Nová výzva'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration:
                          const InputDecoration(labelText: 'Název výzvy'),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: distanceController,
                      decoration:
                          const InputDecoration(labelText: 'Počet kilometrů'),
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('Datum začátku:'),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(startDate != null
                              ? '${startDate!.day.toString().padLeft(2, '0')}.${startDate!.month.toString().padLeft(2, '0')}.${startDate!.year}'
                              : 'Vyberte datum'),
                        ),
                        TextButton(
                          onPressed: () async {
                            final selected = await showDatePicker(
                              context: context,
                              initialDate: DateTime.now(),
                              firstDate: DateTime(2000),
                              lastDate: DateTime(2100),
                            );
                            if (selected != null) {
                              setState(() {
                                startDate = selected;
                              });
                            }
                          },
                          child: const Text('Vybrat'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Align(
                      alignment: Alignment.centerLeft,
                      child: Text('Týmy účastnící se výzvy:',
                          style: TextStyle(fontWeight: FontWeight.bold)),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      height: 200,
                      width: double.maxFinite,
                      child: availableTeams.isEmpty
                          ? const Center(child: Text('Žádné týmy k dispozici.'))
                          : ListView(
                              children: availableTeams.map((team) {
                                final id = team['id'] as int;
                                final name = team['name'] ?? 'Tým';
                                return CheckboxListTile(
                                  value: selectedTeamIds.contains(id),
                                  title: Text(name),
                                  onChanged: (checked) {
                                    setState(() {
                                      if (checked == true) {
                                        selectedTeamIds.add(id);
                                      } else {
                                        selectedTeamIds.remove(id);
                                      }
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Zrušit')),
                ElevatedButton(
                  onPressed: () async {
                    final name = nameController.text.trim();
                    final dialogNavigator = Navigator.of(dialogContext);
                    final dialogMessenger = ScaffoldMessenger.of(dialogContext);
                    final distance = double.tryParse(
                            distanceController.text.replaceAll(',', '.')) ??
                        0.0;
                    if (name.isEmpty ||
                        distance <= 0 ||
                        startDate == null ||
                        selectedTeamIds.isEmpty) {
                      dialogMessenger.showSnackBar(
                        const SnackBar(
                            content: Text('Vyplňte prosím všechny údaje.')),
                      );
                      return;
                    }

                    final selectedNames = availableTeams
                        .where((team) =>
                            selectedTeamIds.contains(team['id'] as int))
                        .map((team) => team['name'] ?? '')
                        .where((name) => name.isNotEmpty)
                        .join(', ');

                    String currentUserId;
                    try {
                      currentUserId =
                          await requireAuthenticatedUserId(_supabase);
                    } catch (authError) {
                      dialogMessenger.showSnackBar(
                        SnackBar(
                            content: Text(
                                'Neplatná relace. Přihlaste se znovu.\n${formatBackendError(authError)}')),
                      );
                      return;
                    }

                    final normalizedChallengeName = name.trim().toLowerCase();
                    final existingChallenges =
                        await loadChallengesSafe(_supabase, ascending: true);
                    final duplicateChallenge = existingChallenges.any((item) =>
                        (item['name'] ?? '').toString().trim().toLowerCase() ==
                        normalizedChallengeName);
                    if (duplicateChallenge) {
                      dialogMessenger.showSnackBar(const SnackBar(
                        content: Text('Výzva s tímto názvem už existuje.'),
                      ));
                      return;
                    }

                    try {
                      Object? firstInsertError;
                      Object? secondInsertError;
                      try {
                        await _supabase.from('challenges').insert({
                          'name': name,
                          'start_date': startDate!.toUtc().toIso8601String(),
                          'distance': distance,
                          'team_names': selectedNames,
                          'is_active': true,
                          'originator_id': currentUserId,
                        });
                      } catch (e) {
                        firstInsertError = e;
                        debugPrint(
                            'Challenges insert fallback without originator_id: ${formatBackendError(e)}');
                        try {
                          await _supabase.from('challenges').insert({
                            'name': name,
                            'start_date': startDate!.toUtc().toIso8601String(),
                            'distance': distance,
                            'team_names': selectedNames,
                            'is_active': true,
                          });
                        } catch (e2) {
                          secondInsertError = e2;
                          try {
                            await insertRowViaRestWithSession(
                              supabase: _supabase,
                              table: 'challenges',
                              payload: {
                                'name': name,
                                'start_date':
                                    startDate!.toUtc().toIso8601String(),
                                'distance': distance,
                                'team_names': selectedNames,
                                'is_active': true,
                              },
                            );
                          } catch (restError) {
                            throw Exception(
                              'Create challenge insert failed. '
                              'First SDK: ${formatBackendError(firstInsertError)} | '
                              'Second SDK: ${formatBackendError(secondInsertError)} | '
                              'REST: ${formatBackendError(restError)}',
                            );
                          }
                        }
                      }

                      dialogNavigator.pop();
                      await _loadData();

                      if (firstInsertError != null ||
                          secondInsertError != null) {
                        debugPrint(
                            'Create challenge recovered by fallback. First: ${firstInsertError == null ? '-' : formatBackendError(firstInsertError)} | Second: ${secondInsertError == null ? '-' : formatBackendError(secondInsertError)}');
                      }
                    } catch (e) {
                      final detail = formatBackendError(e,
                          context: 'create challenge failed');
                      debugPrint(detail);
                      dialogMessenger.showSnackBar(
                        SnackBar(
                          content: Text(
                            isRlsViolationError(e)
                                ? 'Nepodařilo se založit výzvu. DB RLS blokuje insert do challenges (42501). Spusť SQL fix pro RLS.'
                                : 'Nepodařilo se založit výzvu.\n$detail',
                          ),
                        ),
                      );
                    }
                  },
                  child: const Text('Vytvořit'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  String _formatDate(String? iso) {
    if (iso == null || iso.isEmpty) return '--';
    final date = DateTime.parse(iso).toLocal();
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year}';
  }

  Widget _buildChallengeList(bool activeList) {
    final filtered = _challenges
        .where((challenge) => activeList
            ? _isActiveChallenge(challenge)
            : _isEndedChallenge(challenge))
        .toList();
    if (filtered.isEmpty) {
      return Center(
        child: Text(
            activeList ? 'Žádné aktuální výzvy.' : 'Žádné ukončené výzvy.'),
      );
    }

    return ListView.builder(
      itemCount: filtered.length,
      itemBuilder: (context, index) {
        final challenge = filtered[index];
        final name = challenge['name'] ?? 'Výzva';
        final start = _formatDate(challenge['start_date'] as String?);
        final distance =
            (challenge['distance'] as num?)?.toStringAsFixed(0) ?? '0';
        final teams = challenge['team_names'] ?? '';
        final canEdit = _canEditChallenge(challenge);
        final isOwner = _isChallengeOriginator(challenge);

        return Card(
          margin: const EdgeInsets.symmetric(vertical: 8),
          child: ListTile(
            title:
                Text(name, style: const TextStyle(fontWeight: FontWeight.bold)),
            subtitle: Text(isOwner
                ? 'Start: $start • Týmy: $teams\nZakladatel: vy'
                : 'Start: $start • Týmy: $teams'),
            isThreeLine: isOwner,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('$distance km',
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                if (canEdit)
                  PopupMenuButton<String>(
                    onSelected: (value) async {
                      if (value == 'edit') {
                        await _showEditChallengeDialog(challenge);
                      } else if (value == 'delete') {
                        await _deleteChallenge(challenge);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                          value: 'edit', child: Text('Upravit výzvu')),
                      PopupMenuItem(
                          value: 'delete', child: Text('Smazat výzvu')),
                    ],
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Výzvy'),
          backgroundColor: Colors.orange,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const ChallengeDashboard()),
                (route) => false,
              );
            },
          ),
          actions: [buildAppMenu(context)],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Aktuální'),
              Tab(text: 'Ukončené'),
            ],
          ),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  if (_loadError != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        'Diagnostika výzev: $_loadError',
                        style: const TextStyle(color: Colors.red, fontSize: 12),
                      ),
                    ),
                  Expanded(
                    child: TabBarView(
                      children: [
                        _buildChallengeList(true),
                        _buildChallengeList(false),
                      ],
                    ),
                  ),
                ],
              ),
        floatingActionButton: FloatingActionButton(
          onPressed: _showCreateChallengeDialog,
          backgroundColor: Colors.orange,
          tooltip: 'Nová výzva',
          child: const Icon(Icons.add),
        ),
      ),
    );
  }
}

class TeamsScreen extends StatefulWidget {
  const TeamsScreen({super.key});

  @override
  State<TeamsScreen> createState() => _TeamsScreenState();
}

class _TeamsScreenState extends State<TeamsScreen> {
  final _supabase = Supabase.instance.client;
  static const String _selectedChallengePrefsKey = 'selected_challenge_id';
  bool _isLoading = true;
  bool _isChallengesLoading = true;
  String? _teamsLoadError;
  String? _teamsChallengesError;
  List<Map<String, dynamic>> _teams = [];
  List<Map<String, dynamic>> _challenges = [];
  int? _selectedChallengeId;
  bool _showChallengeMode = false;
  final TextEditingController _teamNameController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadTeams();
    _loadChallengesForTeams();
  }

  @override
  void dispose() {
    _teamNameController.dispose();
    super.dispose();
  }

  Future<void> _loadTeams() async {
    try {
      final data = await loadTeamsSafe(_supabase, ascending: true);
      setState(() {
        _teams = data;
        _teamsLoadError = null;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint(formatBackendError(e, context: 'Chyba načítání týmů'));
      setState(() {
        _teamsLoadError = formatBackendError(e, context: 'teams query failed');
        _isLoading = false;
      });
    }
  }

  Future<void> _loadChallengesForTeams() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedSelectedId = prefs.getInt(_selectedChallengePrefsKey);
      final challengeList =
          await loadChallengesSafe(_supabase, ascending: false);

      int? selectedId = storedSelectedId;
      if (challengeList.isNotEmpty) {
        final selectedExists = selectedId != null &&
            challengeList.any((c) => c['id'] == selectedId);
        if (!selectedExists) {
          final active =
              challengeList.where((c) => c['is_active'] == true).toList();
          selectedId = (active.isNotEmpty
              ? active.first
              : challengeList.first)['id'] as int;
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
        _challenges = challengeList;
        _selectedChallengeId = selectedId;
        _teamsChallengesError = null;
        _isChallengesLoading = false;
      });
    } catch (e) {
      debugPrint(
          formatBackendError(e, context: 'Chyba načítání výzev pro týmy'));
      if (!mounted) return;
      setState(() {
        _teamsChallengesError =
            formatBackendError(e, context: 'challenges query failed');
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
      debugPrint('Chyba ukládání vybrané výzvy v týmech: $e');
    }
  }

  Map<String, dynamic>? _selectedChallenge() {
    if (_selectedChallengeId == null) return null;
    for (final challenge in _challenges) {
      if (challenge['id'] == _selectedChallengeId) return challenge;
    }
    return null;
  }

  String? _currentUserId() {
    return _supabase.auth.currentUser?.id;
  }

  bool _isTeamOriginator(Map<String, dynamic> team) {
    final currentUserId = _currentUserId();
    if (currentUserId == null || currentUserId.isEmpty) return false;
    final originatorId = (team['originator_id'] ?? '').toString();
    return originatorId.isNotEmpty && originatorId == currentUserId;
  }

  Map<String, dynamic>? _findTeamByName(String teamName) {
    for (final team in _teams) {
      final currentName = (team['name'] ?? '').toString().trim().toLowerCase();
      if (currentName == teamName.trim().toLowerCase()) {
        return team;
      }
    }
    return null;
  }

  Future<int?> _resolveTeamIdByName(String teamName) async {
    final normalized = teamName.trim().toLowerCase();
    final local = _findTeamByName(teamName);
    final localId = local?['id'] as int?;
    if (localId != null) return localId;

    try {
      final rows = await _supabase
          .from('teams')
          .select('id, name')
          .ilike('name', teamName.trim())
          .limit(10);
      final matches = List<Map<String, dynamic>>.from(rows);
      for (final row in matches) {
        final rowName = (row['name'] ?? '').toString().trim().toLowerCase();
        if (rowName == normalized) {
          return row['id'] as int?;
        }
      }
      if (matches.isNotEmpty) {
        return matches.first['id'] as int?;
      }
    } catch (e) {
      debugPrint('resolve team id by name failed: ${formatBackendError(e)}');
    }
    return null;
  }

  List<String> _selectedChallengeTeamLabels() {
    final challenge = _selectedChallenge();
    final raw = (challenge?['team_names'] ?? '').toString();
    if (raw.isEmpty) return [];

    return raw
        .split(',')
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toList();
  }

  Set<String> _selectedChallengeTeamNamesLower() {
    return _selectedChallengeTeamLabels()
        .map((name) => name.toLowerCase())
        .toSet();
  }

  DateTime? _selectedChallengeStartDate() {
    final raw = _selectedChallenge()?['start_date']?.toString() ?? '';
    return DateTime.tryParse(raw)?.toLocal();
  }

  Future<List<Map<String, dynamic>>> _fetchActivitiesForTeams() async {
    try {
      return await loadActivitiesSafe(_supabase, ascending: false);
    } catch (e) {
      debugPrint(
          formatBackendError(e, context: 'Teams activities safe load failed'));
      return [];
    }
  }

  Future<void> _showTeamMembers(Map<String, dynamic> team) async {
    try {
      final teamName = (team['name'] ?? 'Tým').toString();
      final normalizedTeamName = teamName.trim().toLowerCase();
      final teamId =
          (team['id'] as int?) ?? await _resolveTeamIdByName(teamName);
      final canManage = _isTeamOriginator(team);
      List<String> members = [];
      List<Map<String, dynamic>> memberRows = [];

      Future<void> loadMembersFromTeamMembers(int teamIdValue) async {
        dynamic data;
        try {
          data = await _supabase
              .from('team_members')
              .select('id, runner_name, user_id')
              .eq('team_id', teamIdValue)
              .order('runner_name', ascending: true);
        } catch (e1) {
          debugPrint(formatBackendError(e1,
              context: 'team_members select(id,runner_name,user_id) failed'));
          try {
            data = await _supabase
                .from('team_members')
                .select('id, runner_name')
                .eq('team_id', teamIdValue)
                .order('runner_name', ascending: true);
          } catch (e2) {
            debugPrint(formatBackendError(e2,
                context: 'team_members select(id,runner_name) failed'));
            data = await _supabase
                .from('team_members')
                .select('runner_name')
                .eq('team_id', teamIdValue)
                .order('runner_name', ascending: true);
          }
        }

        memberRows = List<Map<String, dynamic>>.from(data);
        members = memberRows
            .map((row) => (row['runner_name'] ?? '').toString().trim())
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
      }

      Future<List<String>> loadMembersFromActivities() async {
        List<Map<String, dynamic>> rows = [];
        try {
          final exact = await _supabase
              .from('activities')
              .select('runner_name')
              .eq('team_name', teamName)
              .order('runner_name', ascending: true);
          final exactMembers = List<Map<String, dynamic>>.from(exact)
              .map((row) => (row['runner_name'] ?? '').toString().trim())
              .where((name) => name.isNotEmpty)
              .toSet()
              .toList()
            ..sort();
          if (exactMembers.isNotEmpty) return exactMembers;
        } catch (e1) {
          debugPrint(formatBackendError(e1,
              context: 'activities exact members query failed'));
        }

        try {
          final all = await _supabase
              .from('activities')
              .select('team_name, runner_name')
              .order('runner_name', ascending: true);
          rows = List<Map<String, dynamic>>.from(all);
        } catch (e2) {
          debugPrint(
              formatBackendError(e2, context: 'activities broad query failed'));
          try {
            rows = await loadActivitiesSafe(_supabase, ascending: false);
          } catch (e3) {
            debugPrint(formatBackendError(e3,
                context: 'activities safe fallback for members failed'));
            return [];
          }
        }

        final allMembers = rows
            .where((row) =>
                (row['team_name'] ?? '').toString().trim().toLowerCase() ==
                normalizedTeamName)
            .map((row) => (row['runner_name'] ?? '').toString().trim())
            .where((name) => name.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
        return allMembers;
      }

      if (teamId != null) {
        try {
          await loadMembersFromTeamMembers(teamId);

          if (members.isEmpty) {
            members = await loadMembersFromActivities();
          }
        } catch (e) {
          debugPrint('team_members není dostupné, fallback na activities: $e');
          members = await loadMembersFromActivities();
        }
      }

      if (!mounted) return;

      await showDialog(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: Text('Členové týmu $teamName'),
            content: SizedBox(
              width: double.maxFinite,
              child: StatefulBuilder(
                builder: (context, setDialogState) {
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        height: 260,
                        child: members.isEmpty
                            ? const Text(
                                'Pro tento tým zatím nejsou evidováni žádní členové.')
                            : ListView.separated(
                                shrinkWrap: true,
                                itemCount: members.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (context, index) {
                                  final member = members[index];
                                  return ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: const CircleAvatar(
                                      backgroundColor: Color(0xFFFFE0B2),
                                      child: Icon(Icons.person,
                                          color: Colors.orange),
                                    ),
                                    title: Text(member),
                                  );
                                },
                              ),
                      ),
                    ],
                  );
                },
              ),
            ),
            actions: [
              if (canManage && teamId != null)
                TextButton(
                  onPressed: () async {
                    final stateMessenger = ScaffoldMessenger.of(context);
                    final dialogNavigator = Navigator.of(dialogContext);
                    final dialogMessenger = ScaffoldMessenger.of(dialogContext);
                    final confirmed = await showDialog<bool>(
                          context: dialogContext,
                          builder: (ctx) => AlertDialog(
                            title: const Text('Smazat tým?'),
                            content: const Text(
                                'Tato akce je nevratná. Tým bude odstraněn.'),
                            actions: [
                              TextButton(
                                  onPressed: () => Navigator.pop(ctx, false),
                                  child: const Text('Zrušit')),
                              ElevatedButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.red),
                                child: const Text('Smazat'),
                              ),
                            ],
                          ),
                        ) ??
                        false;
                    if (!confirmed) return;
                    try {
                      await _supabase.from('teams').delete().eq('id', teamId);
                      if (mounted) {
                        dialogNavigator.pop();
                        await _loadTeams();
                        stateMessenger.showSnackBar(
                          const SnackBar(content: Text('Tým byl smazán.')),
                        );
                      }
                    } catch (e) {
                      debugPrint('Chyba při mazání týmu: $e');
                      dialogMessenger.showSnackBar(
                        const SnackBar(
                            content: Text('Nepodařilo se smazat tým.')),
                      );
                    }
                  },
                  child: const Text('Smazat tým',
                      style: TextStyle(color: Colors.red)),
                ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Zavřít'),
              ),
            ],
          );
        },
      );
    } catch (e) {
      final detail = formatBackendError(e, context: 'team members load failed');
      debugPrint(detail);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isRlsViolationError(e)
                ? 'Nepodařilo se načíst členy týmu. DB RLS blokuje přístup k team_members.'
                : 'Nepodařilo se načíst členy týmu.\n$detail',
          ),
        ),
      );
    }
  }

  Future<void> _showCreateTeamDialog() async {
    _teamNameController.clear();
    await showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Nový tým'),
          content: TextField(
            controller: _teamNameController,
            decoration: const InputDecoration(labelText: 'Název týmu'),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Zrušit')),
            ElevatedButton(
              onPressed: () async {
                final dialogNavigator = Navigator.of(dialogContext);
                final dialogMessenger = ScaffoldMessenger.of(dialogContext);
                final name = _teamNameController.text.trim();
                if (name.isEmpty) {
                  dialogMessenger.showSnackBar(const SnackBar(
                      content: Text('Zadejte prosím název týmu.')));
                  return;
                }
                String currentUserId;
                try {
                  currentUserId = await requireAuthenticatedUserId(_supabase);
                } catch (authError) {
                  dialogMessenger.showSnackBar(SnackBar(
                      content: Text(
                          'Neplatná relace. Přihlaste se znovu.\n${formatBackendError(authError)}')));
                  return;
                }
                final normalizedName = name.trim().toLowerCase();
                final existingTeamNames =
                    await loadTeamsSafe(_supabase, ascending: true);
                final duplicateTeam = existingTeamNames.any((team) =>
                    (team['name'] ?? '').toString().trim().toLowerCase() ==
                    normalizedName);
                if (duplicateTeam) {
                  dialogMessenger.showSnackBar(const SnackBar(
                    content: Text('Tým s tímto názvem už existuje.'),
                  ));
                  return;
                }
                debugPrint(
                    'create team auth state: user=$currentUserId session=${_supabase.auth.currentSession != null}');
                try {
                  final attemptErrors = <String>[];
                  Future<bool> trySdkInsert(
                    String label,
                    Map<String, dynamic> payload,
                  ) async {
                    try {
                      await _supabase.from('teams').insert(payload);
                      return true;
                    } catch (e) {
                      attemptErrors.add(
                          '$label: ${formatBackendError(e)} payload=$payload');
                      return false;
                    }
                  }

                  Future<bool> tryRestInsert(
                    String label,
                    Map<String, dynamic> payload,
                  ) async {
                    try {
                      await insertRowViaRestWithSession(
                        supabase: _supabase,
                        table: 'teams',
                        payload: payload,
                      );
                      return true;
                    } catch (e) {
                      attemptErrors.add(
                          '$label: ${formatBackendError(e)} payload=$payload');
                      return false;
                    }
                  }

                  final attempts = [
                    (
                      'SDK#1',
                      {
                        'name': name,
                        'km': 0,
                        'originator_id': currentUserId,
                      }
                    ),
                    (
                      'SDK#2',
                      {
                        'name': name,
                        'originator_id': currentUserId,
                      }
                    ),
                    ('SDK#3', {'name': name, 'km': 0}),
                    ('SDK#4', {'name': name}),
                  ];

                  var created = false;
                  for (final attempt in attempts) {
                    if (await trySdkInsert(attempt.$1, attempt.$2)) {
                      created = true;
                      break;
                    }
                  }

                  if (!created) {
                    created =
                        await tryRestInsert('REST#1', {'name': name, 'km': 0});
                  }
                  if (!created) {
                    created = await tryRestInsert('REST#2', {'name': name});
                  }
                  if (!created) {
                    throw Exception(
                      'Create team insert failed. Attempts: ${attemptErrors.join(' | ')}',
                    );
                  }

                  int? teamId;
                  try {
                    final lookup = await _supabase
                        .from('teams')
                        .select('id')
                        .eq('name', name)
                        .order('id', ascending: false)
                        .limit(1);
                    final rows = List<Map<String, dynamic>>.from(lookup);
                    teamId = rows.isNotEmpty ? rows.first['id'] as int? : null;
                  } catch (e) {
                    debugPrint(
                        'Lookup newly created team id skipped: ${formatBackendError(e)}');
                  }

                  if (teamId != null) {
                    try {
                      final runnerName = (_supabase.auth.currentUser
                                  ?.userMetadata?['runner_name'] ??
                              '')
                          .toString()
                          .trim();
                      await _supabase.from('team_members').insert({
                        'team_id': teamId,
                        'user_id': currentUserId,
                        'runner_name':
                            runnerName.isEmpty ? 'Anonymní běžec' : runnerName,
                      });
                    } catch (e) {
                      debugPrint(
                          'Zápis zakladatele do team_members přeskočen: $e');
                    }
                  }

                  if (attemptErrors.isNotEmpty) {
                    debugPrint(
                        'Create team recovered by fallback. Attempts: ${attemptErrors.join(' | ')}');
                  }

                  dialogNavigator.pop();

                  await _loadTeams();
                } catch (e) {
                  final detail =
                      formatBackendError(e, context: 'create team failed');
                  debugPrint(detail);
                  dialogMessenger.showSnackBar(
                    SnackBar(
                      content: Text(
                        isRlsViolationError(e)
                            ? 'Nepodařilo se založit tým. DB RLS blokuje insert do teams (42501). Spusť SQL fix pro RLS.'
                            : 'Nepodařilo se založit tým.\n$detail',
                      ),
                    ),
                  );
                }
              },
              child: const Text('Vytvořit'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Týmy'),
        backgroundColor: Colors.orange,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const ChallengeDashboard()),
              (route) => false,
            );
          },
        ),
        actions: [buildAppMenu(context)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _teams.isEmpty
                ? const Center(child: Text('Žádné aktuální týmy.'))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (_teamsLoadError != null ||
                          _teamsChallengesError != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: SelectableText(
                            'Diagnostika týmů: ${_teamsLoadError ?? ''} ${_teamsChallengesError ?? ''}',
                            style: const TextStyle(
                                color: Colors.red, fontSize: 12),
                          ),
                        ),
                      DropdownButtonFormField<String>(
                        initialValue:
                            _showChallengeMode ? 'challenge' : 'total',
                        decoration: const InputDecoration(
                          labelText: 'Zobrazení kilometrů',
                          border: OutlineInputBorder(),
                        ),
                        items: const [
                          DropdownMenuItem(
                              value: 'total', child: Text('Celkem')),
                          DropdownMenuItem(
                              value: 'challenge',
                              child: Text('Ve vybrané výzvě')),
                        ],
                        onChanged: (value) {
                          setState(() {
                            _showChallengeMode = value == 'challenge';
                          });
                        },
                      ),
                      if (_showChallengeMode) ...[
                        const SizedBox(height: 12),
                        if (_isChallengesLoading)
                          const Center(child: CircularProgressIndicator())
                        else if (_challenges.isEmpty)
                          const Text('Nejsou dostupné žádné výzvy.')
                        else
                          DropdownButtonFormField<int>(
                            initialValue: _selectedChallengeId,
                            decoration: const InputDecoration(
                              labelText: 'Vybraná výzva',
                              border: OutlineInputBorder(),
                            ),
                            items: _challenges.map((challenge) {
                              final name =
                                  (challenge['name'] ?? 'Výzva').toString();
                              final dateValue =
                                  challenge['start_date']?.toString() ?? '';
                              final date =
                                  DateTime.tryParse(dateValue)?.toLocal();
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
                      ],
                      const SizedBox(height: 12),
                      Expanded(
                        child: _showChallengeMode
                            ? Builder(
                                builder: (context) {
                                  final challengeTeams =
                                      _selectedChallengeTeamLabels();
                                  if (!_isChallengesLoading &&
                                      challengeTeams.isEmpty) {
                                    return const Center(
                                        child: Text(
                                            'Pro vybranou výzvu nejsou přiřazeny žádné týmy.'));
                                  }

                                  final challengeTeamNames =
                                      _selectedChallengeTeamNamesLower();
                                  final challengeStartDate =
                                      _selectedChallengeStartDate();

                                  return FutureBuilder<
                                      List<Map<String, dynamic>>>(
                                    future: _fetchActivitiesForTeams(),
                                    builder: (context, snapshot) {
                                      if (snapshot.connectionState ==
                                          ConnectionState.waiting) {
                                        return const Center(
                                            child: CircularProgressIndicator());
                                      }
                                      if (snapshot.hasError) {
                                        return const Center(
                                            child: Text(
                                                'Aktivity se nepodařilo načíst.'));
                                      }

                                      final activities = snapshot.data ??
                                          const <Map<String, dynamic>>[];
                                      final Map<String, double> kmByTeam = {
                                        for (final label in challengeTeams)
                                          label.toLowerCase(): 0.0,
                                      };

                                      for (final act in activities) {
                                        final teamNameRaw =
                                            (act['team_name'] ?? '')
                                                .toString()
                                                .trim();
                                        final teamNameKey =
                                            teamNameRaw.toLowerCase();
                                        if (!challengeTeamNames
                                            .contains(teamNameKey)) {
                                          continue;
                                        }

                                        if (challengeStartDate != null) {
                                          final rawTime = (act['start_time'] ??
                                                  act['created_at'] ??
                                                  '')
                                              .toString();
                                          final activityTime =
                                              DateTime.tryParse(rawTime)
                                                  ?.toLocal();
                                          if (activityTime == null ||
                                              activityTime.isBefore(
                                                  challengeStartDate)) {
                                            continue;
                                          }
                                        }

                                        final kmValue =
                                            (act['km'] as num?)?.toDouble() ??
                                                0.0;
                                        kmByTeam[teamNameKey] =
                                            (kmByTeam[teamNameKey] ?? 0.0) +
                                                kmValue;
                                      }

                                      return ListView.builder(
                                        itemCount: challengeTeams.length,
                                        itemBuilder: (context, index) {
                                          final name = challengeTeams[index];
                                          final km =
                                              kmByTeam[name.toLowerCase()] ??
                                                  0.0;
                                          return Card(
                                            margin: const EdgeInsets.symmetric(
                                                vertical: 8),
                                            child: ListTile(
                                              onTap: () => _showTeamMembers(
                                                _findTeamByName(name) ??
                                                    <String, dynamic>{
                                                      'name': name,
                                                    },
                                              ),
                                              title: Text(name,
                                                  style: const TextStyle(
                                                      fontWeight:
                                                          FontWeight.bold)),
                                              subtitle: Text(
                                                  '${km.toStringAsFixed(1)} km'),
                                              trailing: const Icon(
                                                  Icons.chevron_right),
                                            ),
                                          );
                                        },
                                      );
                                    },
                                  );
                                },
                              )
                            : ListView.builder(
                                itemCount: _teams.length,
                                itemBuilder: (context, index) {
                                  final team = _teams[index];
                                  final name = team['name'] ?? 'Tým';
                                  final km = (team['km'] as num?)
                                          ?.toStringAsFixed(1) ??
                                      '0.0';
                                  return Card(
                                    margin:
                                        const EdgeInsets.symmetric(vertical: 8),
                                    child: ListTile(
                                      onTap: () => _showTeamMembers(team),
                                      title: Text(name,
                                          style: const TextStyle(
                                              fontWeight: FontWeight.bold)),
                                      subtitle: Text('$km km'),
                                      trailing: const Icon(Icons.chevron_right),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateTeamDialog,
        backgroundColor: Colors.orange,
        tooltip: 'Nový tým',
        child: const Icon(Icons.add),
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _supabase = Supabase.instance.client;
  final _picker = ImagePicker();
  final TextEditingController _nameController = TextEditingController();
  String _email = '';
  String? _avatarBase64;
  bool _isLoading = true;
  bool _isLoadingTeams = true;
  bool _isSavingProfile = false;
  bool _isRestoringActivities = false;
  String? _lastRestoreInsertError;
  final List<Map<String, dynamic>> _activities = [];
  List<Map<String, dynamic>> _availableTeams = [];
  int? _selectedTeamId;

  @override
  void initState() {
    super.initState();
    _loadTeamsForProfile();
    _loadUserData();
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  int? _parseTeamId(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  Map<String, dynamic>? _selectedTeam() {
    if (_selectedTeamId == null) return null;
    for (final team in _availableTeams) {
      if (team['id'] == _selectedTeamId) return team;
    }
    return null;
  }

  Future<void> _loadUserData() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return;
      final metadata = user.userMetadata ?? {};
      final runnerName = metadata['runner_name'] ?? '';
      final avatarBase64 = (metadata['avatar_base64'] ?? '').toString();
      _nameController.text = runnerName;
      _avatarBase64 = avatarBase64.isEmpty ? null : avatarBase64;
      _email = user.email ?? '';
      _selectedTeamId = _parseTeamId(metadata['team_id']) ?? _selectedTeamId;
    } catch (e) {
      debugPrint('Chyba načítání profilu: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _loadTeamsForProfile() async {
    try {
      final teams = await loadTeamsSafe(_supabase, ascending: true);
      final currentTeamId =
          _parseTeamId(_supabase.auth.currentUser?.userMetadata?['team_id']);
      if (!mounted) return;
      setState(() {
        _availableTeams = teams;
        _selectedTeamId = currentTeamId ??
            (_selectedTeamId ??
                (teams.isNotEmpty ? teams.first['id'] as int? : null));
        _isLoadingTeams = false;
      });
    } catch (e) {
      debugPrint(
          formatBackendError(e, context: 'profile team list load failed'));
      if (!mounted) return;
      setState(() {
        _isLoadingTeams = false;
      });
    }
  }

  Future<void> _recalculateTeamKmById(int teamId) async {
    try {
      final team = _availableTeams.firstWhere(
        (item) => item['id'] == teamId,
        orElse: () => <String, dynamic>{},
      );
      final teamName = (team['name'] ?? '').toString().trim();
      if (teamName.isEmpty) return;

      final teamActivities = await _supabase
          .from('activities')
          .select('km')
          .eq('team_name', teamName);
      double teamKm = 0.0;
      for (final row in List<Map<String, dynamic>>.from(teamActivities)) {
        teamKm += (row['km'] as num?)?.toDouble() ?? 0.0;
      }
      await _supabase.from('teams').update({'km': teamKm}).eq('id', teamId);
    } catch (e) {
      debugPrint(formatBackendError(e,
          context: 'profile team km recalculation failed'));
    }
  }

  Future<void> _saveProfile() async {
    final newName = _nameController.text.trim();
    if (newName.isEmpty) return;
    if (_selectedTeamId == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vyberte prosím tým z nabídky.')),
      );
      return;
    }

    setState(() {
      _isSavingProfile = true;
    });

    try {
      await _supabase.auth.refreshSession();

      final user = _supabase.auth.currentUser;
      final userId = user?.id;
      if (userId == null) {
        throw Exception('User is not signed in');
      }

      final metadata = user?.userMetadata ?? {};
      final oldRunnerName = (metadata['runner_name'] ?? '').toString().trim();
      final oldTeamName = (metadata['team_name'] ?? '').toString().trim();
      final oldTeamId = _parseTeamId(metadata['team_id']);
      final selectedTeam = _selectedTeam();
      final newTeamName = (selectedTeam?['name'] ?? '').toString().trim();
      if (newTeamName.isEmpty) {
        throw Exception('Selected team is missing');
      }

      await _supabase.auth.updateUser(
        UserAttributes(
          data: {
            'runner_name': newName,
            'avatar_base64': _avatarBase64,
            'team_id': _selectedTeamId,
            'team_name': newTeamName,
          },
        ),
      );

      try {
        await _supabase.from('team_members').delete().eq('user_id', userId);
        await _supabase.from('team_members').insert({
          'team_id': _selectedTeamId,
          'user_id': userId,
          'runner_name': newName,
        });
      } catch (e) {
        debugPrint('team_members při změně týmu přeskočeno: $e');
      }

      if (oldRunnerName.isNotEmpty) {
        try {
          var activityUpdate = _supabase.from('activities').update({
            'runner_name': newName,
            'team_name': newTeamName,
          });
          activityUpdate = activityUpdate.eq('runner_name', oldRunnerName);
          if (oldTeamName.isNotEmpty) {
            activityUpdate = activityUpdate.eq('team_name', oldTeamName);
          }
          await activityUpdate;
        } catch (e) {
          debugPrint('activities při změně týmu přeskočeny: $e');
        }
      }

      if (oldTeamId != null && oldTeamId != _selectedTeamId) {
        await _recalculateTeamKmById(oldTeamId);
      }
      if (_selectedTeamId != null) {
        await _recalculateTeamKmById(_selectedTeamId!);
      }

      await _loadTeamsForProfile();
      await _loadUserData();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profil i tým byly aktualizovány.')));
    } catch (e) {
      debugPrint('Chyba ukládání profilu: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Nepodařilo se uložit změny.')));
    } finally {
      if (mounted) {
        setState(() {
          _isSavingProfile = false;
        });
      }
    }
  }

  Set<String> _parseChallengeTeams(String rawTeamNames) {
    return rawTeamNames
        .split(',')
        .map((name) => name.trim().toLowerCase())
        .where((name) => name.isNotEmpty)
        .toSet();
  }

  String _activityKey(DateTime startUtc, DateTime endUtc, double km) {
    final startMs = startUtc.millisecondsSinceEpoch;
    final endMs = endUtc.millisecondsSinceEpoch;
    final kmBucket = (km * 10000).round();
    return '$startMs|$endMs|$kmBucket';
  }

  String _activityTimeKey(DateTime startUtc, DateTime endUtc) {
    final startMs = startUtc.millisecondsSinceEpoch;
    final endMs = endUtc.millisecondsSinceEpoch;
    return '$startMs|$endMs';
  }

  void _showRestoreStatus(String message) {
    debugPrint('RESTORE_STATUS: $message');
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _insertActivityViaRestWithSession(
      Map<String, dynamic> payload) async {
    final session = _supabase.auth.currentSession;
    final accessToken = session?.accessToken;
    final tokens = <String>[];
    if (accessToken != null && accessToken.isNotEmpty) {
      tokens.add(accessToken);
    }
    if (!tokens.contains(kSupabasePublishableKey)) {
      tokens.add(kSupabasePublishableKey);
    }

    Object? lastError;
    for (final token in tokens) {
      final uri = Uri.parse('$kSupabaseUrl/rest/v1/activities');
      final client = HttpClient();
      try {
        final request = await client.postUrl(uri);
        request.headers.set('apikey', kSupabasePublishableKey);
        request.headers.set('Authorization', 'Bearer $token');
        request.headers.set('Content-Type', 'application/json; charset=utf-8');
        request.headers.set('Accept', 'application/json');
        request.headers.set('Prefer', 'return=representation');
        request.add(utf8.encode(jsonEncode(payload)));

        final response = await request.close();
        final body = await utf8.decodeStream(response);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw Exception(
              'REST insert HTTP ${response.statusCode}, body=$body');
        }
        return;
      } catch (e) {
        lastError = e;
      } finally {
        client.close(force: true);
      }
    }

    throw Exception('REST insert failed for all tokens: $lastError');
  }

  Future<int> _insertActivitiesWithFallback(
      List<Map<String, dynamic>> rows) async {
    if (rows.isEmpty) return 0;
    _lastRestoreInsertError = null;

    int inserted = 0;
    for (final row in rows) {
      final teamName = (row['team_name'] ?? '').toString().trim();
      final runnerName = (row['runner_name'] ?? '').toString().trim();
      final km = (row['km'] as num?)?.toDouble() ?? 0.0;
      if (teamName.isEmpty || runnerName.isEmpty || !km.isFinite || km <= 0) {
        continue;
      }

      final payloadWithTimes = {
        'team_name': teamName,
        'runner_name': runnerName,
        'km': km,
        'start_time': row['start_time'],
        'end_time': row['end_time'],
        'created_at': DateTime.now().toUtc().toIso8601String(),
      };

      final startIso = (row['start_time'] ?? '').toString();
      final endIso = (row['end_time'] ?? '').toString();
      if (startIso.isNotEmpty && endIso.isNotEmpty) {
        // Idempotent restore: remove old row for the same interval before insert.
        try {
          await _supabase
              .from('activities')
              .delete()
              .eq('team_name', teamName)
              .eq('runner_name', runnerName)
              .eq('start_time', startIso)
              .eq('end_time', endIso);
        } catch (e) {
          debugPrint(formatBackendError(e,
              context:
                  'restore activities: pre-insert interval cleanup skipped'));
        }
      }

      if (startIso.isNotEmpty && endIso.isNotEmpty) {
        try {
          final existingSameInterval = await _supabase
              .from('activities')
              .select('id')
              .eq('team_name', teamName)
              .eq('runner_name', runnerName)
              .eq('start_time', startIso)
              .eq('end_time', endIso)
              .limit(1);
          if ((existingSameInterval as List).isNotEmpty) {
            continue;
          }
        } catch (e) {
          debugPrint(formatBackendError(e,
              context:
                  'restore activities: pre-insert duplicate check skipped'));
        }
      }

      try {
        await _supabase.from('activities').insert(payloadWithTimes);
        inserted += 1;
      } catch (e2) {
        final msg = formatBackendError(e2,
            context: 'restore activities: per-row insert with times failed');
        _lastRestoreInsertError = msg;
        debugPrint(msg);
        try {
          await _supabase.from('activities').insert({
            'team_name': teamName,
            'runner_name': runnerName,
            'km': km,
            'created_at': DateTime.now().toUtc().toIso8601String(),
          });
          inserted += 1;
        } catch (e3) {
          final msg = formatBackendError(e3,
              context:
                  'restore activities: per-row insert without times failed');
          _lastRestoreInsertError = msg;
          debugPrint(msg);

          // Last-resort path: use raw REST with current session token to bypass SDK serialization quirks.
          try {
            await _insertActivityViaRestWithSession(payloadWithTimes);
            inserted += 1;
          } catch (e4) {
            final msg =
                'restore activities: REST insert with times failed: $e4';
            _lastRestoreInsertError = msg;
            debugPrint(msg);
            try {
              await _insertActivityViaRestWithSession({
                'team_name': teamName,
                'runner_name': runnerName,
                'km': km,
                'created_at': DateTime.now().toUtc().toIso8601String(),
              });
              inserted += 1;
            } catch (e5) {
              final msg =
                  'restore activities: REST insert without times failed: $e5';
              _lastRestoreInsertError = msg;
              debugPrint(msg);
            }
          }
        }
      }
    }
    return inserted;
  }

  Future<void> _restoreActivities() async {
    if (_isRestoringActivities) return;

    setState(() {
      _isRestoringActivities = true;
    });

    try {
      try {
        await _supabase.auth.refreshSession();
      } catch (e) {
        debugPrint(formatBackendError(e,
            context: 'restore activities: refreshSession failed'));
      }

      final user = _supabase.auth.currentUser;
      if (user == null) {
        _showRestoreStatus('Nejste přihlášen.');
        return;
      }

      final metadata = user.userMetadata ?? {};
      final runnerName = (metadata['runner_name'] ?? '').toString().trim();
      String teamName = (metadata['team_name'] ?? '').toString().trim();
      final rawTeamId = metadata['team_id'];
      final int? teamId = rawTeamId is int
          ? rawTeamId
          : (rawTeamId is num
              ? rawTeamId.toInt()
              : int.tryParse(rawTeamId?.toString() ?? ''));

      if (teamId != null) {
        try {
          final teams = await loadTeamsSafe(_supabase, ascending: true);
          final matchingTeam = teams.where((t) => t['id'] == teamId).toList();
          if (matchingTeam.isNotEmpty) {
            final canonicalName =
                (matchingTeam.first['name'] ?? '').toString().trim();
            if (canonicalName.isNotEmpty) {
              teamName = canonicalName;
            }
          }
        } catch (e) {
          debugPrint(formatBackendError(e,
              context:
                  'restore activities: canonical team name lookup failed'));
        }
      }

      if (runnerName.isEmpty || teamName.isEmpty) {
        _showRestoreStatus('V profilu chybí jméno běžce nebo tým.');
        return;
      }

      final allChallenges =
          await loadChallengesSafe(_supabase, ascending: true);
      final challengeRows = allChallenges;
      final teamNameLower = teamName.toLowerCase();
      DateTime? earliestStart;

      for (final challenge in challengeRows) {
        final teamsRaw = (challenge['team_names'] ?? '').toString();
        final teams = _parseChallengeTeams(teamsRaw);
        if (!teams.contains(teamNameLower)) continue;

        final startRaw = challenge['start_date']?.toString() ?? '';
        final start = DateTime.tryParse(startRaw)?.toLocal();
        if (start == null) continue;

        if (earliestStart == null || start.isBefore(earliestStart)) {
          earliestStart = start;
        }
      }

      if (earliestStart == null) {
        _showRestoreStatus('Pro váš tým nebyla nalezena žádná aktuální výzva.');
        return;
      }

      final MethodChannel healthChannel =
          const MethodChannel('team_run_challenge/health_connect');
      final Health health = Health();
      await health.configure();

      final isAvailable = await healthChannel
              .invokeMethod<bool>('checkHealthConnectAvailability') ??
          false;
      if (!isAvailable) {
        _showRestoreStatus('Health Connect není na tomto zařízení dostupný.');
        return;
      }

      final hasPermissions =
          await healthChannel.invokeMethod<bool>('requestDistanceAccess') ??
              false;
      if (!hasPermissions) {
        _showRestoreStatus('Health Connect neudělil oprávnění.');
        return;
      }

      final hasWorkoutPermissions = await health.requestAuthorization(
        [
          HealthDataType.DISTANCE_DELTA,
          HealthDataType.WORKOUT,
        ],
        permissions: [
          HealthDataAccess.READ,
          HealthDataAccess.READ,
        ],
      );
      if (!hasWorkoutPermissions) {
        _showRestoreStatus(
            'Health Connect neudělil oprávnění na ExerciseSession (WORKOUT).');
        return;
      }

      bool historyGranted = true;
      try {
        historyGranted = await health.requestHealthDataHistoryAuthorization();
      } catch (e) {
        debugPrint('Health history authorization request failed: $e');
      }

      final now = DateTime.now();
      var healthData = await health.getHealthDataFromTypes(
        types: const [
          HealthDataType.DISTANCE_DELTA,
        ],
        startTime: earliestStart,
        endTime: now,
      );

      List<HealthDataPoint> workoutData = [];
      try {
        workoutData = await health.getHealthDataFromTypes(
          types: const [HealthDataType.WORKOUT],
          startTime: earliestStart,
          endTime: now,
        );
      } catch (e) {
        debugPrint('Chyba načítání workout sessions při obnově: $e');
      }
      final runningSessions = extractRunningSessionRanges(workoutData);
      List<DateTimeRange> effectiveRunningSessions = runningSessions;
      if (effectiveRunningSessions.isEmpty) {
        try {
          effectiveRunningSessions = await loadRunningSessionsFromNative(
              healthChannel, earliestStart, now);
          debugPrint(
              'Native running sessions fallback count (restore): ${effectiveRunningSessions.length}');
        } catch (e) {
          debugPrint('Native running sessions fallback failed (restore): $e');
        }
      }

      if (effectiveRunningSessions.isEmpty) {
        final recentStart = DateTime.now().subtract(const Duration(days: 30));
        List<HealthDataPoint> recentWorkoutData = [];
        try {
          recentWorkoutData = await health.getHealthDataFromTypes(
            types: const [HealthDataType.WORKOUT],
            startTime: recentStart,
            endTime: now,
          );
        } catch (e) {
          debugPrint('Recent workout read failed: $e');
        }

        final workoutTypeNames = extractWorkoutTypeNames(workoutData);
        final preview = compactWorkoutTypePreview(workoutTypeNames);
        final recentPreview = compactWorkoutTypePreview(
            extractWorkoutTypeNames(recentWorkoutData));
        _showRestoreStatus(
          'Nenalezeny bezecke ExerciseSession. Cele okno: ${workoutData.length} ($preview), poslednich 30 dni: ${recentWorkoutData.length} ($recentPreview), history perm: $historyGranted.',
        );
        return;
      }

      List<Map<String, dynamic>> existingRows = await loadActivitiesSafe(
        _supabase,
        runnerName: runnerName,
        teamName: teamName,
        ascending: true,
      );
      if (existingRows.isEmpty) {
        // Fallback for case/whitespace mismatch in metadata vs stored values.
        final allRows = await loadActivitiesSafe(_supabase, ascending: true);
        final runnerLower = runnerName.trim().toLowerCase();
        final teamLower = teamName.trim().toLowerCase();
        existingRows = allRows.where((row) {
          final rowRunner =
              (row['runner_name'] ?? '').toString().trim().toLowerCase();
          final rowTeam =
              (row['team_name'] ?? '').toString().trim().toLowerCase();
          return rowRunner == runnerLower && rowTeam == teamLower;
        }).toList();
      }
      debugPrint(
          'RESTORE_STATUS: existing rows for runner/team = ${existingRows.length}');
      int insertedCount = 0;

      final existingKeys = <String>{};
      final existingTimeKeys = <String>{};
      final duplicateRowIds = <dynamic>[];
      for (final row in existingRows) {
        final startIso = (row['start_time'] ?? '').toString();
        final endIso = (row['end_time'] ?? '').toString();
        final km = (row['km'] as num?)?.toDouble() ?? 0.0;
        if (startIso.isEmpty || endIso.isEmpty) continue;
        final startDt = DateTime.tryParse(startIso)?.toUtc();
        final endDt = DateTime.tryParse(endIso)?.toUtc();
        if (startDt == null || endDt == null) continue;

        final timeKey = _activityTimeKey(startDt, endDt);
        if (existingTimeKeys.contains(timeKey)) {
          duplicateRowIds.add(row['id']);
          continue;
        }
        existingTimeKeys.add(timeKey);

        if (km <= 0) continue;
        final key = _activityKey(startDt, endDt, km);
        if (existingKeys.contains(key)) {
          duplicateRowIds.add(row['id']);
        } else {
          existingKeys.add(key);
        }
      }

      for (final duplicateId in duplicateRowIds) {
        if (duplicateId == null) continue;
        try {
          await _supabase.from('activities').delete().eq('id', duplicateId);
        } catch (e) {
          debugPrint(formatBackendError(e,
              context: 'restore activities: duplicate delete skipped'));
        }
      }

      final healthSegments = <Map<String, dynamic>>[];
      for (final point in healthData) {
        if (!overlapsRunningSession(
            point.dateFrom, point.dateTo, effectiveRunningSessions)) {
          continue;
        }
        if (point.value is! NumericHealthValue) continue;

        final meters =
            (point.value as NumericHealthValue).numericValue.toDouble();
        final km = meters / 1000.0;
        if (km <= 0.01) continue;

        final startIso = point.dateFrom.toUtc().toIso8601String();
        final endIso = point.dateTo.toUtc().toIso8601String();
        final startDtUtc = point.dateFrom.toUtc();
        final endDtUtc = point.dateTo.toUtc();
        final timeKey = _activityTimeKey(startDtUtc, endDtUtc);
        healthSegments.add({
          'start_iso': startIso,
          'end_iso': endIso,
          'start_dt': point.dateFrom.toLocal(),
          'end_dt': point.dateTo.toLocal(),
          'km': km,
          'time_key': timeKey,
          'key': _activityKey(startDtUtc, endDtUtc, km),
        });
      }

      final toInsert = <Map<String, dynamic>>[];
      for (final segment in healthSegments) {
        final key = segment['key'] as String;
        final timeKey = segment['time_key'] as String;
        if (existingTimeKeys.contains(timeKey)) continue;
        if (existingKeys.contains(key)) continue;

        existingTimeKeys.add(timeKey);
        existingKeys.add(key);
        toInsert.add({
          'team_name': teamName,
          'runner_name': runnerName,
          'km': segment['km'],
          'start_time': segment['start_iso'],
          'end_time': segment['end_iso'],
        });
      }
      final int segmentsCount = healthSegments.length;
      final int candidatesCount = toInsert.length;

      // Fresh database bootstrap: import everything when user has no activities yet.
      if (existingRows.isEmpty) {
        insertedCount += await _insertActivitiesWithFallback(toInsert);

        if (teamId != null) {
          try {
            final teamActivities = await _supabase
                .from('activities')
                .select('km')
                .eq('team_name', teamName);
            double teamKm = 0.0;
            for (final row in List<Map<String, dynamic>>.from(teamActivities)) {
              teamKm += (row['km'] as num?)?.toDouble() ?? 0.0;
            }
            await _supabase
                .from('teams')
                .update({'km': teamKm}).eq('id', teamId);
          } catch (e) {
            debugPrint(formatBackendError(e,
                context: 'restore activities: team km recalculation skipped'));
          }
        }

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
            'last_sync_time', DateTime.now().toUtc().toIso8601String());

        await _loadUserData();
        if (candidatesCount > 0 &&
            insertedCount == 0 &&
            _lastRestoreInsertError != null) {
          _showRestoreStatus(
            'Obnova: Segmenty $segmentsCount, kandidáti $candidatesCount, přidáno 0. Detail insert chyby: $_lastRestoreInsertError',
          );
        } else {
          _showRestoreStatus(
            'Obnova dokončena. Segmenty: $segmentsCount, kandidáti: $candidatesCount, přidáno aktivit: $insertedCount.',
          );
        }
        return;
      }

      insertedCount += await _insertActivitiesWithFallback(toInsert);

      int repairedCount = 0;
      int deletedCount = 0;
      final usedSegmentKeys = <String>{};
      final repairedIds = <dynamic>{};
      for (final row in existingRows) {
        final rowId = row['id'];
        if (rowId == null) continue;

        final startIso = (row['start_time'] ?? '').toString();
        final endIso = (row['end_time'] ?? '').toString();
        final currentKm = (row['km'] as num?)?.toDouble() ?? 0.0;
        final hasMissing = startIso.isEmpty || endIso.isEmpty || currentKm <= 0;
        if (!hasMissing) continue;

        final createdAtRaw = (row['created_at'] ?? '').toString();
        final createdAt = DateTime.tryParse(createdAtRaw)?.toLocal();

        Map<String, dynamic>? best;
        double bestScore = double.infinity;
        for (final segment in healthSegments) {
          final key = segment['key'] as String;
          if (usedSegmentKeys.contains(key)) continue;

          final segmentKm = segment['km'] as double;
          final segmentEnd = segment['end_dt'] as DateTime;
          final kmDiff = currentKm > 0 ? (segmentKm - currentKm).abs() : 0.0;
          final timeDiffHours = createdAt == null
              ? 0.0
              : (segmentEnd.difference(createdAt).inMinutes.abs() / 60.0);
          final score = (kmDiff * 1000) + timeDiffHours;

          if (score < bestScore) {
            bestScore = score;
            best = segment;
          }
        }

        if (best == null) continue;

        final updatePayload = {
          'start_time': best['start_iso'],
          'end_time': best['end_iso'],
          'km': best['km'],
        };

        try {
          await _supabase
              .from('activities')
              .update(updatePayload)
              .eq('id', rowId);
          usedSegmentKeys.add(best['key'] as String);
          repairedIds.add(rowId);
          repairedCount += 1;
        } catch (e1) {
          debugPrint(formatBackendError(e1,
              context: 'restore activities: update with times failed'));
          try {
            await _supabase
                .from('activities')
                .update({'km': best['km']}).eq('id', rowId);
            repairedIds.add(rowId);
            repairedCount += 1;
          } catch (e2) {
            debugPrint(formatBackendError(e2,
                context: 'restore activities: update km-only failed'));
          }
        }
      }

      final healthKeys =
          healthSegments.map((segment) => segment['key'] as String).toSet();

      for (final row in existingRows) {
        final rowId = row['id'];
        if (rowId == null) continue;

        final referenceRaw =
            (row['start_time'] ?? row['end_time'] ?? row['created_at'] ?? '')
                .toString();
        final referenceTime = DateTime.tryParse(referenceRaw)?.toLocal();
        if (referenceTime == null || referenceTime.isBefore(earliestStart)) {
          continue;
        }

        final startIso = (row['start_time'] ?? '').toString();
        final endIso = (row['end_time'] ?? '').toString();
        final km = (row['km'] as num?)?.toDouble() ?? 0.0;
        final hasCompleteKey =
            startIso.isNotEmpty && endIso.isNotEmpty && km > 0;

        bool shouldDelete = false;
        if (hasCompleteKey) {
          final startDt = DateTime.tryParse(startIso)?.toUtc();
          final endDt = DateTime.tryParse(endIso)?.toUtc();
          if (startDt == null || endDt == null) {
            shouldDelete = !repairedIds.contains(rowId);
          } else {
            final key = _activityKey(startDt, endDt, km);
            shouldDelete = !healthKeys.contains(key);
          }
        } else {
          shouldDelete = !repairedIds.contains(rowId);
        }

        if (!shouldDelete) continue;

        try {
          await _supabase.from('activities').delete().eq('id', rowId);
          deletedCount += 1;
        } catch (e) {
          debugPrint(formatBackendError(e,
              context: 'restore activities: delete stale row skipped'));
        }
      }

      if (teamId != null) {
        try {
          final teamActivities = await _supabase
              .from('activities')
              .select('km')
              .eq('team_name', teamName);
          double teamKm = 0.0;
          for (final row in List<Map<String, dynamic>>.from(teamActivities)) {
            teamKm += (row['km'] as num?)?.toDouble() ?? 0.0;
          }
          await _supabase.from('teams').update({'km': teamKm}).eq('id', teamId);
        } catch (e) {
          debugPrint(formatBackendError(e,
              context:
                  'restore activities: final team km recalculation skipped'));
        }
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
          'last_sync_time', DateTime.now().toUtc().toIso8601String());

      await _loadUserData();
      if (candidatesCount > 0 &&
          insertedCount == 0 &&
          _lastRestoreInsertError != null) {
        _showRestoreStatus(
          'Obnova: Segmenty $segmentsCount, kandidáti $candidatesCount, přidáno 0. Detail insert chyby: $_lastRestoreInsertError',
        );
      } else {
        _showRestoreStatus(
          'Obnova dokončena. Segmenty: $segmentsCount, kandidáti: $candidatesCount, přidáno: $insertedCount, opraveno: $repairedCount, smazáno: $deletedCount.',
        );
      }
    } catch (e) {
      _showRestoreStatus('Obnova aktivit selhala: ${formatBackendError(e)}');
    } finally {
      if (mounted) {
        setState(() {
          _isRestoringActivities = false;
        });
      }
    }
  }

  String _formatActivityTime(String? iso) {
    if (iso == null || iso.isEmpty) return '--.--.---- --:--';
    final date = DateTime.parse(iso).toLocal();
    return '${date.day.toString().padLeft(2, '0')}.${date.month.toString().padLeft(2, '0')}.${date.year} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _pickAvatar(ImageSource source) async {
    try {
      final file = await _picker.pickImage(
          source: source, imageQuality: 75, maxWidth: 600);
      if (file == null) return;
      final bytes = await file.readAsBytes();
      final encoded = base64Encode(bytes);
      if (!mounted) return;
      setState(() {
        _avatarBase64 = encoded;
      });
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nepodařilo se vybrat avatar.')),
      );
    }
  }

  void _showAvatarPicker() {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) {
        return SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.photo_library),
                title: const Text('Vybrat z galerie'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickAvatar(ImageSource.gallery);
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_camera),
                title: const Text('Pořídit fotku'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickAvatar(ImageSource.camera);
                },
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Profil'),
        backgroundColor: Colors.orange,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pushAndRemoveUntil(
              context,
              MaterialPageRoute(builder: (_) => const ChallengeDashboard()),
              (route) => false,
            );
          },
        ),
        actions: [buildAppMenu(context)],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Profil',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    Center(
                      child: Column(
                        children: [
                          CircleAvatar(
                            radius: 46,
                            backgroundColor:
                                Colors.orange.withValues(alpha: 0.2),
                            backgroundImage: _avatarBase64 != null
                                ? MemoryImage(base64Decode(_avatarBase64!))
                                : null,
                            child: _avatarBase64 == null
                                ? const Icon(Icons.person,
                                    size: 46, color: Colors.orange)
                                : null,
                          ),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: _showAvatarPicker,
                            icon: const Icon(Icons.photo_camera),
                            label: const Text('Přidat/Změnit avatar'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: TextEditingController(text: _email),
                      decoration: const InputDecoration(
                          labelText: 'Email', border: OutlineInputBorder()),
                      enabled: false,
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _nameController,
                      decoration: const InputDecoration(
                          labelText: 'Jméno', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    if (_isLoadingTeams)
                      const Center(child: CircularProgressIndicator())
                    else if (_availableTeams.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: Text(
                          'V databázi nebyly nalezeny žádné týmy.',
                          style: TextStyle(color: Colors.red),
                        ),
                      )
                    else
                      DropdownButtonFormField<int>(
                        initialValue: _selectedTeamId,
                        decoration: const InputDecoration(
                          labelText: 'Tým',
                          border: OutlineInputBorder(),
                        ),
                        items: _availableTeams.map((team) {
                          return DropdownMenuItem<int>(
                            value: team['id'] as int,
                            child: Text(team['name'] ?? 'Tým'),
                          );
                        }).toList(),
                        onChanged: _isSavingProfile
                            ? null
                            : (value) {
                                setState(() {
                                  _selectedTeamId = value;
                                });
                              },
                      ),
                    const SizedBox(height: 12),
                    ElevatedButton(
                      onPressed: _isSavingProfile ? null : _saveProfile,
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange),
                      child: Text(
                          _isSavingProfile ? 'Ukládám...' : 'Uložit změny'),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton.icon(
                      onPressed:
                          _isRestoringActivities ? null : _restoreActivities,
                      style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange.shade700),
                      icon: _isRestoringActivities
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.sync),
                      label: Text(_isRestoringActivities
                          ? 'Obnovuji aktivity...'
                          : 'Obnovit aktivity'),
                    ),
                    const SizedBox(height: 24),
                    const Text('Historie aktivit',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 12),
                    if (_activities.isEmpty)
                      const Text('Zatím žádná osobní historie.',
                          style: TextStyle(color: Colors.grey)),
                    ..._activities.map((act) {
                      final kmValue =
                          (act['km'] as num?)?.toStringAsFixed(1) ?? '0.0';
                      final startAt =
                          _formatActivityTime(act['start_time'] as String?);
                      final endAt =
                          _formatActivityTime(act['end_time'] as String?);
                      final teamName = act['team_name'] ?? 'Tým';
                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 6),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor:
                                Colors.orange.withValues(alpha: 0.2),
                            backgroundImage: _avatarBase64 != null
                                ? MemoryImage(base64Decode(_avatarBase64!))
                                : null,
                            child: _avatarBase64 == null
                                ? const Icon(Icons.person, color: Colors.orange)
                                : null,
                          ),
                          title: Text('$kmValue km • $teamName'),
                          subtitle: Text('Start: $startAt\nKonec: $endAt'),
                          isThreeLine: true,
                        ),
                      );
                    }),
                  ],
                ),
              ),
      ),
    );
  }
}

Widget _buildTeamCard(String name, double current, double target, Color color) {
  double percentage = current / target;
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
              Text(name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
              Text('${current.toStringAsFixed(1)} / ${target.toInt()} km',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w500)),
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

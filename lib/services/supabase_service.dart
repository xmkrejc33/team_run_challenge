import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:health/health.dart';
import '../utils/helpers.dart';
import '../utils/health_helper.dart';

const String kSupabaseUrl = 'https://xfnfzgragzlwhefniawp.supabase.co';
const String kSupabasePublishableKey =
  'sb_publishable_3BzkICJSF9v52DDBZwPcrg_Zyi_JgJi';

class SupabaseService {
  static final client = Supabase.instance.client;

  static Future<String> createHealthShortcutToken() async {
    final response = await client.functions.invoke('create-health-shortcut-token');
    final data = Map<String, dynamic>.from(response.data as Map);
    final token = data['token']?.toString() ?? '';
    if (token.isEmpty) throw Exception(data['error']?.toString() ?? 'Token se nepodařilo vytvořit.');
    return token;
  }

  static Future<Map<String, dynamic>> loadCurrentProfile() async {
    final user = client.auth.currentUser;
    if (user == null) throw Exception('No authenticated user');

    final profile = await client.from('profiles').select(
      'user_id, runner_name, team_id, team_name, avatar_base64, last_sync_at',
    ).eq('user_id', user.id).maybeSingle();
    if (profile != null) return Map<String, dynamic>.from(profile);

    final metadata = user.userMetadata ?? {};
    final fallback = <String, dynamic>{
      'user_id': user.id,
      'runner_name': (metadata['runner_name'] ?? 'Anonymní běžec').toString(),
      'team_id': int.tryParse(metadata['team_id']?.toString() ?? ''),
      'team_name': metadata['team_name']?.toString(),
      'avatar_base64': metadata['avatar_base64']?.toString(),
    };
    await client.from('profiles').upsert(fallback, onConflict: 'user_id');
    return fallback;
  }

  static Future<void> saveCurrentProfile({
    required String runnerName,
    required int? teamId,
    required String? teamName,
    required String? avatarBase64,
  }) async {
    final userId = await requireAuthenticatedUserId();
    await client.from('profiles').upsert({
      'user_id': userId,
      'runner_name': runnerName,
      'team_id': teamId,
      'team_name': teamName,
      'avatar_base64': avatarBase64,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, onConflict: 'user_id');
  }

  static Future<void> saveLastActivitySync(DateTime time) async {
    final userId = await requireAuthenticatedUserId();
    await client.from('profiles').update({
      'last_sync_at': time.toUtc().toIso8601String(),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('user_id', userId);
  }

  static Future<DateTime?> loadLastActivityUploadAt({
    required String runnerName,
    required String teamName,
  }) async {
    final activities = await loadActivitiesSafe(
      runnerName: runnerName,
      teamName: teamName,
      ascending: false,
    );
    DateTime? latestUploadAt;
    for (final activity in activities) {
      final uploadedAt = DateTime.tryParse(
        (activity['created_at'] ?? '').toString(),
      );
      if (uploadedAt != null &&
          (latestUploadAt == null || uploadedAt.isAfter(latestUploadAt))) {
        latestUploadAt = uploadedAt;
      }
    }
    return latestUploadAt;
  }

  static Future<void> deleteCurrentUserActivities({
    required String runnerName,
    required String teamName,
  }) async {
    await requireAuthenticatedUserId();
    await client
        .from('activities')
        .delete()
        .eq('runner_name', runnerName.trim())
        .eq('team_name', teamName.trim());
  }

  static Future<String> requireAuthenticatedUserId() async {
    await client.auth.refreshSession();
    final user = client.auth.currentUser;
    final session = client.auth.currentSession;
    final accessToken = session?.accessToken;
    if (user == null || session == null || accessToken == null || accessToken.isEmpty) {
      throw Exception('Session missing (user/session/token)');
    }
    final payload = tryDecodeJwtPayload(accessToken);
    final role = (payload?['role'] ?? '').toString();
    final sub = (payload?['sub'] ?? '').toString();
    if (role != 'authenticated' || sub.isEmpty || sub != user.id) {
      throw Exception('Invalid auth token context (role=$role, sub=$sub, user=${user.id})');
    }
    return user.id;
  }

  static Future<List<Map<String, dynamic>>> fetchPublicRows({
    required String table,
    required String select,
    String? orderColumn,
    bool ascending = true,
    Map<String, String>? extraQuery,
  }) async {
    final query = <String, String>{'select': select};
    if (extraQuery != null) query.addAll(extraQuery);
    if (orderColumn != null && orderColumn.isNotEmpty) {
      query['order'] = '$orderColumn.${ascending ? 'asc' : 'desc'}';
    }

    final uri = Uri.parse('$kSupabaseUrl/rest/v1/$table').replace(queryParameters: query);
    final httpClient = HttpClient();
    try {
      final request = await httpClient.getUrl(uri);
      request.headers.set('apikey', kSupabasePublishableKey);
      request.headers.set('Authorization', 'Bearer $kSupabasePublishableKey');
      request.headers.set('Accept', 'application/json');

      final response = await request.close();
      final body = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('public REST $table failed: HTTP ${response.statusCode}, body=$body');
      }
      return List<Map<String, dynamic>>.from(jsonDecode(body));
    } finally {
      httpClient.close(force: true);
    }
  }

  static Future<void> insertRowViaRestWithSession({
    required String table,
    required Map<String, dynamic> payload,
  }) async {
    final accessToken = client.auth.currentSession?.accessToken;
    if (accessToken == null || accessToken.isEmpty) {
      throw Exception('Missing authenticated session token for REST insert into $table');
    }

    final uri = Uri.parse('$kSupabaseUrl/rest/v1/$table');
    final httpClient = HttpClient();
    httpClient.userAgent = 'Mozilla/5.0 (Android 14; Mobile; rv:128.0) FlutterTeamRun/1.0';
    try {
      final request = await httpClient.postUrl(uri);
      request.headers.set('apikey', kSupabasePublishableKey);
      request.headers.set('Authorization', 'Bearer $accessToken');
      request.headers.set('Content-Type', 'application/json; charset=utf-8');
      request.headers.set('Content-Profile', 'public');
      request.headers.set('Accept-Profile', 'public');
      request.headers.set('Accept', 'application/json');
      request.headers.set('Prefer', 'return=minimal');
      final bodyBytes = utf8.encode(jsonEncode(payload));
      request.contentLength = bodyBytes.length;
      request.add(bodyBytes);

      final response = await request.close();
      final body = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception(
          'REST insert $table failed: HTTP ${response.statusCode}, '
          'contentType=${response.headers.contentType}, body=$body, payload=${jsonEncode(payload)}',
        );
      }
    } finally {
      httpClient.close(force: true);
    }
  }

  static Future<List<Map<String, dynamic>>> loadTeamsSafe({bool ascending = true}) async {
    final data = await _loadWithFallbacks([
      _FallbackAttempt(
        context: 'teams public REST read failed',
        load: () => fetchPublicRows(table: 'teams', select: 'id,name,km,originator_id', orderColumn: 'id', ascending: ascending),
      ),
      _FallbackAttempt(
        context: 'teams select failed',
        load: () => client.from('teams').select('id, name, km, originator_id').order('id', ascending: ascending),
      ),
    ], 'teams load');

    return List<Map<String, dynamic>>.from(data).map((row) {
      final normalized = Map<String, dynamic>.from(row);
      normalized['name'] = (normalized['name'] ?? '').toString();
      normalized['km'] = (normalized['km'] as num?)?.toDouble() ?? 0.0;
      normalized['originator_id'] = normalized['originator_id']?.toString();
      return normalized;
    }).toList();
  }

  static Future<List<Map<String, dynamic>>> loadActivitiesSafe({
    String? runnerName,
    String? teamName,
    bool ascending = false,
  }) async {
    await requireAuthenticatedUserId();

    final data = await _loadWithFallbacks([
      _FallbackAttempt(
        context: 'activities select failed',
        load: () => client.from('activities').select('id, team_name, runner_name, km, start_time, end_time, created_at'),
      ),
      _FallbackAttempt(
        context: 'activities public REST read failed',
        load: () => fetchPublicRows(
          table: 'activities',
          select: 'id,team_name,runner_name,km,start_time,end_time,created_at',
          orderColumn: null,
        ),
      ),
      _FallbackAttempt(
        context: 'activities minimal read failed',
        load: () => client.from('activities').select('team_name, runner_name, km, start_time, end_time, created_at'),
      ),
    ], 'activities load');

    final activities = List<Map<String, dynamic>>.from(data).map((row) {
      final normalized = Map<String, dynamic>.from(row);
      normalized['team_name'] = (normalized['team_name'] ?? '').toString();
      normalized['runner_name'] = (normalized['runner_name'] ?? '').toString();
      normalized['km'] = (normalized['km'] as num?)?.toDouble() ?? 0.0;
      return normalized;
    }).where((activity) {
      final matchesRunner = runnerName == null || runnerName.isEmpty || activity['runner_name'] == runnerName;
      final matchesTeam = teamName == null || teamName.isEmpty || activity['team_name'] == teamName;
      return matchesRunner && matchesTeam;
    }).toList();
    activities.sort((left, right) {
      final leftTime = DateTime.tryParse((left['start_time'] ?? '').toString());
      final rightTime = DateTime.tryParse((right['start_time'] ?? '').toString());
      final comparison = (leftTime ?? DateTime.fromMillisecondsSinceEpoch(0)).compareTo(
        rightTime ?? DateTime.fromMillisecondsSinceEpoch(0),
      );
      return ascending ? comparison : -comparison;
    });
    return activities;
  }

  static Future<List<Map<String, dynamic>>> loadChallengesSafe({bool ascending = false}) async {
    final data = await _loadWithFallbacks([
      _FallbackAttempt(
        context: 'challenges public REST read failed',
        load: () => fetchPublicRows(
          table: 'challenges',
          select: 'id,name,start_date,distance,team_names,is_active,originator_id',
          orderColumn: 'start_date',
          ascending: ascending,
        ),
      ),
      _FallbackAttempt(
        context: 'challenges select failed',
        load: () => client.from('challenges').select('id, name, start_date, distance, team_names, is_active, originator_id').order('start_date', ascending: ascending),
      ),
    ], 'challenges load');

    return List<Map<String, dynamic>>.from(data).map((row) {
      final normalized = Map<String, dynamic>.from(row);
      normalized['name'] = (normalized['name'] ?? '').toString();
      normalized['team_names'] = (normalized['team_names'] ?? '').toString();
      normalized['is_active'] = normalized['is_active'] == false ? false : true;
      normalized['distance'] = (normalized['distance'] as num?)?.toDouble() ?? 0.0;
      return normalized;
    }).toList();
  }

  static Future<int> restoreActivities({
    required String runnerName,
    required String teamName,
    required Function(String) onStatusUpdate,
    required DateTime startTime,
  }) async {
    final client = Supabase.instance.client;
    try {
      onStatusUpdate('Ověřuji přihlášení...');
      await requireAuthenticatedUserId();
      debugPrint('Activity restore: authenticated session verified');
      onStatusUpdate('Konfiguruji Health...');
      debugPrint('Activity restore: Health configuration delegated to HealthHelper');

      final now = DateTime.now();

      onStatusUpdate('Načítám data z ${HealthHelper.providerName}...');
      final healthData = await HealthHelper.loadDistanceData(
        startTime: startTime,
        endTime: now,
      );
      debugPrint('Activity restore: Health returned ${healthData.length} points');

      final safeRunnerName = runnerName.trim();
      final safeTeamName = teamName.trim();

      final existingActivities = await loadActivitiesSafe(
        runnerName: safeRunnerName,
        ascending: false,
      );
      final existingActivityKeys = existingActivities.map(_activityTimeKey).toSet();
      final sourceActivityKeys = <String>{};
      final List<Map<String, dynamic>> toInsert = [];

      // Zpracování dat a vynechání již uložených záznamů.
      for (final point in healthData) {
        if (point.value is! NumericHealthValue) continue;

        final meters = (point.value as NumericHealthValue).numericValue.toDouble();
        if (meters <= 10) continue;

        final start = point.dateFrom.toUtc();
        final end = point.dateTo.toUtc();
        if (start.isAfter(end)) continue;

        final km = meters / 1000.0;
        if (km <= 0 || safeRunnerName.isEmpty || safeTeamName.isEmpty) continue;

        final activityKey = _activityTimeKeyFromDates(start, end);
        if (existingActivityKeys.contains(activityKey) || !sourceActivityKeys.add(activityKey)) {
          continue;
        }

        toInsert.add({
          'team_name': safeTeamName,
          'runner_name': safeRunnerName,
          'km': double.parse(km.toStringAsFixed(3)),
          'start_time': start.toIso8601String(),
          'end_time': end.toIso8601String(),
        });
      }

      if (toInsert.isEmpty) {
        onStatusUpdate(
          healthData.isEmpty
              ? 'V ${HealthHelper.providerName} nebyla nalezena žádná data o vzdálenosti.'
              : 'Všechny nalezené aktivity už jsou v databázi.',
        );
        return 0;
      }

      onStatusUpdate('Vkládám ${toInsert.length} aktivit...');
      debugPrint('Activity restore: first payload=${jsonEncode(toInsert.first)}');

      final insertPayload = toInsert.take(50).toList();
      if (insertPayload.length != toInsert.length) {
        debugPrint('Bulk insert split: ${toInsert.length} rows -> ${insertPayload.length}');
      }

      var insertedCount = 0;
      Object? lastInsertError;
      for (final row in insertPayload) {
        try {
          debugPrint('Activity restore: calling activities insert');
          await client.from('activities').insert(row);
          insertedCount++;
          debugPrint('Activity restore: activities insert succeeded');
        } catch (e) {
          debugPrint(
            'Rejected activity row: ${formatBackendError(e, context: 'activities insert')}',
          );
          lastInsertError = e;
        }
      }

      if (insertedCount == 0) {
        throw Exception('Nepodařilo se uložit žádnou aktivitu do Supabase: $lastInsertError');
      }

      onStatusUpdate('Obnova dokončena. Uloženo $insertedCount aktivit.');
      return insertedCount;
    } catch (e) {
      onStatusUpdate(formatBackendError(e, context: 'Uložení aktivit selhalo'));
      rethrow;
    }
  }

  static String _activityTimeKey(Map<String, dynamic> activity) {
    final start = DateTime.tryParse((activity['start_time'] ?? '').toString());
    final end = DateTime.tryParse((activity['end_time'] ?? '').toString());
    return _activityTimeKeyFromDates(start, end);
  }

  static String _activityTimeKeyFromDates(DateTime? start, DateTime? end) {
    return '${start?.toUtc().millisecondsSinceEpoch ?? -1}:${end?.toUtc().millisecondsSinceEpoch ?? -1}';
  }

  static Future<dynamic> _loadWithFallbacks(List<_FallbackAttempt> attempts, String failureLabel) async {
    Object? lastError;
    for (final attempt in attempts) {
      try {
        return await attempt.load();
      } catch (e) {
        debugPrint(formatBackendError(e, context: attempt.context));
        lastError = e;
      }
    }
    throw Exception('$failureLabel failed: $lastError');
  }
}

class _FallbackAttempt {
  final String context;
  final Future<dynamic> Function() load;
  const _FallbackAttempt({required this.context, required this.load});
}


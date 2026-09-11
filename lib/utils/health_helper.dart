import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:health/health.dart';
import 'platform.dart';

class HealthHelper {
  static const MethodChannel _healthChannel = MethodChannel('team_run_challenge/health_connect');
  static final Health _health = Health();

  static String get providerName => isIOS ? 'Apple Health' : 'Health Connect';

  static List<DateTimeRange> extractRunningSessionRanges(List<HealthDataPoint> workoutPoints) {
    final ranges = <DateTimeRange>[];
    for (final point in workoutPoints) {
      if (point.type != HealthDataType.WORKOUT) continue;
      final workoutTypeName = resolveWorkoutTypeName(point).toLowerCase();
      final isRunning = workoutTypeName.contains('running') || workoutTypeName == 'run' || workoutTypeName.contains('run_');
      if (!isRunning) continue;
      ranges.add(DateTimeRange(start: point.dateFrom.toLocal(), end: point.dateTo.toLocal()));
    }
    return ranges;
  }

  static String resolveWorkoutTypeName(HealthDataPoint point) {
    if (point.value is WorkoutHealthValue) {
      return (point.value as WorkoutHealthValue).workoutActivityType.name;
    }
    final summaryType = point.workoutSummary?.workoutType.trim();
    if (summaryType != null && summaryType.isNotEmpty) return summaryType;
    final metadata = point.metadata;
    if (metadata != null) {
      final candidates = [metadata['workout_type'], metadata['workoutType'], metadata['workoutActivityType'], metadata['exercise_type'], metadata['exerciseType']];
      for (final candidate in candidates) {
        final value = candidate?.toString().trim() ?? '';
        if (value.isNotEmpty) return value;
      }
    }
    return '';
  }

  static bool overlapsRunningSession(DateTime start, DateTime end, List<DateTimeRange> sessions) {
    for (final session in sessions) {
      if (start.isBefore(session.end) && end.isAfter(session.start)) return true;
    }
    return false;
  }

  static Future<List<DateTimeRange>> loadRunningSessionsFromNative(DateTime start, DateTime end) async {
    if (!isAndroid) return const <DateTimeRange>[];
    debugPrint('HealthHelper: loadRunningSessionsFromNative start=${start.toIso8601String()} end=${end.toIso8601String()}');
    final response = await _healthChannel.invokeMethod<Map<dynamic, dynamic>>(
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
      ranges.add(DateTimeRange(
        start: DateTime.fromMillisecondsSinceEpoch(startMs, isUtc: true).toLocal(),
        end: DateTime.fromMillisecondsSinceEpoch(endMs, isUtc: true).toLocal(),
      ));
    }
    debugPrint('HealthHelper: native running sessions count=${ranges.length} raw=${sessionItems.length}');
    return ranges;
  }

  static Future<bool> checkHealthConnectAvailability() async {
    if (isIOS) {
      return true;
    }
    if (!isAndroid) return false;
    try {
      final status = await _healthChannel.invokeMethod<String>('checkHealthConnectAvailability');
      debugPrint('HealthHelper: availability status=$status');
      if (status == null) return false;
      return status == 'AVAILABLE' || status == 'UPDATE_REQUIRED';
    } catch (e) {
      debugPrint('HealthHelper: availability check failed: $e');
      return false;
    }
  }

  static Future<bool> requestDistanceAccess() async {
    if (isIOS) {
      return _requestHealthKitDistanceAccess();
    }
    if (!isAndroid) return false;
    try {
      final bool hasNative = await _healthChannel.invokeMethod<bool>('requestDistanceAccess') ?? false;
      debugPrint('HealthHelper: native permission result=$hasNative');
      if (hasNative) return true;
    } catch (e) {
      debugPrint('HealthHelper: native permission request threw: $e');
    }

    try {
      final result = await _health.requestAuthorization(
        [
          HealthDataType.DISTANCE_DELTA,
          HealthDataType.WORKOUT,
          HealthDataType.TOTAL_CALORIES_BURNED,
        ],
        permissions: [
          HealthDataAccess.READ,
          HealthDataAccess.READ,
          HealthDataAccess.READ,
        ],
      );
      debugPrint('HealthHelper: flutter authorization result=$result');
      return result;
    } catch (e) {
      debugPrint('HealthHelper: flutter authorization failed: $e');
      return false;
    }
  }

  static Future<bool> _requestHealthKitDistanceAccess() async {
    try {
      final result = await _health.requestAuthorization(
        [
          HealthDataType.DISTANCE_DELTA,
          HealthDataType.WORKOUT,
          HealthDataType.TOTAL_CALORIES_BURNED,
        ],
        permissions: const [
          HealthDataAccess.READ,
          HealthDataAccess.READ,
          HealthDataAccess.READ,
        ],
      );
      debugPrint('HealthHelper: HealthKit authorization result=$result');
      return result;
    } catch (e) {
      debugPrint('HealthHelper: HealthKit authorization failed: $e');
      return false;
    }
  }

  static Future<List<HealthDataPoint>> getHealthDataFromTypes({
    required List<HealthDataType> types,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    debugPrint('HealthHelper: fetching types=${types.map((e) => e.name).toList()} from=${startTime.toIso8601String()} to=${endTime.toIso8601String()}');
    try {
      await _health.configure();
      final data = await _health.getHealthDataFromTypes(types: types, startTime: startTime, endTime: endTime);
      debugPrint('HealthHelper: received ${data.length} data points');
      return data;
    } catch (e) {
      debugPrint('HealthHelper: getHealthDataFromTypes failed for $types: $e');
      return const <HealthDataPoint>[];
    }
  }

  static Future<List<HealthDataPoint>> loadDistanceData({
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    if (!await requestDistanceAccess()) {
      throw Exception(
        isIOS
            ? 'Apple Health nepovolil čtení vzdálenosti nebo historie aktivit.'
            : 'Health Connect nepovolil čtení vzdálenosti nebo historických dat.',
      );
    }
    await _health.configure();
    final data = await _health.getHealthDataFromTypes(
      types: const [HealthDataType.DISTANCE_DELTA],
      startTime: startTime,
      endTime: endTime,
    );
    if (data.isEmpty) {
      debugPrint(
        'HealthHelper: no DISTANCE_DELTA data in range '
        '${startTime.toUtc().toIso8601String()} - ${endTime.toUtc().toIso8601String()}',
      );
    }
    return data;
  }
}

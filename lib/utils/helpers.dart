import 'dart:convert';
import 'package:supabase_flutter/supabase_flutter.dart';

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

bool isRlsViolationError(Object error) {
  final lower = formatBackendError(error).toLowerCase();
  return lower.contains('42501') ||
      lower.contains('row-level security') ||
      lower.contains('rls');
}

String formatDateParts(DateTime dateTime, {bool includeTime = true}) {
  final day = dateTime.day.toString().padLeft(2, '0');
  final month = dateTime.month.toString().padLeft(2, '0');
  final year = dateTime.year.toString();
  if (!includeTime) return '$day.$month.$year';
  final hour = dateTime.hour.toString().padLeft(2, '0');
  final minute = dateTime.minute.toString().padLeft(2, '0');
  return '$day.$month.$year $hour:$minute';
}

String formatDateTimeOrDash(DateTime? dateTime, {bool includeTime = true}) {
  if (dateTime == null) return '--.--.---- --:--';
  return formatDateParts(dateTime, includeTime: includeTime);
}

List<String> parseCsvLabels(String rawTeamNames) {
  return rawTeamNames
      .split(',')
      .map((name) => name.trim())
      .where((name) => name.isNotEmpty)
      .toList();
}

Set<String> parseCsvLowerSet(String rawTeamNames) {
  return parseCsvLabels(rawTeamNames).map((name) => name.toLowerCase()).toSet();
}

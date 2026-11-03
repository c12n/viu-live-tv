// Remind Me — local notifications for upcoming programmes (the mobile
// counterpart of the iOS 1.5.0 reminders).
//
// Android only: on Windows every call is a no-op and the UI hides the
// feature. Scheduling uses inexact alarms, so no exact-alarm permission
// is needed; the POST_NOTIFICATIONS runtime permission is requested
// when the first reminder is set.

import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

class ReminderService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static bool get supported => Platform.isAndroid;

  static Future<void> _ensure() async {
    if (_ready || !supported) return;
    tzdata.initializeTimeZones();
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(const InitializationSettings(android: android));
    _ready = true;
  }

  /// Stable notification id per channel + programme start.
  static int idFor(int streamId, DateTime start) =>
      (streamId * 1000003 + start.millisecondsSinceEpoch ~/ 1000) &
      0x7fffffff;

  /// Schedule a reminder for [start]. Returns false when reminders are
  /// unsupported here or the start time has already passed.
  static Future<bool> schedule({
    required int streamId,
    required String channelName,
    required String programmeName,
    required DateTime start,
  }) async {
    if (!supported) return false;
    await _ensure();
    final androidImpl =
        _plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.requestNotificationsPermission();
    if (!start.isAfter(DateTime.now())) return false;
    await _plugin.zonedSchedule(
      idFor(streamId, start),
      programmeName,
      'Starting now on $channelName',
      tz.TZDateTime.from(start, tz.local),
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'viu_reminders',
          'Programme reminders',
          channelDescription:
              'Alerts when a programme you picked is starting',
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
    return true;
  }

  static Future<void> cancel({
    required int streamId,
    required DateTime start,
  }) async {
    if (!supported) return;
    await _ensure();
    await _plugin.cancel(idFor(streamId, start));
  }
}

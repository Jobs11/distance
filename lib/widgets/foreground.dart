import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 포그라운드 태스크 초기화
void initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'bluetooth_service',
      channelName: 'Bluetooth Background Service',
      channelDescription: 'ESP32 블루투스 연결 유지 서비스',
      channelImportance: NotificationChannelImportance.HIGH,
      priority: NotificationPriority.HIGH,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      autoRunOnBoot: false,
      allowWakeLock: true,
      allowWifiLock: true,
      eventAction: ForegroundTaskEventAction.repeat(
        5000,
      ), // 5초마다 onRepeatEvent 호출
    ),
  );
}

/// 포그라운드 서비스 시작
void startService() {
  FlutterForegroundTask.startService(
    notificationTitle: '앱 실행 중',
    notificationText: 'ESP32와 블루투스 연결 유지 중...',
  );
}

/// 포그라운드 서비스 중지
void stopService() {
  FlutterForegroundTask.stopService();
}

Future<void> _ensurePluginNotiPerm() async {
  // true면 이미 허용, false면 미허용
  final granted = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
  // (배터리최적화 무시 여기는 옵션)

  // Android 13+에서 알림 권한 요청
  await FlutterForegroundTask.requestNotificationPermission();
}

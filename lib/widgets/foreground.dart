import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

void initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'sld_service_v1',
      channelName: 'Smartphone Loss Device',
      channelDescription: '블루투스 연결 유지 서비스',
      channelImportance: NotificationChannelImportance.LOW,
      priority: NotificationPriority.LOW,
    ),
    iosNotificationOptions: const IOSNotificationOptions(
      showNotification: true,
      playSound: false,
    ),
    foregroundTaskOptions: ForegroundTaskOptions(
      allowWakeLock: true,
      allowWifiLock: true,
      eventAction: ForegroundTaskEventAction.repeat(5000),
    ),
  );
}

void startService() {
  FlutterForegroundTask.startService(
    notificationTitle: '앱 실행 중',
    notificationText: '블루투스 연결 유지 중...',
    callback: startCallback,
  );
}

void stopService() {
  FlutterForegroundTask.stopService();
}

class RssiForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[FG] onStart');
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('[FG] 종료됨');
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map && data['cmd'] == 'bindDevice') {
      final name = data['name'] ?? '알 수 없는 기기';
      // 기기 연결 시 1회만 알림 업데이트
      FlutterForegroundTask.updateService(
        notificationTitle: 'Smartphone Loss Device',
        notificationText: '$name 와 연결된 상태',
      );
    }
    // rssi 명령은 무시 (알림 갱신 X)
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(RssiForegroundTaskHandler());
}

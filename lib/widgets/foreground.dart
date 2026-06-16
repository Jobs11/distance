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
      eventAction: ForegroundTaskEventAction.repeat(1000), // 1초마다
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
  String _deviceName = '';
  bool _alarmActive = false;
  bool _blinkState = false;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    debugPrint('[FG] onStart');
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // 알람 활성 중일 때만 1초마다 깜빡임
    if (_alarmActive) {
      _blinkState = !_blinkState;
      FlutterForegroundTask.updateService(
        notificationTitle: _blinkState ? '🔴 범위 초과!' : '⚠️ 범위 초과!',
        notificationText: _blinkState
            ? '$_deviceName 가 범위를 벗어났습니다.'
            : '앱을 열어 알람을 끄세요.',
      );
    }
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint('[FG] 종료됨');
  }

  @override
  void onReceiveData(Object data) {
    if (data is Map && data['cmd'] == 'bindDevice') {
      _deviceName = data['name'] ?? '알 수 없는 기기';
      _alarmActive = false;
      FlutterForegroundTask.updateService(
        notificationTitle: 'Smartphone Loss Device',
        notificationText: '$_deviceName 와 연결된 상태',
      );
    }

    if (data is Map && data['cmd'] == 'alarmOn') {
      _deviceName = data['name'] ?? _deviceName;
      _alarmActive = true;
      _blinkState = true;
      FlutterForegroundTask.updateService(
        notificationTitle: '🔴 범위 초과!',
        notificationText: '$_deviceName 가 범위를 벗어났습니다.',
      );
    }

    if (data is Map && data['cmd'] == 'alarmOff') {
      _alarmActive = false;
      _blinkState = false;
      FlutterForegroundTask.updateService(
        notificationTitle: 'Smartphone Loss Device',
        notificationText: '$_deviceName 와 연결된 상태',
      );
    }
  }
}

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(RssiForegroundTaskHandler());
}

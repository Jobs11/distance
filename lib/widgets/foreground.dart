import 'dart:isolate';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 포그라운드 태스크 초기화
void initForegroundTask() {
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'bt_service_v5', // ← 새 채널 ID로 변경
      channelName: 'Bluetooth Background Service',
      channelDescription: 'ESP32 블루투스 연결 유지 서비스',
      channelImportance: NotificationChannelImportance.HIGH, // 중요
      priority: NotificationPriority.HIGH, // 중요
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

/// 포그라운드 서비스 시작
void startService() {
  FlutterForegroundTask.startService(
    notificationTitle: '앱 실행 중',
    notificationText: 'ESP32와 블루투스 연결 유지 중...',
    callback: startCallback,
  );
}

/// 포그라운드 서비스 중지
void stopService() {
  FlutterForegroundTask.stopService();
}

Future<void> ensureServiceRunning() async {
  final isRunning = await FlutterForegroundTask.isRunningService;
  if (!isRunning) {
    await FlutterForegroundTask.startService(
      notificationTitle: '앱 실행 중',
      notificationText: 'ESP32와 블루투스 연결 유지 중...',
      callback: startCallback,
    );
  }
}

Future<void> updateForegroundNotice({
  required String title,
  required String text,
}) async {
  if (await FlutterForegroundTask.isRunningService) {
    await FlutterForegroundTask.updateService(
      notificationTitle: title,
      notificationText: text,
    );
  }
}

class RssiForegroundTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    // 초기화 (예: 블루투스 연결 확인)
    debugPrint('[FG] onStart: ${starter.name}');
    await FlutterForegroundTask.updateService(
      notificationTitle: 'ESP32 연결 대기',
      notificationText: 'Foreground 준비 완료',
    );
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // 5초마다 실행됨
    // 여기서 RSSI 가져오기 → 조건에 따라 진동 or 알람
    debugPrint("RSSI 체크 실행됨: $timestamp");
    // FlutterForegroundTask.updateService(
    //   notificationText: 'tick ${DateTime.now().toIso8601String()}',
    // );
  }

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {
    debugPrint("Foreground Task 종료됨");
  }

  @override
  void onReceiveData(Object data) {
    // mainhome 등에서 sendDataToTask로 보낸 메시지 수신
    if (data is Map && data['cmd'] == 'bindDevice') {
      final deviceId = data['deviceId'];
      final name = data['name'];
      // 필요 시 내부 상태 저장, 알림 갱신 등
      FlutterForegroundTask.updateService(
        notificationTitle: 'ESP32 연결됨',
        notificationText: '$name ($deviceId)와 연결 유지 중…',
      );
    }

    if (data is Map && data['cmd'] == 'rssi') {
      final rssi = data['value'];
      FlutterForegroundTask.updateService(
        notificationTitle: 'RSSI 모니터링',
        notificationText: '현재 RSSI: $rssi dBm',
      );
      // 임계값 진동/사운드 로직도 여기서 처리 가능
    }
  }
}

/// Foreground Task 시작 콜백
@pragma('vm:entry-point')
void startCallback() {
  debugPrint('[FG] startCallback() 진입');
  FlutterForegroundTask.setTaskHandler(RssiForegroundTaskHandler());
}

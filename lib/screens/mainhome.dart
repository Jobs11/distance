import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:distance/widgets/foreground.dart';
import 'package:distance/widgets/rssiguard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Mainhome extends StatefulWidget {
  const Mainhome({super.key});
  @override
  State<Mainhome> createState() => _MainhomeState();
}

class _MainhomeState extends State<Mainhome> with WidgetsBindingObserver {
  // === Nordic UART Service (NUS) ===
  final Guid nusService = Guid("6e400001-b5a3-f393-e0a9-e50e24dcca9e");
  final Guid nusRxChar = Guid(
    "6e400003-b5a3-f393-e0a9-e50e24dcca9e",
  ); // notify (peripheral -> app)
  final Guid nusTxChar = Guid(
    "6e400002-b5a3-f393-e0a9-e50e24dcca9e",
  ); // write  (app -> peripheral)

  BluetoothDevice? _device;
  BluetoothConnectionState _connState = BluetoothConnectionState.disconnected;

  String _status = '대기';
  String _lastRecv = '-'; // 최근 토큰(숫자) 표시
  final List<String> _recvLog = <String>[]; // "시각 → 값" 로그
  int? _lastRssi;

  // 구독/타이머 핸들
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  Timer? _rssiTimer;
  bool _userWantsConnect = false;

  Duration _reconnectDelay = const Duration(seconds: 1);
  final Duration _maxReconnectDelay = const Duration(seconds: 20);

  bool _restoring = false; // 🟦 중복 호출 가드
  bool _didRestoreOnce = false; // 🟦 이번 런치에서 1회 보장

  // 수신 파서 버퍼 (문자열 프레이밍: \n 기준)
  final StringBuffer _rxBuf = StringBuffer();

  @override
  void initState() {
    super.initState();
    initForegroundTask();
    WidgetsBinding.instance.addObserver(this);
    _restoreConnectIntent();

    // 콜드스타트: 첫 빌드가 끝난 직후에 복원 시도 (알림 첫 탭 케이스 커버)      // 🟦
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreConnectIntent();
    }); // 🟦🟦

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final ignoring =
          await FlutterForegroundTask.isIgnoringBatteryOptimizations;
      if (!ignoring) {
        await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      }
    });
  }

  @override
  void dispose() {
    _stopScan();
    _cancelRssi();
    _notifySub?.cancel();
    _connSub?.cancel();
    _device?.disconnect();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// ---- 권한 / 어댑터 가드 ----
  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;

    // 1. 기본 권한 (permission_handler)
    final res = await [
      Permission.notification, // POST_NOTIFICATIONS
      Permission.bluetoothScan, // BLE 스캔
      Permission.bluetoothConnect, // BLE 연결
      // Android 11 이하 테스트 시 필요할 수 있음
      // Permission.locationWhenInUse,
    ].request();

    final granted = res.values.every((s) => s.isGranted);
    if (!granted) return false;

    // 2. 배터리 최적화 예외 (flutter_foreground_task)
    final isIgnoring =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!isIgnoring) {
      final requested =
          await FlutterForegroundTask.requestIgnoreBatteryOptimization();
      if (!requested) {
        debugPrint("⚠️ 배터리 최적화 예외 거부됨 → 서비스가 중단될 수 있음");
      }
    }

    return true;
  }

  Future<bool> _ensureBluetoothOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    if (state == BluetoothAdapterState.on) return true;
    setState(() => _status = '블루투스를 켜 주세요.');
    return false;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 🟦
    if (state == AppLifecycleState.resumed) {
      // 🟦
      _restoreConnectIntent(); // 🟦 포그라운드 복귀도 동일 처리
    }
  }

  // 앱 시작 시 복원
  Future<void> _restoreConnectIntent() async {
    // 🟦
    if (_restoring) return; // 🟦 중복 방지
    _restoring = true; // 🟦
    try {
      if (_didRestoreOnce && _connState == BluetoothConnectionState.connected) {
        return; // 🟦 이미 성공했으면 스킵
      }

      // 1) 권한/BT ON 확인
      if (!await _ensurePermissions()) {
        // 🟦
        setState(() => _status = '권한을 허용해 주세요.'); // 🟦
        return; // 🟦
      }
      if (!await _ensureBluetoothOn()) return; // 🟦

      // 2) 저장된 '연결 의지' 복원
      final prefs = await SharedPreferences.getInstance(); // 🟦
      final want = prefs.getBool('wantConnect') ?? false; // 🟦
      if (!want) return; // 🟦 사용자가 원치 않으면 스킵
      _userWantsConnect = true; // 🟦

      // 3) 이미 붙어있으면 종료
      if (_device != null && _connState == BluetoothConnectionState.connected) {
        _didRestoreOnce = true; // 🟦
        return; // 🟦
      }

      // 4) 최근 기기 ID가 있으면 직접 붙기 → 실패하면 스캔으로 폴백
      final lastId = prefs.getString('lastDeviceId'); // 🟦
      if (lastId != null && lastId.isNotEmpty) {
        // 🟦
        try {
          // flutter_blue_plus에서 지원하는 방식에 맞게 생성 (버전에 따라 다름)   // 🟦
          final dev = BluetoothDevice.fromId(lastId); // 🟦
          await dev.connect(
            autoConnect: false,
            timeout: const Duration(seconds: 8),
          ); // 🟦
          _device = dev; // 🟦
          setState(() => _connState = BluetoothConnectionState.connected); // 🟦
          await _afterConnected(); // 🟦 (MTU/우선순위/RSSI 시작)
          _didRestoreOnce = true; // 🟦
          return; // 🟦
        } catch (e) {
          debugPrint('직접 재연결 실패, 스캔으로 폴백: $e'); // 🟦
        }
      }

      // 5) 폴백: 기존 버튼 로직과 동일하게 스캔-연결
      await _scanAndConnect(); // 🟦
      _didRestoreOnce = true; // 🟦
    } finally {
      _restoring = false; // 🟦
    }
  }

  // ---- 스캔 시작/정지 ----
  Future<void> _scanAndConnect() async {
    if (!await _ensurePermissions()) {
      setState(() => _status = '권한을 허용해 주세요.');
      return;
    }
    if (!await _ensureBluetoothOn()) return;

    setState(() {
      _status = '스캔 중…';
      _lastRecv = '-';
      _lastRssi = null;
      _rxBuf.clear();
      _recvLog.clear();
    });

    _userWantsConnect = true; // 🟦 사용자가 연결을 원함 표시
    final prefs = await SharedPreferences.getInstance(); // 🟦
    await prefs.setBool('wantConnect', true);
    if (_device != null) {
      // 🟦
      await prefs.setString('lastDeviceId', _device!.remoteId.str); // 🟦
    }

    // 이전 스캔 정리
    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (_) {}

    // 스캔 시작
    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 8),
      androidScanMode: AndroidScanMode.lowLatency,
    );

    // 기존 리스너 제거 후 새로 구독
    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen(
      (results) async {
        for (final r in results) {
          final name = r.advertisementData.advName.isNotEmpty
              ? r.advertisementData.advName
              : r.device.platformName;

          final upper = name.toUpperCase();

          // 후보 판정
          final isEspByName = upper.contains('ESP32');
          final su = r.advertisementData.serviceUuids
              .map((g) => g.toString().toLowerCase())
              .toList();
          final isEspBySvc = su.contains(
            nusService.toString().toLowerCase(),
          ); // NUS 광고 포함 시

          if (isEspByName || isEspBySvc) {
            // ✅ 일단 스캔 중지(중복 연결 방지)
            try {
              if (FlutterBluePlus.isScanningNow) {
                await FlutterBluePlus.stopScan();
              }
            } catch (_) {}

            // ✅ 연결 시도
            final display = isEspByName
                ? name
                : (name.isEmpty ? 'ESP32(NUS)' : name);
            await _onDeviceFound(r.device, display);

            // ✅ 연결 성공이면 Foreground 시작 + (선택) deviceId 전달
            if (_device != null &&
                _connState == BluetoothConnectionState.connected) {
              _connSub?.cancel(); // 🟦 기존 구독 정리
              _connSub = _device!.connectionState.listen((s) {
                // 🟦 상태 감시
                setState(() => _connState = s); // 🟦
                if (s == BluetoothConnectionState.disconnected &&
                    _userWantsConnect) {
                  // 필요 시 여기서 재연결 시도 로직을 넣을 수 있습니다. // 🟦
                  // 예: _device!.connect(autoConnect: false).catchError((_) {});
                }
              });
              _startRssi(); // 🟦 (RSSI -> 서비스로 push는 이미 추가하신 부분이 실행됨)
              try {
                debugPrint('>>> Foreground startService 호출');
                final ok = await FlutterForegroundTask.startService(
                  notificationTitle: '앱 실행 중',
                  notificationText: 'ESP32와 블루투스 연결 유지 중...',
                  callback:
                      startCallback, // ★ top-level + @pragma('vm:entry-point')
                );
                debugPrint('>>> startService 반환: $ok');

                // 잠깐 대기 후 서비스 실행 여부 확인
                await Future.delayed(const Duration(milliseconds: 500));
                final running = await FlutterForegroundTask.isRunningService;
                debugPrint('>>> isRunningService: $running');

                // 알림 강제 갱신(보이면 정상)
                await FlutterForegroundTask.updateService(
                  notificationTitle: 'ESP32 연결 대기',
                  notificationText: 'Foreground 준비 완료',
                );
                debugPrint('>>> updateService 호출 완료');

                // ★ 실제로 서비스가 돌아간 뒤에 기기 정보 전달
                if (running) {
                  final id = _device!.remoteId.str;
                  final displayName = display; // 네가 위에서 만든 name/display
                  FlutterForegroundTask.sendDataToTask({
                    'cmd': 'bindDevice',
                    'deviceId': id,
                    'name': displayName,
                  });
                  debugPrint('>>> bindDevice 데이터 전송 완료');
                }
              } catch (e, st) {
                debugPrint('!!! startService 예외: $e\n$st');
              }
            }

            return; // 하나만 잡고 종료
          }
        }
      },
      onError: (e) {
        setState(() => _status = '스캔 오류: $e');
      },
    );
  }

  Future<void> _onDeviceFound(BluetoothDevice dev, String name) async {
    await _stopScan();
    _device = dev;

    setState(() => _status = '발견: $name, 연결 중…');

    // 연결 상태 스트림으로 UI 갱신
    _connSub?.cancel();
    _connSub = _device!.connectionState.listen((s) {
      setState(() => _connState = s);
    });

    try {
      await _device!.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 8),
      );
      await _device!.requestMtu(512); // MTU 업(가능한 기기에서)
      setState(() => _status = '연결 성공! 서비스 검색 중…');
      await _discoverAndSubscribe(); // 서비스/캐릭터리스틱 찾고 notify 구독
      _startRssi(); // RSSI 주기 측정(옵션)
    } catch (e) {
      setState(() => _status = '연결 실패: $e');
    }
  }

  Future<void> _stopScan() async {
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _scanSub?.cancel();
    _scanSub = null;
  }

  // ---- 서비스/캐릭터리스틱 찾기 + notify 구독 ----
  Future<void> _discoverAndSubscribe() async {
    if (_device == null) return;

    final services = await _device!.discoverServices();

    for (final s in services) {
      debugPrint('Service: ${s.uuid}');
      for (final c in s.characteristics) {
        debugPrint(
          '  Char: ${c.uuid} props: '
          'read=${c.properties.read} write=${c.properties.write} '
          'notify=${c.properties.notify} indicate=${c.properties.indicate}',
        );
      }
    }

    BluetoothCharacteristic? rx; // notify 받을 곳
    BluetoothCharacteristic? tx; // write  보낼 곳

    // 1) NUS 우선 탐색
    final nus = services.where((s) => s.uuid == nusService).toList();
    if (nus.isNotEmpty) {
      final svc = nus.first;
      try {
        rx = svc.characteristics.firstWhere(
          (c) =>
              c.uuid == nusRxChar &&
              (c.properties.notify || c.properties.indicate),
        );
      } catch (_) {}
      try {
        tx = svc.characteristics.firstWhere(
          (c) => c.uuid == nusTxChar && c.properties.write,
        );
      } catch (_) {}
    }

    // 2) 폴백: 모든 서비스에서 notify/indicate 가능한 후보 중 첫 번째
    //    단, 0x2A05(Service Changed)는 제외
    if (rx == null) {
      for (final s in services) {
        final cand = s.characteristics.where((c) {
          final notifyLike = c.properties.notify || c.properties.indicate;
          final is2a05 = c.uuid.str.toLowerCase().endsWith('2a05');
          return notifyLike && !is2a05;
        });
        if (cand.isNotEmpty) {
          rx = cand.first;
          // tx도 같이 찾을 수 있으면 잡아둠(옵션)
          final writables = s.characteristics.where((c) => c.properties.write);
          if (writables.isNotEmpty) tx = writables.first;
          break;
        }
      }
    }

    if (rx == null) {
      setState(() => _status = '알림 받을 캐릭터리스틱을 찾지 못했습니다.');
      return;
    }

    // 3) notify 구독 (1회만)
    _notifySub?.cancel();
    final ok = await rx.setNotifyValue(true);
    debugPrint(
      'SUBSCRIBE: ${rx.uuid} -> $ok  (notify=${rx.properties.notify}, indicate=${rx.properties.indicate})',
    );
    //

    _notifySub = rx.onValueReceived.listen((bytes) {
      // 디버그용 로그
      debugPrint(
        'RX HEX: ${bytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}',
      );
      try {
        debugPrint('RX TXT: ${utf8.decode(bytes)}');
      } catch (_) {}
      _onBytes(bytes);
    }, onError: (e) => debugPrint('RX error: $e'));

    setState(() => _status = '수신 대기 중 (notify 구독 완료)');

    // 4) (옵션) TX가 있으면 테스트로 한 줄 보내보기
    if (tx != null && tx.properties.write) {
      try {
        await tx.write(utf8.encode("hello\n"), withoutResponse: true);
        debugPrint('TX sent: hello');
      } catch (e) {
        debugPrint('TX write error: $e');
      }
    }
  }

  // ---- 수신 파서: \n 단위로 프레임 분리 → 숫자 토큰 추출 ----
  void _onBytes(List<int> data) {
    if (data.isEmpty) return;

    // 0) 항상 HEX/TXT 로그는 남겨 문제 파악
    debugPrint(
      'RX HEX: ${data.map((b) => b.toRadixString(16).padLeft(2, "0")).join(" ")}',
    );
    String txt = '';
    try {
      txt = utf8.decode(data);
    } catch (_) {}

    // 1) 케이스 A: 줄바꿈(\n \r\n 등) 포함 → 줄 단위 파싱
    if (txt.contains('\n') || txt.contains('\r')) {
      _rxBuf.write(txt);
      while (true) {
        final s = _rxBuf.toString();
        final idxN = s.indexOf('\n');
        final idxR = s.indexOf('\r');
        final cut = (idxN >= 0 && idxR >= 0)
            ? (idxN < idxR ? idxN : idxR)
            : (idxN >= 0 ? idxN : idxR);
        if (cut < 0) break;

        final line = s.substring(0, cut).trim();
        _rxBuf.clear();
        if (cut + 1 < s.length) _rxBuf.write(s.substring(cut + 1));
        _parseLine(line);
      }
      return;
    }

    // 2) 케이스 B: 줄바꿈은 없지만, 사람이 읽을 수 있는 숫자/공백들만 온 경우
    if (txt.isNotEmpty && RegExp(r'^[0-9\s,;]+$').hasMatch(txt)) {
      // 예: "1 2 3 4" (공백/콤마/세미콜론 분리)
      _parseLine(txt.trim());
      return;
    }

    // 3) 케이스 C: 바이트 단품 알림(프레이밍 없음)
    if (data.length == 1) {
      _pushValue(data.first);
      return;
    }

    // 4) 케이스 D: 그 외(바이너리/묶음 바이트) → 바이트별 숫자로 처리
    for (final b in data) {
      _pushValue(b);
    }
  }

  void _parseLine(String line) {
    if (line.isEmpty) return;
    // "1 2 3 4" / "1,2,3,4" / "1;2;3;4" 모두 처리
    final tokens = line.split(RegExp(r'[\s,;]+')).where((t) => t.isNotEmpty);
    for (final t in tokens) {
      final n = int.tryParse(t);
      if (n != null) _pushValue(n);
    }
  }

  // ---- 값 반영 + 로그 ----
  void _pushValue(int code) {
    final now = DateTime.now();
    final hhmmss =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';

    setState(() {
      _lastRecv = code.toString();
      _recvLog.insert(0, '$hhmmss → $code');
      if (_recvLog.length > 200) _recvLog.removeLast();
    });
  }

  // ---- RSSI 주기 측정(선택) ----
  void _startRssi() {
    _cancelRssi();
    _rssiTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final rssi = await _device?.readRssi();
        if (mounted) {
          setState(() => _lastRssi = rssi);
        }

        // 🟦 Foreground 서비스가 실행 중이면 RSSI 값을 전달
        if (rssi != null) {
          // 🟦
          final running = await FlutterForegroundTask.isRunningService; // 🟦
          if (running) {
            // 🟦
            FlutterForegroundTask.sendDataToTask({
              // 🟦
              'cmd': 'rssi', // 🟦
              'value': rssi, // 🟦
            }); // 🟦
          } // 🟦
        } // 🟦
      } catch (_) {}
    });
  }

  void _cancelRssi() {
    _rssiTimer?.cancel();
    _rssiTimer = null;
  }

  // ---- 수동 연결 해제 ----
  // ---- 수동 연결 해제 ----
  Future<void> _disconnect() async {
    // (안전) 스캔 중지
    _userWantsConnect = false; // 🟦 사용자가 더 이상 연결 원하지 않음 (자동 재연결 중단)
    final prefs = await SharedPreferences.getInstance(); // 🟦
    await prefs.setBool('wantConnect', false);

    try {
      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
      }
    } catch (_) {}

    // RSSI 타이머/스트림 종료
    _cancelRssi();

    // BLE 연결 해제
    try {
      await _device?.disconnect();
    } catch (_) {}

    // notify/connection 구독 종료
    await _notifySub?.cancel();
    await _connSub?.cancel();
    await _scanSub?.cancel();

    // ✅ Foreground 정지
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}

    setState(() {
      _device = null;
      _connState = BluetoothConnectionState.disconnected;
      _status = '연결 해제';
      _lastRecv = '-';
      _lastRssi = null;
      _rxBuf.clear();
      _recvLog.clear();
    });
  }

  // --- 연결 시도(재시도 포함) ---
  Future<void> _connectWithRetry() async {
    // 🟦
    if (_device == null) return; // 🟦
    while (_userWantsConnect &&
        _connState != BluetoothConnectionState.connected) {
      try {
        await _device!.connect(
          // 🟦
          autoConnect: false, // 🟦 (직접 재시도 전략과 궁합 좋음)
          timeout: const Duration(seconds: 8), // 🟦
        );
        // 연결 성공 → 품질 힌트 & MTU 업, RSSI 루프 등
        await _afterConnected(); // 🟦
        _reconnectDelay = const Duration(seconds: 1); // 🟦 (백오프 초기화)
        return; // 🟦
      } catch (_) {
        // 실패 → 백오프 후 재시도
        await Future.delayed(_reconnectDelay); // 🟦
        final next = _reconnectDelay.inSeconds * 2; // 🟦
        _reconnectDelay = Duration(
          seconds: next.clamp(1, _maxReconnectDelay.inSeconds),
        ); // 🟦
      }
    }
  }

  // --- 연결 후 품질 힌트/감시 ---
  Future<void> _afterConnected() async {
    // 🟦
    try {
      await _device?.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high, // 🟦 변경된 API
      ); // 🟦 가용 시
      await _device?.requestMtu(185); // 🟦 가용 시(ESP32 대응)
      _startRssi(); // (서비스로 RSSI push 포함)
    } catch (_) {}

    // 연결 성공 후에만 저장
    if (_device != null && _connState == BluetoothConnectionState.connected) {
      // 🟦
      final prefs = await SharedPreferences.getInstance(); // 🟦
      await prefs.setString('lastDeviceId', _device!.remoteId.str); // 🟦
      await prefs.setBool('wantConnect', true); // 🟦
    }

    _watchConnection(); // 🟦 상태 감시 시작
    _startRssi(); // 🟦 주기적 RSSI(keep-alive 효과)
    // ★ 여기서 서비스에 bindDevice 알림을 보내고 싶다면 보냅니다.
  }

  // --- 상태 스트림 구독 ---
  void _watchConnection() {
    // 🟦
    _connSub?.cancel(); // 🟦
    _connSub = _device!.connectionState.listen((s) async {
      // 🟦
      setState(() => _connState = s); // 🟦

      if (s == BluetoothConnectionState.disconnected) {
        // 🟦
        // 주기 작업 정리
        _cancelRssi(); // 🟦
        if (_userWantsConnect) {
          // 🟦 수동 해제가 아니면 자동 재연결
          await _connectWithRetry(); // 🟦
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final name = _device?.platformName ?? '-';
    final id = _device?.remoteId.str ?? '-';

    return Scaffold(
      appBar: AppBar(title: const Text('ESP32-S3 연결 + 수신')),
      body: Padding(
        padding: EdgeInsets.all(16.w),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                ElevatedButton(
                  onPressed: _scanAndConnect,
                  child: const Text('연결 시도'),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _device == null ? null : _disconnect,
                  child: const Text('연결 해제'),
                ),
              ],
            ),
            SizedBox(height: 12.h),
            Text('상태: $_status'),
            SizedBox(height: 8.h),
            Text('기기 이름: $name'),
            Text('기기 ID: $id'),
            Text('ConnectionState: $_connState'),
            SizedBox(height: 8.h),
            Text('최근 수신 값: $_lastRecv'),
            Text('RSSI: ${_lastRssi?.toString() ?? '-'} dBm'),
            SizedBox(height: 12.h),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '최근 수신 값: $_lastRecv',
                  style: TextStyle(
                    fontSize: 18.sp,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _recvLog.clear();
                    _lastRecv = '-';
                  }),
                  child: const Text('로그 지우기'),
                ),
              ],
            ),
            SizedBox(height: 8.h),
            // Padding(
            //   padding: EdgeInsets.symmetric(horizontal: 8.w),
            //   child: Row(
            //     mainAxisAlignment: MainAxisAlignment.spaceBetween,
            //     children: [
            //       GestureDetector(
            //         onTap: () {
            //           startService();
            //         },
            //         child: Container(
            //           width: 150.w,
            //           height: 30.h,
            //           alignment: Alignment.center,
            //           decoration: BoxDecoration(
            //             color: Color(0xFFFFFFFF),
            //             border: Border.all(color: Colors.black),
            //             borderRadius: BorderRadius.circular(10.r),
            //           ),
            //           child: const Text("백그라운드 서비스 시작"),
            //         ),
            //       ),
            //       GestureDetector(
            //         onTap: () {
            //           stopService();
            //         },
            //         child: Container(
            //           width: 150.w,
            //           height: 30.h,
            //           alignment: Alignment.center,
            //           decoration: BoxDecoration(
            //             color: Color(0xFFFFFFFF),
            //             border: Border.all(color: Colors.black),
            //             borderRadius: BorderRadius.circular(10.r),
            //           ),
            //           child: const Text("백그라운드 서비스 중지"),
            //         ),
            //       ),
            //     ],
            //   ),
            // ),
            SizedBox(height: 8.h),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.black12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _recvLog.isEmpty
                    ? const Center(child: Text('아직 수신된 데이터가 없습니다.'))
                    : ListView.builder(
                        itemCount: _recvLog.length,
                        itemBuilder: (context, i) => ListTile(
                          dense: true,
                          visualDensity: const VisualDensity(vertical: -2),
                          title: Text(_recvLog[i]),
                        ),
                      ),
              ),
            ),
            SizedBox(height: 12.h),
            if (_device != null &&
                _connState == BluetoothConnectionState.connected)
              RssiGuard(device: _device!),
            const Text(
              '메모: ESP32가 "1 2 3 4\\n"처럼 문자열을 보내면, 위 파서가 줄 단위로 나눠 숫자 토큰을 모두 처리합니다.',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ],
        ),
      ),
    );
  }
}

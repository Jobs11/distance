import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:distance/screens/scan_page.dart';
import 'package:distance/widgets/foreground.dart';
import 'package:distance/widgets/rssiguard.dart';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';
import 'package:audioplayers/audioplayers.dart';

// ── 색상 토큰 ─────────────────────────────────────────────────
const kBg = Color(0xFFFAF7F2);
const kCard = Color(0xFFFFFFFF);
const kBeige = Color(0xFFE8DDD0);
const kBeigeDeep = Color(0xFFD4C4B0);
const kBrown = Color(0xFF7B6B5A);
const kBrownDeep = Color(0xFF3D3530);
const kGrey = Color(0xFFAA9E94);
const kGreen = Color(0xFF6BAF92);
const kRed = Color(0xFFD97B6C);
const kOrange = Color(0xFFE8A97A);

class Mainhome extends StatefulWidget {
  const Mainhome({super.key});
  @override
  State<Mainhome> createState() => _MainhomeState();
}

class _MainhomeState extends State<Mainhome>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final Guid nusService = Guid("0000dfb0-0000-1000-8000-00805f9b34fb");
  final Guid nusRxChar = Guid(
    "0000dfb1-0000-1000-8000-00805f9b34fb",
  ); // notify (ACK)
  final Guid nusTxChar = Guid("0000dfb1-0000-1000-8000-00805f9b34fb"); // write
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar;
  BluetoothConnectionState _connState = BluetoothConnectionState.disconnected;

  String _status = '기기를 연결해주세요';
  String _lastRecv = '-';
  final List<String> _recvLog = [];
  int? _lastRssi;
  int? _batteryMv;

  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  Timer? _rssiTimer;
  bool _userWantsConnect = false;

  Duration _reconnectDelay = const Duration(seconds: 1);
  final Duration _maxReconnectDelay = const Duration(seconds: 20);

  bool _restoring = false;
  bool _didRestoreOnce = false;
  bool _showSettings = false;

  final StringBuffer _rxBuf = StringBuffer();

  // 거리 설정
  static const double _txPower = -56.0; // 1m 기준 RSSI
  static const double _pathN = 2.8; // 환경 계수 (실내 기준)
  // 가까움(5m) / 멀어짐(10m) 선택
  bool _isNearMode = true; // true=가까움(5m), false=멀어짐(10m)
  double get _alertDist => _isNearMode ? 5.0 : 10.0;

  // 진동 감지
  int _consecutiveOver = 0;
  static const int _triggerConsec = 3;
  static const int _cooldownMs = 5000;
  DateTime _lastVibe = DateTime.fromMillisecondsSinceEpoch(0);

  // 알람 상태
  bool _alarmActive = false;
  Timer? _alarmTimer;

  // 알람 모드 (0=진동, 1=소리, 2=진동&소리)
  int _alarmMode = 0;

  // 펄스 애니메이션
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    initForegroundTask();
    WidgetsBinding.instance.addObserver(this);

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(
      begin: 0.95,
      end: 1.05,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _loadSettings();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreConnectIntent();
      _requestBatteryOpt();
    });
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _alarmTimer?.cancel();
    _audioPlayer.dispose();
    Vibration.cancel();
    _cancelRssi();
    _notifySub?.cancel();
    _connSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _restoreConnectIntent();
  }

  Future<void> _requestBatteryOpt() async {
    final ignoring = await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!ignoring) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  Future<void> _loadSettings() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _isNearMode = p.getBool('is_near_mode') ?? true;
      _alarmMode = p.getInt('alarm_mode') ?? 0;
    });
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool('is_near_mode', _isNearMode);
    await p.setInt('alarm_mode', _alarmMode);
  }

  // 거리 → RSSI 변환
  double _distToRssi(double dist) {
    if (dist <= 0) return _txPower;
    return _txPower - 10.0 * _pathN * (log(dist) / log(10));
  }

  // RSSI → 거리 변환
  double _rssiToDist(int rssi) {
    return pow(10.0, (_txPower - rssi) / (10.0 * _pathN)).toDouble();
  }

  // ── 상태 판단 ─────────────────────────────────────────────
  bool get _isNear {
    if (!_connected || _lastRssi == null) return true;
    return _rssiToDist(_lastRssi!) < _alertDist;
  }

  // ── 권한 ──────────────────────────────────────────────────
  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final res = await [
      Permission.notification,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    final granted = res.values.every((s) => s.isGranted);
    if (!granted) return false;
    final isIgnoring =
        await FlutterForegroundTask.isIgnoringBatteryOptimizations;
    if (!isIgnoring) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
    return true;
  }

  Future<bool> _ensureBluetoothOn() async {
    final state = await FlutterBluePlus.adapterState.first;
    if (state == BluetoothAdapterState.on) return true;
    setState(() => _status = '블루투스를 켜 주세요.');
    return false;
  }

  // ── 자동 재연결 ───────────────────────────────────────────
  Future<void> _restoreConnectIntent() async {
    if (_restoring) return;
    if (_connState == BluetoothConnectionState.connected) return;
    _restoring = true;

    try {
      if (!await _ensurePermissions()) return;
      if (!await _ensureBluetoothOn()) return;

      final prefs = await SharedPreferences.getInstance();
      final want = prefs.getBool('wantConnect') ?? false;
      final lastId = prefs.getString('lastDeviceId');
      final lastName = prefs.getString('lastDeviceName') ?? '';

      if (!want || lastId == null || lastId.isEmpty) return;

      _userWantsConnect = true;
      setState(() => _status = '$lastName 재연결 중...');

      try {
        final dev = BluetoothDevice.fromId(lastId);

        // 이미 연결된 상태면 바로 구독만
        final state = await dev.connectionState.first;
        if (state == BluetoothConnectionState.connected) {
          _device = dev;
          setState(() {
            _connState = BluetoothConnectionState.connected;
            _status = '$lastName 연결됨';
          });
          await _discoverAndSubscribe();
          _startRssi();
          _watchConnection();
          return;
        }

        // 스캔으로 기기 찾아서 연결 (advertising interval 대응)
        setState(() => _status = '$lastName 스캔 중...');

        bool found = false;
        await FlutterBluePlus.startScan(
          timeout: const Duration(seconds: 30),
          androidScanMode: AndroidScanMode.lowLatency,
        );

        await for (final results in FlutterBluePlus.scanResults) {
          for (final r in results) {
            if (r.device.remoteId.str == lastId) {
              found = true;
              await FlutterBluePlus.stopScan();
              await _onDeviceFound(r.device, lastName);

              // 포그라운드 서비스 시작
              try {
                await FlutterForegroundTask.startService(
                  notificationTitle: 'Smartphone Loss Device',
                  notificationText: '$lastName 와 연결된 상태',
                  callback: startCallback,
                );
              } catch (_) {}
              return;
            }
          }
          if (found) break;
        }

        if (!found) {
          setState(() => _status = '기기를 찾지 못했습니다. 수동으로 연결해주세요.');
        }
      } catch (e) {
        debugPrint('자동 재연결 실패: $e');
        setState(() => _status = '기기를 연결해주세요');
      }
    } finally {
      _restoring = false;
    }
  }

  // ── 스캔 → 연결 ───────────────────────────────────────────
  Future<void> _scanAndConnect() async {
    if (!await _ensurePermissions()) return;
    if (!await _ensureBluetoothOn()) return;

    final result = await Navigator.of(
      context,
    ).push<SelectedDevice>(MaterialPageRoute(builder: (_) => const ScanPage()));
    if (result == null) return;

    final name = result.displayName;
    setState(() {
      _status = '연결 중…';
      _lastRecv = '-';
      _lastRssi = null;
      _batteryMv = null;
      _rxBuf.clear();
    });

    _userWantsConnect = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wantConnect', true);

    await _onDeviceFound(result.device, name);

    if (_device != null && _connState == BluetoothConnectionState.connected) {
      try {
        await FlutterForegroundTask.startService(
          notificationTitle: '$name 연결됨',
          notificationText: '분실 방지 모니터링 중...',
          callback: startCallback,
        );
        await Future.delayed(const Duration(milliseconds: 500));
        final running = await FlutterForegroundTask.isRunningService;
        if (running) {
          FlutterForegroundTask.sendDataToTask({
            'cmd': 'bindDevice',
            'deviceId': _device!.remoteId.str,
            'name': name,
          });
        }
      } catch (e) {
        debugPrint('FG 서비스 오류: $e');
      }
    }
  }

  Future<void> _onDeviceFound(BluetoothDevice dev, String name) async {
    _device = dev;
    setState(() => _status = '$name 연결 중…');

    _connSub?.cancel();
    _connSub = _device!.connectionState.listen((s) {
      setState(() => _connState = s);
    });

    try {
      await _device!.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 8),
      );

      // MTU 요청 실패해도 계속 진행
      try {
        await _device!.requestMtu(512);
      } catch (e) {
        debugPrint('MTU 요청 실패 (무시): $e');
      }

      setState(() => _status = '$name 연결됨');
      await _discoverAndSubscribe();
      _startRssi();
      _watchConnection();

      // 연결 성공 시 저장
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lastDeviceId', dev.remoteId.str);
      await prefs.setString('lastDeviceName', name);
      await prefs.setBool('wantConnect', true);
    } catch (e) {
      setState(() => _status = '연결 실패: $e');
      debugPrint('연결 실패: $e');
    }
  }

  Future<void> _discoverAndSubscribe() async {
    if (_device == null) return;
    final services = await _device!.discoverServices();

    BluetoothCharacteristic? rx;
    BluetoothCharacteristic? tx;

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
          (c) =>
              c.uuid == nusTxChar &&
              (c.properties.write || c.properties.writeWithoutResponse),
        );
      } catch (_) {}
    }

    if (rx == null) {
      for (final s in services) {
        final cand = s.characteristics.where((c) {
          final notifyLike = c.properties.notify || c.properties.indicate;
          final is2a05 = c.uuid.str.toLowerCase().endsWith('2a05');
          return notifyLike && !is2a05;
        });
        if (cand.isNotEmpty) {
          rx = cand.first;
          final writables = s.characteristics.where(
            (c) => c.properties.write || c.properties.writeWithoutResponse,
          );
          if (writables.isNotEmpty) tx = writables.first;
          break;
        }
      }
    }

    if (rx == null) {
      setState(() => _status = '서비스를 찾지 못했습니다.');
      return;
    }

    _txChar = tx;
    _notifySub?.cancel();
    await rx.setNotifyValue(true);
    _notifySub = rx.onValueReceived.listen(
      (bytes) => _onBytes(bytes),
      onError: (e) => debugPrint('RX error: $e'),
    );

    debugPrint('[BLE] RX notify 구독 완료: ${rx.uuid}');
  }

  // ── 보드로 값 전송 ────────────────────────────────────────
  Future<void> _sendValue(String val) async {
    if (_txChar == null) return;
    try {
      final bytes = utf8.encode('$val\n');
      final canWrite = _txChar!.properties.writeWithoutResponse;
      await _txChar!.write(bytes, withoutResponse: canWrite);
      debugPrint('[TX] 전송: $val');
    } catch (e) {
      debugPrint('[TX] 전송 실패: $e');
    }
  }

  void _onBytes(List<int> data) {
    if (data.isEmpty) return;

    // null 바이트 및 쓰레기 값 제거 (32 미만이고 \r\n 아닌 것)
    final clean = data.where((b) => b >= 32 || b == 13 || b == 10).toList();

    debugPrint('[RX RAW] $data');

    String txt = '';
    try {
      txt = utf8.decode(clean);
    } catch (_) {
      txt = String.fromCharCodes(clean);
    }

    debugPrint('[RX TXT] $txt');

    _rxBuf.write(txt.replaceAll('\r', '\n'));

    while (true) {
      final s = _rxBuf.toString();
      final idx = s.indexOf('\n');
      if (idx < 0) return;

      final line = s.substring(0, idx).trim();
      _rxBuf.clear();
      if (idx + 1 < s.length) _rxBuf.write(s.substring(idx + 1));
      if (line.isNotEmpty) _pushValue(line);
    }
  }

  void _pushValue(String val) {
    debugPrint('[RX LINE] $val');

    int? parsedBatteryMv;

    if (val.startsWith('BAT:')) {
      parsedBatteryMv = int.tryParse(val.substring(4).trim());
      debugPrint('[BAT] ${parsedBatteryMv ?? '-'} mV');
    } else if (val.startsWith('ACK:')) {
      debugPrint('[ACK] $val');
    }

    if (mounted) {
      setState(() {
        if (parsedBatteryMv != null) {
          _batteryMv = parsedBatteryMv;
        }

        _lastRecv = val;
        _recvLog.insert(0, val);

        if (_recvLog.length > 100) {
          _recvLog.removeLast();
        }
      });
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: kBrownDeep,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _startRssi() {
    _cancelRssi();
    _rssiTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      try {
        final rssi = await _device?.readRssi();
        if (rssi == null) return;

        final dist = _rssiToDist(rssi);
        final isOver = dist >= _alertDist; // 설정 거리 이상 멀어짐

        if (mounted) setState(() => _lastRssi = rssi);

        // 상태에 따라 0 또는 1 계속 전송
        await _sendValue(isOver ? '1' : '0');

        // 멀어진 경우 진동 (연속 3회)
        if (isOver) {
          _consecutiveOver++;
        } else {
          _consecutiveOver = 0;
        }

        if (_consecutiveOver >= _triggerConsec) {
          await _maybeVibrate();
          _consecutiveOver = 0;
        }

        final running = await FlutterForegroundTask.isRunningService;
        if (running) {
          FlutterForegroundTask.sendDataToTask({'cmd': 'rssi', 'value': rssi});
        }
      } catch (_) {}
    });
  }

  final AudioPlayer _audioPlayer = AudioPlayer();

  Future<void> _maybeVibrate() async {
    if (_alarmActive) return;
    _startAlarm();
  }

  void _startAlarm() {
    setState(() => _alarmActive = true);
    _alarmTimer?.cancel();
    _alarmTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!_alarmActive) {
        _alarmTimer?.cancel();
        return;
      }
      // 진동
      if (_alarmMode == 0 || _alarmMode == 2) {
        if (await Vibration.hasVibrator() ?? false) {
          await Vibration.vibrate(pattern: [0, 300, 100, 300]);
        }
      }
      // 소리
      if (_alarmMode == 1 || _alarmMode == 2) {
        await _audioPlayer.play(AssetSource('sounds/alarm1.wav'));
      }
    });
    // 첫 알람 즉시 실행
    _triggerAlarm();
  }

  Future<void> _triggerAlarm() async {
    if (_alarmMode == 0 || _alarmMode == 2) {
      if (await Vibration.hasVibrator() ?? false) {
        await Vibration.vibrate(pattern: [0, 300, 100, 300]);
      }
    }
    if (_alarmMode == 1 || _alarmMode == 2) {
      await _audioPlayer.play(AssetSource('sounds/alarm1.wav'));
    }
  }

  void _stopAlarm() {
    _alarmTimer?.cancel();
    _alarmTimer = null;
    Vibration.cancel();
    _audioPlayer.stop();
    setState(() => _alarmActive = false);
  }

  void _cancelRssi() {
    _rssiTimer?.cancel();
    _rssiTimer = null;
  }

  Future<void> _disconnect() async {
    _userWantsConnect = false;
    final prefs = await SharedPreferences.getInstance();
    // 기기 정보 + wantConnect 유지 → 앱 재시작 시 자동 재연결
    await prefs.setBool('wantConnect', true);

    _cancelRssi();
    try {
      await _device?.disconnect();
    } catch (_) {}
    await _notifySub?.cancel();
    await _connSub?.cancel();
    try {
      await FlutterForegroundTask.stopService();
    } catch (_) {}

    setState(() {
      _device = null;
      _txChar = null;
      _connState = BluetoothConnectionState.disconnected;
      _status = '기기를 연결해주세요';
      _lastRecv = '-';
      _lastRssi = null;
      _batteryMv = null;
      _rxBuf.clear();
    });
  }

  Future<void> _connectWithRetry() async {
    if (_device == null) return;
    while (_userWantsConnect &&
        _connState != BluetoothConnectionState.connected) {
      try {
        await _device!.connect(
          autoConnect: false,
          timeout: const Duration(seconds: 8),
        );
        await _afterConnected();
        _reconnectDelay = const Duration(seconds: 1);
        return;
      } catch (_) {
        await Future.delayed(_reconnectDelay);
        final next = _reconnectDelay.inSeconds * 2;
        _reconnectDelay = Duration(
          seconds: next.clamp(1, _maxReconnectDelay.inSeconds),
        );
      }
    }
  }

  Future<void> _afterConnected() async {
    try {
      await _device?.requestConnectionPriority(
        connectionPriorityRequest: ConnectionPriority.high,
      );
      await _device?.requestMtu(185);
    } catch (_) {}
    if (_device != null && _connState == BluetoothConnectionState.connected) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('lastDeviceId', _device!.remoteId.str);
      await prefs.setBool('wantConnect', true);
    }
    _watchConnection();
    _startRssi();
  }

  void _watchConnection() {
    _connSub?.cancel();
    _connSub = _device!.connectionState.listen((s) async {
      setState(() => _connState = s);
      if (s == BluetoothConnectionState.disconnected) {
        _cancelRssi();
        if (_userWantsConnect) await _connectWithRetry();
      }
    });
  }

  // ── 상태 관련 헬퍼 ────────────────────────────────────────
  bool get _connected => _connState == BluetoothConnectionState.connected;

  Color get _zoneColor {
    if (!_connected || _lastRssi == null) return kGrey;
    return _isNear ? kGreen : kRed;
  }

  String get _zoneLabel {
    if (!_connected) return '연결 안됨';
    if (_lastRssi == null) return '측정 중...';
    final dist = _rssiToDist(_lastRssi!);
    return _isNear
        ? '범위 안 (${dist.toStringAsFixed(1)}m)'
        : '범위 초과 (${dist.toStringAsFixed(1)}m)';
  }

  String get _deviceName {
    if (_device == null) return '-';
    return _device!.platformName.isNotEmpty
        ? _device!.platformName
        : _device!.remoteId.str;
  }

  // ── UI ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) async {
        if (!didPop) {
          // 뒤로가기 = 포그라운드로 전환, 연결 의지 유지
          if (_connected) {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool('wantConnect', true);
          }
          FlutterForegroundTask.minimizeApp();
        }
      },
      child: Scaffold(
        backgroundColor: kBg,
        body: SafeArea(
          bottom: false,
          child: SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20.w,
              16.h,
              20.w,
              MediaQuery.of(context).padding.bottom + 16.h,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                SizedBox(height: 24.h),
                // 알람 활성화 시 경고 배너
                if (_alarmActive) _buildAlarmBanner(),
                _buildDistanceGauge(),
                SizedBox(height: 20.h),
                _buildStatusCard(),
                SizedBox(height: 16.h),
                _buildSettingsCard(),
                SizedBox(height: 16.h),
                _buildRecvCard(),
                SizedBox(height: 24.h),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── 헤더 ──────────────────────────────────────────────────
  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Smartphone',
              style: TextStyle(
                fontSize: 11.sp,
                color: kGrey,
                letterSpacing: 1.5,
                fontWeight: FontWeight.w500,
              ),
            ),
            Text(
              'Loss Device',
              style: TextStyle(
                fontSize: 18.sp,
                color: kBrownDeep,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        Row(
          children: [
            // 연결 상태 뱃지
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: _connected ? kGreen.withOpacity(0.12) : kBeige,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: _connected ? kGreen : kGrey,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _connected ? '연결됨' : '미연결',
                    style: TextStyle(
                      fontSize: 12.sp,
                      color: _connected ? kGreen : kGrey,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // 알람 설정 버튼
            GestureDetector(
              onTap: _showAlarmSettings,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: kBeige,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.notifications_outlined,
                  size: 20,
                  color: kBrown,
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 연결/해제 버튼
            GestureDetector(
              onTap: _connected ? _disconnect : _scanAndConnect,
              child: Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _connected ? kRed.withOpacity(0.1) : kBeige,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  _connected
                      ? Icons.bluetooth_disabled
                      : Icons.bluetooth_searching,
                  size: 20,
                  color: _connected ? kRed : kBrown,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── 원형 거리 게이지 ──────────────────────────────────────
  Widget _buildDistanceGauge() {
    return Center(
      child: ScaleTransition(
        scale: _connected ? _pulseAnim : const AlwaysStoppedAnimation(1.0),
        child: SizedBox(
          width: 220.w,
          height: 220.w,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // 배경 원
              Container(
                width: 220.w,
                height: 220.w,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kBeige.withOpacity(0.5),
                ),
              ),
              // 상태 원
              Container(
                width: 200.w,
                height: 200.w,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _zoneColor, width: 10),
                ),
              ),
              // 내부 콘텐츠
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isNear ? Icons.person_pin_circle : Icons.person_off,
                    size: 36,
                    color: _zoneColor,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _connected && _lastRssi != null ? '${_lastRssi} dBm' : '--',
                    style: TextStyle(
                      fontSize: 36.sp,
                      fontWeight: FontWeight.w700,
                      color: kBrownDeep,
                    ),
                  ),
                  Text(
                    _zoneLabel,
                    style: TextStyle(
                      fontSize: 15.sp,
                      color: _zoneColor,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 상태 카드 ─────────────────────────────────────────────
  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: kBeige,
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.bluetooth, color: kBrown, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _deviceName,
                  style: TextStyle(
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w700,
                    color: kBrownDeep,
                  ),
                ),
                Text(
                  _status,
                  style: TextStyle(fontSize: 12.sp, color: kGrey),
                ),
              ],
            ),
          ),
          if (!_connected)
            GestureDetector(
              onTap: _scanAndConnect,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: kBrown,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '연결',
                  style: TextStyle(
                    fontSize: 13.sp,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── 설정 카드 ─────────────────────────────────────────────
  Widget _buildSettingsCard() {
    return Container(
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // 헤더
          GestureDetector(
            onTap: () => setState(() => _showSettings = !_showSettings),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.tune, color: kBrown, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    '거리 설정',
                    style: TextStyle(
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w700,
                      color: kBrownDeep,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _isNearMode ? '가까움 감지' : '멀어짐 감지',
                    style: TextStyle(fontSize: 12.sp, color: kGrey),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _showSettings ? Icons.expand_less : Icons.expand_more,
                    color: kGrey,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          // 설정 패널
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(color: kBeige),
                  const SizedBox(height: 12),
                  const Text(
                    '감지 범위',
                    style: TextStyle(fontSize: 13, color: kGrey),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setState(() => _isNearMode = true);
                            _saveSettings();
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: _isNearMode ? kGreen : kBg,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: _isNearMode ? kGreen : kBeige,
                                width: 1.5,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '가까운 범위',
                                style: TextStyle(
                                  fontSize: 14.sp,
                                  fontWeight: FontWeight.w700,
                                  color: _isNearMode ? Colors.white : kGrey,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: GestureDetector(
                          onTap: () {
                            setState(() => _isNearMode = false);
                            _saveSettings();
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: !_isNearMode ? kRed : kBg,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: !_isNearMode ? kRed : kBeige,
                                width: 1.5,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '넓은 범위',
                                style: TextStyle(
                                  fontSize: 14.sp,
                                  fontWeight: FontWeight.w700,
                                  color: !_isNearMode ? Colors.white : kGrey,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            crossFadeState: _showSettings
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 250),
          ),
        ],
      ),
    );
  }

  void _showAlarmSettings() {
    showModalBottomSheet(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            MediaQuery.of(ctx).padding.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 핸들
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: kBeige,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                '알람 설정',
                style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: kBrownDeep,
                ),
              ),
              const SizedBox(height: 20),
              // 알람 방식
              const Text('알람 방식', style: TextStyle(fontSize: 13, color: kGrey)),
              const SizedBox(height: 10),
              Row(
                children: [
                  _alarmModeBtn2(0, Icons.vibration, '진동', setModalState),
                  const SizedBox(width: 8),
                  _alarmModeBtn2(
                    1,
                    Icons.volume_up_rounded,
                    '소리',
                    setModalState,
                  ),
                  const SizedBox(width: 8),
                  _alarmModeBtn2(
                    2,
                    Icons.notifications_active_rounded,
                    '진동+소리',
                    setModalState,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _alarmModeBtn2(
    int mode,
    IconData icon,
    String label,
    StateSetter setModalState,
  ) {
    final selected = _alarmMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _alarmMode = mode);
          setModalState(() {});
          _saveSettings();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: selected ? kBrown : kBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? kBrown : kBeige, width: 1.5),
          ),
          child: Column(
            children: [
              Icon(icon, size: 22, color: selected ? Colors.white : kGrey),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : kGrey,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _alarmModeBtn(int mode, IconData icon, String label) {
    final selected = _alarmMode == mode;
    return Expanded(
      child: GestureDetector(
        onTap: () {
          setState(() => _alarmMode = mode);
          _saveSettings();
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            color: selected ? kBrown : kBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: selected ? kBrown : kBeige, width: 1.5),
          ),
          child: Column(
            children: [
              Icon(icon, size: 20, color: selected ? Colors.white : kGrey),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.sp,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : kGrey,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 알람 배너 ─────────────────────────────────────────────
  Widget _buildAlarmBanner() {
    return GestureDetector(
      onTap: _stopAlarm,
      child: Container(
        width: double.infinity,
        margin: EdgeInsets.only(bottom: 16.h),
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 20),
        decoration: BoxDecoration(
          color: kRed,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: kRed.withOpacity(0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '⚠️ 범위 초과!',
                  style: TextStyle(
                    fontSize: 16.sp,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                Text(
                  '탭하여 알람 끄기',
                  style: TextStyle(fontSize: 12.sp, color: Colors.white70),
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '알람 끄기',
                style: TextStyle(
                  fontSize: 13.sp,
                  fontWeight: FontWeight.w700,
                  color: kRed,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecvCard() {
    return Container(
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // 헤더
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                const Icon(Icons.inbox_rounded, color: kBrown, size: 20),
                const SizedBox(width: 10),
                Text(
                  '수신 데이터',
                  style: TextStyle(
                    fontSize: 14.sp,
                    fontWeight: FontWeight.w700,
                    color: kBrownDeep,
                  ),
                ),
                const Spacer(),
                Text(
                  _batteryMv == null ? '배터리: -' : '배터리: ${_batteryMv}mV',
                  style: TextStyle(fontSize: 12.sp, color: kGrey),
                ),
                const SizedBox(width: 8),
                if (_lastRecv != '-')
                  Flexible(
                    child: Text(
                      '최근: $_lastRecv',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.sp, color: kGrey),
                    ),
                  ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => setState(() => _recvLog.clear()),
                  child: const Icon(
                    Icons.delete_outline,
                    color: kGrey,
                    size: 18,
                  ),
                ),
              ],
            ),
          ),
          // 로그
          Container(
            height: 120.h,
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            decoration: BoxDecoration(
              color: kBg,
              borderRadius: BorderRadius.circular(10),
            ),
            child: _recvLog.isEmpty
                ? Center(
                    child: Text(
                      '수신된 데이터가 없습니다.',
                      style: TextStyle(fontSize: 12.sp, color: kGrey),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    itemCount: _recvLog.length,
                    itemBuilder: (_, i) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        _recvLog[i],
                        style: TextStyle(
                          fontSize: 13.sp,
                          color: kBrownDeep,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

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
  final Guid nusService = Guid("6e400001-b5a3-f393-e0a9-e50e24dcca9e");
  final Guid nusRxChar = Guid("6e400003-b5a3-f393-e0a9-e50e24dcca9e");
  final Guid nusTxChar = Guid("6e400002-b5a3-f393-e0a9-e50e24dcca9e");

  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar;
  BluetoothConnectionState _connState = BluetoothConnectionState.disconnected;

  String _status = '기기를 연결해주세요';
  String _lastRecv = '-';
  final List<_LogEntry> _log = [];
  int? _lastRssi;
  double _estimatedDist = 0.0;

  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  Timer? _rssiTimer;
  bool _userWantsConnect = false;

  Duration _reconnectDelay = const Duration(seconds: 1);
  final Duration _maxReconnectDelay = const Duration(seconds: 20);

  bool _restoring = false;
  bool _didRestoreOnce = false;
  bool _showLog = false;
  bool _showSettings = false;

  final StringBuffer _rxBuf = StringBuffer();
  final TextEditingController _txController = TextEditingController();
  bool _isSending = false;

  // 거리 설정값
  double _txPower = -59.0;
  double _pathN = 2.0;
  double _maxDist = 3.0;

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
    _txController.dispose();
    _cancelRssi();
    _notifySub?.cancel();
    _connSub?.cancel();
    _device?.disconnect();
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
      _txPower = p.getDouble('rssi_txPower') ?? -59.0;
      _pathN = p.getDouble('rssi_pathN') ?? 2.0;
      _maxDist = p.getDouble('rssi_maxDist') ?? 3.0;
    });
  }

  Future<void> _saveSettings() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble('rssi_txPower', _txPower);
    await p.setDouble('rssi_pathN', _pathN);
    await p.setDouble('rssi_maxDist', _maxDist);
  }

  // ── 거리 계산 ─────────────────────────────────────────────
  double _calcDist(int rssi) {
    if (rssi == 0) return 0.0;
    return pow(10.0, (_txPower - rssi) / (10.0 * _pathN)).toDouble();
  }

  double _distToRssi(double dist) {
    if (dist <= 0) return _txPower;
    return _txPower - 10.0 * _pathN * log(dist) / ln10;
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
    _restoring = true;
    try {
      if (_connState == BluetoothConnectionState.connected) return;
      if (!await _ensurePermissions()) return;
      if (!await _ensureBluetoothOn()) return;

      final prefs = await SharedPreferences.getInstance();
      final want = prefs.getBool('wantConnect') ?? false;
      final lastId = prefs.getString('lastDeviceId');

      if (!want || lastId == null || lastId.isEmpty) return;

      _userWantsConnect = true;
      setState(() => _status = '마지막 기기에 재연결 중...');

      try {
        final dev = BluetoothDevice.fromId(lastId);

        // 연결 상태 확인
        final state = await dev.connectionState.first;
        if (state == BluetoothConnectionState.connected) {
          _device = dev;
          setState(() => _connState = BluetoothConnectionState.connected);
          await _discoverAndSubscribe();
          _startRssi();
          _watchConnection();
          setState(() => _status = '재연결됨');
          _didRestoreOnce = true;
          return;
        }

        // 새로 연결
        await dev.connect(
          autoConnect: false,
          timeout: const Duration(seconds: 10),
        );
        _device = dev;

        try {
          await dev.requestMtu(512);
        } catch (_) {}

        setState(() {
          _connState = BluetoothConnectionState.connected;
          _status = '재연결됨';
        });

        await _discoverAndSubscribe();
        _startRssi();
        _watchConnection();
        _didRestoreOnce = true;
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
      _rxBuf.clear();
      _log.clear();
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
          (c) => c.uuid == nusTxChar && c.properties.write,
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
          final writables = s.characteristics.where((c) => c.properties.write);
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
  }

  void _onBytes(List<int> data) {
    if (data.isEmpty) return;
    String txt = '';
    try {
      txt = utf8.decode(data);
    } catch (_) {}

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
    if (txt.isNotEmpty && RegExp(r'^[0-9\s,;]+$').hasMatch(txt)) {
      _parseLine(txt.trim());
      return;
    }
    if (data.length == 1) {
      _pushValue(data.first.toString());
      return;
    }
    for (final b in data) _pushValue(b.toString());
  }

  void _parseLine(String line) {
    if (line.isEmpty) return;
    final tokens = line.split(RegExp(r'[\s,;]+')).where((t) => t.isNotEmpty);
    for (final t in tokens) _pushValue(t);
  }

  void _pushValue(String val) {
    if (mounted) {
      setState(() {
        _lastRecv = val;
        _addLog(_LogEntry(direction: _Dir.rx, text: val));
      });
    }
  }

  Future<void> _sendData() async {
    final text = _txController.text.trim();
    if (text.isEmpty) return;
    if (_txChar == null || _connState != BluetoothConnectionState.connected) {
      _showSnack('연결 상태가 아닙니다.');
      return;
    }
    setState(() => _isSending = true);
    try {
      final bytes = utf8.encode('$text\n');
      final canWrite = _txChar!.properties.writeWithoutResponse;
      await _txChar!.write(bytes, withoutResponse: canWrite);
      _addLog(_LogEntry(direction: _Dir.tx, text: text));
      _txController.clear();
    } catch (e) {
      _showSnack('전송 실패: $e');
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  void _addLog(_LogEntry entry) {
    _log.insert(0, entry);
    if (_log.length > 200) _log.removeLast();
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
    _rssiTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final rssi = await _device?.readRssi();
        if (mounted && rssi != null) {
          setState(() {
            _lastRssi = rssi;
            _estimatedDist = _calcDist(rssi);
          });
        }
        if (rssi != null) {
          final running = await FlutterForegroundTask.isRunningService;
          if (running) {
            FlutterForegroundTask.sendDataToTask({
              'cmd': 'rssi',
              'value': rssi,
            });
          }
        }
      } catch (_) {}
    });
  }

  void _cancelRssi() {
    _rssiTimer?.cancel();
    _rssiTimer = null;
  }

  Future<void> _disconnect() async {
    _userWantsConnect = false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('wantConnect', false);

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
      _estimatedDist = 0.0;
      _rxBuf.clear();
      _log.clear();
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
    final threshold = _distToRssi(_maxDist);
    if (_lastRssi! > threshold) return kGreen;
    if (_lastRssi! > threshold - 10) return kOrange;
    return kRed;
  }

  String get _zoneLabel {
    if (!_connected) return '연결 안됨';
    if (_lastRssi == null) return '측정 중...';
    final threshold = _distToRssi(_maxDist);
    if (_lastRssi! > threshold) return '범위 안';
    return '범위 초과';
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
      onPopInvoked: (didPop) {
        if (!didPop) FlutterForegroundTask.minimizeApp();
      },
      child: Scaffold(
        backgroundColor: kBg,
        body: SafeArea(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(horizontal: 20.w, vertical: 16.h),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(),
                SizedBox(height: 24.h),
                _buildDistanceGauge(),
                SizedBox(height: 20.h),
                _buildStatusCard(),
                SizedBox(height: 16.h),
                _buildSettingsCard(),
                SizedBox(height: 16.h),
                _buildSendCard(),
                SizedBox(height: 16.h),
                _buildLogCard(),
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
    final ratio = _connected && _lastRssi != null
        ? (_estimatedDist / _maxDist).clamp(0.0, 1.2)
        : 0.0;
    final inRange =
        _connected && _lastRssi != null && _estimatedDist <= _maxDist;

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
              // 진행 원
              SizedBox(
                width: 200.w,
                height: 200.w,
                child: CircularProgressIndicator(
                  value: ratio.clamp(0.0, 1.0),
                  strokeWidth: 12,
                  backgroundColor: kBeige,
                  color: _zoneColor,
                  strokeCap: StrokeCap.round,
                ),
              ),
              // 내부 콘텐츠
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    inRange ? Icons.person_pin_circle : Icons.person_off,
                    size: 36,
                    color: _zoneColor,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _connected && _lastRssi != null
                        ? '${_estimatedDist.toStringAsFixed(1)}m'
                        : '--',
                    style: TextStyle(
                      fontSize: 36.sp,
                      fontWeight: FontWeight.w700,
                      color: kBrownDeep,
                    ),
                  ),
                  Text(
                    _zoneLabel,
                    style: TextStyle(
                      fontSize: 13.sp,
                      color: _zoneColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (_connected && _lastRssi != null)
                    Text(
                      '${_lastRssi} dBm',
                      style: TextStyle(fontSize: 11.sp, color: kGrey),
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
                    '감지 범위 ${_maxDist.toStringAsFixed(1)}m',
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
                  const SizedBox(height: 8),
                  _settingSlider(
                    label: '감지 거리',
                    value: _maxDist,
                    min: 0.5,
                    max: 5.0,
                    divisions: 45,
                    display: '${_maxDist.toStringAsFixed(1)}m',
                    color: kBrown,
                    onChanged: (v) {
                      setState(() => _maxDist = v);
                      _saveSettings();
                    },
                  ),
                  _settingSlider(
                    label: 'TX Power (1m 기준)',
                    value: _txPower,
                    min: -80,
                    max: -40,
                    divisions: 40,
                    display: '${_txPower.round()} dBm',
                    color: kBrown,
                    onChanged: (v) {
                      setState(() => _txPower = v);
                      _saveSettings();
                    },
                  ),
                  _settingSlider(
                    label: '환경 계수 n',
                    value: _pathN,
                    min: 1.0,
                    max: 5.0,
                    divisions: 40,
                    display: _pathN.toStringAsFixed(1),
                    color: kBrown,
                    onChanged: (v) {
                      setState(() => _pathN = v);
                      _saveSettings();
                    },
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () {
                        setState(() {
                          _txPower = -59.0;
                          _pathN = 2.0;
                          _maxDist = 3.0;
                        });
                        _saveSettings();
                      },
                      child: const Text(
                        '초기화',
                        style: TextStyle(color: kGrey, fontSize: 12),
                      ),
                    ),
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

  Widget _settingSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required Color color,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 12.sp, color: kGrey),
            ),
            Text(
              display,
              style: TextStyle(
                fontSize: 12.sp,
                color: kBrownDeep,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: color,
            thumbColor: color,
            overlayColor: color.withOpacity(0.15),
            inactiveTrackColor: kBeige,
            trackHeight: 4,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }

  // ── 송신 카드 ─────────────────────────────────────────────
  Widget _buildSendCard() {
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.send, color: kBrown, size: 20),
              const SizedBox(width: 10),
              Text(
                '데이터 전송',
                style: TextStyle(
                  fontSize: 14.sp,
                  fontWeight: FontWeight.w700,
                  color: kBrownDeep,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _txController,
                  enabled: _connected,
                  decoration: InputDecoration(
                    hintText: _connected ? '보낼 데이터 입력...' : '연결 후 사용 가능',
                    hintStyle: const TextStyle(color: kGrey, fontSize: 13),
                    filled: true,
                    fillColor: kBg,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  onSubmitted: (_) => _sendData(),
                  textInputAction: TextInputAction.send,
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: (_connected && !_isSending) ? _sendData : null,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: _connected ? kBrown : kBeige,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: _isSending
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.send, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── 로그 카드 ─────────────────────────────────────────────
  Widget _buildLogCard() {
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
          GestureDetector(
            onTap: () => setState(() => _showLog = !_showLog),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  const Icon(Icons.history, color: kBrown, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    '송수신 로그',
                    style: TextStyle(
                      fontSize: 14.sp,
                      fontWeight: FontWeight.w700,
                      color: kBrownDeep,
                    ),
                  ),
                  const Spacer(),
                  if (_log.isNotEmpty)
                    Text(
                      '${_log.length}건',
                      style: TextStyle(fontSize: 12.sp, color: kGrey),
                    ),
                  const SizedBox(width: 8),
                  Icon(
                    _showLog ? Icons.expand_less : Icons.expand_more,
                    color: kGrey,
                    size: 20,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: Column(
              children: [
                const Divider(color: kBeige, height: 1),
                SizedBox(
                  height: 200.h,
                  child: _log.isEmpty
                      ? const Center(
                          child: Text(
                            '아직 데이터가 없습니다.',
                            style: TextStyle(color: kGrey, fontSize: 13),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: _log.length,
                          itemBuilder: (_, i) {
                            final e = _log[i];
                            final isTx = e.direction == _Dir.tx;
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 3,
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    isTx
                                        ? Icons.arrow_upward_rounded
                                        : Icons.arrow_downward_rounded,
                                    size: 12,
                                    color: isTx ? kBrown : kGreen,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    e.timeStr,
                                    style: TextStyle(
                                      fontSize: 11.sp,
                                      color: kGrey,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      e.text,
                                      style: TextStyle(
                                        fontSize: 13.sp,
                                        color: isTx ? kBrown : kBrownDeep,
                                        fontWeight: isTx
                                            ? FontWeight.w600
                                            : FontWeight.normal,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: GestureDetector(
                      onTap: () => setState(() {
                        _log.clear();
                        _lastRecv = '-';
                      }),
                      child: Text(
                        '로그 지우기',
                        style: TextStyle(
                          fontSize: 12.sp,
                          color: kGrey,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            crossFadeState: _showLog
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 250),
          ),
        ],
      ),
    );
  }
}

enum _Dir { tx, rx }

class _LogEntry {
  final _Dir direction;
  final String text;
  final String timeStr;

  _LogEntry({required this.direction, required this.text})
    : timeStr = _fmt(DateTime.now());

  static String _fmt(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';
}

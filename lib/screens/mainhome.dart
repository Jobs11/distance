import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:distance/screens/scan_page.dart';
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
  final Guid nusService = Guid("6e400001-b5a3-f393-e0a9-e50e24dcca9e");
  final Guid nusRxChar = Guid("6e400003-b5a3-f393-e0a9-e50e24dcca9e");
  final Guid nusTxChar = Guid("6e400002-b5a3-f393-e0a9-e50e24dcca9e");

  BluetoothDevice? _device;
  BluetoothCharacteristic? _txChar;
  BluetoothConnectionState _connState = BluetoothConnectionState.disconnected;

  String _status = '대기';
  String _lastRecv = '-';
  final List<_LogEntry> _log = [];
  int? _lastRssi;

  StreamSubscription<BluetoothConnectionState>? _connSub;
  StreamSubscription<List<int>>? _notifySub;
  Timer? _rssiTimer;
  bool _userWantsConnect = false;

  Duration _reconnectDelay = const Duration(seconds: 1);
  final Duration _maxReconnectDelay = const Duration(seconds: 20);

  bool _restoring = false;
  bool _didRestoreOnce = false;

  final StringBuffer _rxBuf = StringBuffer();

  final TextEditingController _txController = TextEditingController();
  final FocusNode _txFocus = FocusNode();
  bool _isSending = false;

  // ── 초기화 ────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    initForegroundTask();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreConnectIntent();
      _requestBatteryOpt();
    });
  }

  @override
  void dispose() {
    _txController.dispose();
    _txFocus.dispose();
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

  // ── 권한 ──────────────────────────────────────────────────
  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final res = await [
      Permission.notification,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
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

  // ── 자동 재연결 복원 ──────────────────────────────────────
  Future<void> _restoreConnectIntent() async {
    if (_restoring) return;
    _restoring = true;
    try {
      if (_didRestoreOnce && _connState == BluetoothConnectionState.connected)
        return;
      if (!await _ensurePermissions()) return;
      if (!await _ensureBluetoothOn()) return;

      final prefs = await SharedPreferences.getInstance();
      final want = prefs.getBool('wantConnect') ?? false;
      if (!want) return;
      _userWantsConnect = true;

      if (_device != null && _connState == BluetoothConnectionState.connected) {
        _didRestoreOnce = true;
        return;
      }

      final lastId = prefs.getString('lastDeviceId');
      if (lastId != null && lastId.isNotEmpty) {
        try {
          final dev = BluetoothDevice.fromId(lastId);
          await dev.connect(
            autoConnect: false,
            timeout: const Duration(seconds: 8),
          );
          _device = dev;
          setState(() => _connState = BluetoothConnectionState.connected);
          await _afterConnected();
          _didRestoreOnce = true;
          return;
        } catch (e) {
          debugPrint('직접 재연결 실패: $e');
        }
      }
      _didRestoreOnce = true;
    } finally {
      _restoring = false;
    }
  }

  // ── 스캔 페이지 → 선택 → 연결 ────────────────────────────
  Future<void> _scanAndConnect() async {
    if (!await _ensurePermissions()) {
      setState(() => _status = '권한을 허용해 주세요.');
      return;
    }
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
          notificationText: '블루투스 연결 유지 중...',
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
    setState(() => _status = '발견: $name, 연결 중…');

    _connSub?.cancel();
    _connSub = _device!.connectionState.listen((s) {
      setState(() => _connState = s);
    });

    try {
      await _device!.connect(
        autoConnect: false,
        timeout: const Duration(seconds: 8),
      );
      await _device!.requestMtu(512);
      setState(() => _status = '연결 성공! 서비스 검색 중…');
      await _discoverAndSubscribe();
      _startRssi();
    } catch (e) {
      setState(() => _status = '연결 실패: $e');
    }
  }

  // ── 서비스/캐릭터리스틱 탐색 ─────────────────────────────
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
      setState(() => _status = '알림 캐릭터리스틱을 찾지 못했습니다.');
      return;
    }

    _txChar = tx;

    _notifySub?.cancel();
    await rx.setNotifyValue(true);
    _notifySub = rx.onValueReceived.listen(
      (bytes) => _onBytes(bytes),
      onError: (e) => debugPrint('RX error: $e'),
    );

    setState(() => _status = '수신 대기 중');
  }

  // ── 수신 파서 ─────────────────────────────────────────────
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

  // ── 송신 ──────────────────────────────────────────────────
  Future<void> _sendData() async {
    final text = _txController.text.trim();
    if (text.isEmpty) return;
    if (_txChar == null) {
      _showSnack('TX 캐릭터리스틱 없음');
      return;
    }
    if (_connState != BluetoothConnectionState.connected) {
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
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  // ── RSSI ──────────────────────────────────────────────────
  void _startRssi() {
    _cancelRssi();
    _rssiTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final rssi = await _device?.readRssi();
        if (mounted) setState(() => _lastRssi = rssi);
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

  // ── 연결 해제 ─────────────────────────────────────────────
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
      _status = '연결 해제';
      _lastRecv = '-';
      _lastRssi = null;
      _rxBuf.clear();
      _log.clear();
    });
  }

  // ── 재연결 ────────────────────────────────────────────────
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

  // ── UI ────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final connected = _connState == BluetoothConnectionState.connected;
    final name = _device?.platformName.isNotEmpty == true
        ? _device!.platformName
        : _device?.remoteId.str ?? '-';

    return PopScope(
      canPop: false,
      onPopInvoked: (didPop) {
        if (!didPop) FlutterForegroundTask.minimizeApp();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('BLE 모니터'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: Icon(
                Icons.circle,
                size: 14,
                color: connected ? Colors.greenAccent : Colors.grey,
              ),
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: EdgeInsets.all(16.w),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── 연결/해제 버튼 ──
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _scanAndConnect,
                    icon: const Icon(Icons.bluetooth_searching, size: 18),
                    label: const Text('연결 시도'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: connected ? _disconnect : null,
                    icon: const Icon(Icons.bluetooth_disabled, size: 18),
                    label: const Text('연결 해제'),
                    style: ElevatedButton.styleFrom(
                      foregroundColor: Colors.red,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 8.h),

              // ── 상태 정보 ──
              Text(
                '상태: $_status',
                style: TextStyle(fontSize: 13.sp, color: Colors.grey[700]),
              ),
              Text(
                '기기: $name',
                style: TextStyle(fontSize: 12.sp, color: Colors.grey),
              ),
              Text(
                'RSSI: ${_lastRssi?.toString() ?? '-'} dBm  |  최근 수신: $_lastRecv',
                style: TextStyle(fontSize: 12.sp, color: Colors.grey),
              ),
              SizedBox(height: 10.h),

              // ── RSSI 가드 ──
              if (_device != null && connected) RssiGuard(device: _device!),
              SizedBox(height: 8.h),

              // ── TX 입력창 ──
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _txController,
                      focusNode: _txFocus,
                      enabled: connected,
                      decoration: InputDecoration(
                        hintText: connected ? '보낼 데이터 입력...' : '연결 후 사용 가능',
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 12.w,
                          vertical: 10.h,
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        suffixIcon: _txController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear, size: 18),
                                onPressed: () =>
                                    setState(() => _txController.clear()),
                              )
                            : null,
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _sendData(),
                      textInputAction: TextInputAction.send,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    height: 44,
                    child: ElevatedButton(
                      onPressed: (connected && !_isSending) ? _sendData : null,
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        backgroundColor: Colors.blue,
                        foregroundColor: Colors.white,
                      ),
                      child: _isSending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.send, size: 20),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 10.h),

              // ── 로그 헤더 ──
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '송수신 로그',
                    style: TextStyle(
                      fontSize: 14.sp,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () => setState(() {
                      _log.clear();
                      _lastRecv = '-';
                    }),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('지우기'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.grey,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
              SizedBox(height: 4.h),

              // ── 로그 리스트 ──
              SizedBox(
                height: 200.h,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black12),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.grey[50],
                  ),
                  child: _log.isEmpty
                      ? const Center(
                          child: Text(
                            '아직 송수신된 데이터가 없습니다.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: _log.length,
                          itemBuilder: (context, i) {
                            final entry = _log[i];
                            final isTx = entry.direction == _Dir.tx;
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    isTx
                                        ? Icons.arrow_upward_rounded
                                        : Icons.arrow_downward_rounded,
                                    size: 14,
                                    color: isTx ? Colors.blue : Colors.green,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    entry.timeStr,
                                    style: TextStyle(
                                      fontSize: 11.sp,
                                      color: Colors.grey,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      entry.text,
                                      style: TextStyle(
                                        fontSize: 13.sp,
                                        color: isTx
                                            ? Colors.blue[700]
                                            : Colors.black87,
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
              ),
              SizedBox(height: 16.h),
            ],
          ),
        ),
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

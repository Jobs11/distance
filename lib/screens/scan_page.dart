import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

class SelectedDevice {
  final BluetoothDevice device;
  final String displayName;
  final int? rssi;

  const SelectedDevice({
    required this.device,
    required this.displayName,
    this.rssi,
  });
}

class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  final Map<String, ScanResult> _results = {};
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<bool>? _isScanSub;
  bool _isScanning = false;

  @override
  void initState() {
    super.initState();
    _startScan();
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _isScanSub?.cancel();
    try {
      FlutterBluePlus.stopScan();
    } catch (_) {}
    super.dispose();
  }

  Future<bool> _ensurePermissions() async {
    if (!Platform.isAndroid) return true;
    final res = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
    return res.values.every((s) => s.isGranted);
  }

  Future<void> _startScan() async {
    if (!await _ensurePermissions()) {
      _showSnack('블루투스 권한을 허용해 주세요.');
      return;
    }

    final adapterState = await FlutterBluePlus.adapterState.first;
    if (adapterState != BluetoothAdapterState.on) {
      _showSnack('블루투스를 켜 주세요.');
      return;
    }

    setState(() {
      _results.clear();
      _isScanning = true;
    });

    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    } catch (_) {}

    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 30),
      androidScanMode: AndroidScanMode.lowLatency,
    );

    await _scanSub?.cancel();
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      if (!mounted) return;
      setState(() {
        for (final r in results) {
          _results[r.device.remoteId.str] = r;
        }
      });
    });

    await _isScanSub?.cancel();
    _isScanSub = FlutterBluePlus.isScanning.listen((scanning) {
      if (mounted) setState(() => _isScanning = scanning);
    });
  }

  void _onTap(ScanResult r) async {
    try {
      if (FlutterBluePlus.isScanningNow) await FlutterBluePlus.stopScan();
    } catch (_) {}
    await _scanSub?.cancel();

    final name = r.advertisementData.advName.isNotEmpty
        ? r.advertisementData.advName
        : r.device.platformName.isNotEmpty
        ? r.device.platformName
        : r.device.remoteId.str;

    if (mounted) {
      Navigator.of(
        context,
      ).pop(SelectedDevice(device: r.device, displayName: name, rssi: r.rssi));
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  IconData _rssiIcon(int rssi) {
    if (rssi >= -60) return Icons.signal_cellular_alt;
    if (rssi >= -75) return Icons.signal_cellular_alt_2_bar;
    return Icons.signal_cellular_alt_1_bar;
  }

  Color _rssiColor(int rssi) {
    if (rssi >= -60) return Colors.green;
    if (rssi >= -75) return Colors.orange;
    return Colors.red;
  }

  @override
  Widget build(BuildContext context) {
    final sorted =
        _results.values
            .where(
              (r) =>
                  r.advertisementData.advName.isNotEmpty ||
                  r.device.platformName.isNotEmpty,
            )
            .toList()
          ..sort((a, b) {
            final aName =
                a.advertisementData.advName.isNotEmpty ||
                a.device.platformName.isNotEmpty;
            final bName =
                b.advertisementData.advName.isNotEmpty ||
                b.device.platformName.isNotEmpty;
            if (aName && !bName) return -1;
            if (!aName && bName) return 1;
            return b.rssi.compareTo(a.rssi);
          });

    return Scaffold(
      appBar: AppBar(
        title: const Text('기기 선택'),
        actions: [
          if (_isScanning)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.refresh),
              tooltip: '다시 스캔',
              onPressed: _startScan,
            ),
        ],
      ),
      body: Column(
        children: [
          // 상태 배너
          Container(
            width: double.infinity,
            color: _isScanning
                ? Colors.blue.withOpacity(0.08)
                : Colors.grey.withOpacity(0.05),
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      _isScanning ? Icons.bluetooth_searching : Icons.bluetooth,
                      size: 16,
                      color: _isScanning ? Colors.blue : Colors.grey,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _isScanning
                          ? '스캔 중... (${sorted.length}개 발견)  최대 30초'
                          : '스캔 완료 (${sorted.length}개 발견)',
                      style: TextStyle(
                        fontSize: 13,
                        color: _isScanning ? Colors.blue : Colors.grey,
                      ),
                    ),
                  ],
                ),
                if (_isScanning) ...[
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    backgroundColor: Colors.blue.withOpacity(0.1),
                    color: Colors.blue,
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: sorted.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.bluetooth_disabled,
                          size: 48,
                          color: Colors.grey[300],
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _isScanning ? '스캔 중...' : '발견된 기기 없음',
                          style: const TextStyle(color: Colors.grey),
                        ),
                        if (!_isScanning) ...[
                          const SizedBox(height: 12),
                          ElevatedButton.icon(
                            onPressed: _startScan,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('다시 스캔'),
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: sorted.length,
                    separatorBuilder: (_, __) =>
                        const Divider(height: 1, indent: 16),
                    itemBuilder: (context, i) {
                      final r = sorted[i];
                      final name = r.advertisementData.advName.isNotEmpty
                          ? r.advertisementData.advName
                          : r.device.platformName.isNotEmpty
                          ? r.device.platformName
                          : '(이름 없음)';
                      final rssi = r.rssi;

                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: _rssiColor(rssi).withOpacity(0.12),
                          child: Icon(
                            Icons.bluetooth,
                            color: _rssiColor(rssi),
                            size: 20,
                          ),
                        ),
                        title: Text(
                          name,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text(
                          r.device.remoteId.str,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                        ),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              _rssiIcon(rssi),
                              size: 18,
                              color: _rssiColor(rssi),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$rssi\ndBm',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 11,
                                color: _rssiColor(rssi),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        onTap: () => _onTap(r),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:vibration/vibration.dart';

class RssiGuard extends StatefulWidget {
  final BluetoothDevice device; // 이미 연결된 디바이스
  const RssiGuard({super.key, required this.device});

  @override
  State<RssiGuard> createState() => _RssiGuardState();
}

class _RssiGuardState extends State<RssiGuard> {
  Timer? _timer;

  // --- 튜닝 파라미터 ---
  static const int sampleIntervalMs = 1000; // 1초마다 체크
  static const int movingWindow = 5; // 이동 평균 샘플 개수
  static const int triggerConsecutive = 3; // 연속 하락 횟수
  static const int cooldownMs = 5000; // 진동 쿨다운 5초
  static const int rssiFarThreshold = -70; // 이 값보다 작으면 "멀다"

  final List<int> _rssiBuf = [];
  int _consecutiveBelow = 0;
  DateTime _lastVibe = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSmoothed = 0;

  @override
  void initState() {
    super.initState();
    _startWatch();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startWatch() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: sampleIntervalMs), (
      _,
    ) async {
      try {
        final rssi = await widget.device.readRssi();
        _pushRssi(rssi);
        final smooth = _smoothedRssi();

        // 히스테리시스: 올라갔다 내려갔다 할 때 펄럭임 방지
        final farNow = smooth <= rssiFarThreshold;
        if (farNow) {
          _consecutiveBelow++;
        } else {
          _consecutiveBelow = 0;
        }

        // 연속 N회 이하이면 무시, 넘으면 이벤트
        if (_consecutiveBelow >= triggerConsecutive) {
          _maybeVibrate();
          _consecutiveBelow = 0; // 한 번 울리고 카운터 리셋
        }

        setState(() {
          _lastSmoothed = smooth;
        });
      } catch (_) {
        // 연결 끊김 등: 필요 시 상태 표시
      }
    });
  }

  void _pushRssi(int val) {
    _rssiBuf.add(val);
    if (_rssiBuf.length > movingWindow) {
      _rssiBuf.removeAt(0);
    }
  }

  int _smoothedRssi() {
    if (_rssiBuf.isEmpty) return 0;
    // 이동 평균(간단). 중앙값 필터로 바꿔도 좋음.
    final avg = _rssiBuf.reduce((a, b) => a + b) / _rssiBuf.length;
    return avg.round();
  }

  Future<void> _maybeVibrate() async {
    final now = DateTime.now();
    if (now.difference(_lastVibe).inMilliseconds < cooldownMs) return;

    if (await Vibration.hasVibrator()) {
      // 패턴: 0ms 대기 → 200ms 진동 → 120ms 쉬고 → 200ms 진동
      await Vibration.vibrate(pattern: [0, 200, 120, 200]);
    }
    _lastVibe = now;
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'RSSI 가드 (멀어지면 진동)',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('평활 RSSI: $_lastSmoothed dBm'),
                Text('임계값: $rssiFarThreshold dBm'),
              ],
            ),
            const SizedBox(height: 4),
            Text('연속 하락 감지: $_consecutiveBelow / $triggerConsecutive'),
            const SizedBox(height: 8),
            Text(
              _lastSmoothed <= rssiFarThreshold
                  ? '상태: 멀어짐 (감지 중)'
                  : '상태: 정상 거리',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: _lastSmoothed <= rssiFarThreshold
                    ? Colors.red
                    : Colors.green,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

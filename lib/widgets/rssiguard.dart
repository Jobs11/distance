import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vibration/vibration.dart';

// ── SharedPreferences 키 ─────────────────────────────────────
const _kTxPower = 'rssi_txPower';
const _kPathN = 'rssi_pathN';
const _kMaxDist = 'rssi_maxDist'; // 감지 거리 (m)
const _kVibEnabled = 'rssi_vibEnabled';

class RssiGuard extends StatefulWidget {
  final BluetoothDevice device;
  const RssiGuard({super.key, required this.device});

  @override
  State<RssiGuard> createState() => _RssiGuardState();
}

class _RssiGuardState extends State<RssiGuard> {
  Timer? _timer;

  static const int _sampleMs = 1000;
  static const int _movingWindow = 5;
  static const int _triggerConsec = 3;
  static const int _cooldownMs = 5000;

  // 조절 파라미터
  double _txPower = -59.0;
  double _pathN = 2.0;
  double _maxDist = 3.0; // 기본 감지 거리 3m
  bool _vibEnabled = true;

  // 런타임 상태
  final List<int> _rssiBuf = [];
  int _consecutiveOver = 0;
  DateTime _lastVibe = DateTime.fromMillisecondsSinceEpoch(0);
  int _lastSmoothed = 0;
  double _currentDist = 0.0;

  bool _expanded = false;

  // ── 초기화 ───────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _loadPrefs().then((_) => _startWatch());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() {
      _txPower = p.getDouble(_kTxPower) ?? -59.0;
      _pathN = p.getDouble(_kPathN) ?? 2.0;
      _maxDist = p.getDouble(_kMaxDist) ?? 3.0;
      _vibEnabled = p.getBool(_kVibEnabled) ?? true;
    });
  }

  Future<void> _savePrefs() async {
    final p = await SharedPreferences.getInstance();
    await p.setDouble(_kTxPower, _txPower);
    await p.setDouble(_kPathN, _pathN);
    await p.setDouble(_kMaxDist, _maxDist);
    await p.setBool(_kVibEnabled, _vibEnabled);
  }

  // ── 공식: 거리 → RSSI 임계값 변환 ───────────────────────
  // RSSI = txPower - 10 * n * log10(distance)
  double _distToRssi(double dist) {
    if (dist <= 0) return _txPower.toDouble();
    return _txPower - 10.0 * _pathN * log(dist) / ln10;
  }

  // ── 공식: RSSI → 거리 추정 ───────────────────────────────
  double _rssiToDist(int rssi) {
    if (rssi == 0) return 0.0;
    return pow(10.0, (_txPower - rssi) / (10.0 * _pathN)).toDouble();
  }

  // ── RSSI 감시 루프 ───────────────────────────────────────
  void _startWatch() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: _sampleMs), (_) async {
      try {
        final rssi = await widget.device.readRssi();
        _rssiBuf.add(rssi);
        if (_rssiBuf.length > _movingWindow) _rssiBuf.removeAt(0);

        final smooth = (_rssiBuf.reduce((a, b) => a + b) / _rssiBuf.length)
            .round();
        final dist = _rssiToDist(smooth);
        final threshold = _distToRssi(_maxDist); // 설정 거리의 RSSI 임계값

        // 설정 거리 초과 시 카운트
        final overDist = smooth <= threshold; // RSSI가 임계값 이하 = 더 멀다
        if (overDist) {
          _consecutiveOver++;
        } else {
          _consecutiveOver = 0;
        }

        if (_consecutiveOver >= _triggerConsec) {
          if (_vibEnabled) _maybeVibrate();
          _consecutiveOver = 0;
        }

        if (mounted) {
          setState(() {
            _lastSmoothed = smooth;
            _currentDist = dist;
          });
        }
      } catch (_) {}
    });
  }

  Future<void> _maybeVibrate() async {
    final now = DateTime.now();
    if (now.difference(_lastVibe).inMilliseconds < _cooldownMs) return;
    if (await Vibration.hasVibrator()) {
      await Vibration.vibrate(pattern: [0, 200, 120, 200]);
    }
    _lastVibe = now;
  }

  // ── 상태 색상 ────────────────────────────────────────────
  Color get _statusColor {
    if (_currentDist <= 0) return Colors.grey;
    final ratio = _currentDist / _maxDist;
    if (ratio <= 0.5) return Colors.green;
    if (ratio <= 0.85) return Colors.orange;
    return Colors.red;
  }

  String get _statusLabel {
    if (_currentDist <= 0) return '측정 중...';
    if (_currentDist <= _maxDist)
      return '범위 안 (${_currentDist.toStringAsFixed(1)}m)';
    return '범위 초과 (${_currentDist.toStringAsFixed(1)}m)';
  }

  // ── UI ───────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final threshold = _distToRssi(_maxDist);
    final inRange = _lastSmoothed > threshold;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 2,
      child: Column(
        children: [
          // ── 상태 헤더 (탭으로 펼치기/접기) ──
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      // 상태 아이콘
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: _statusColor.withOpacity(0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          inRange ? Icons.person_pin_circle : Icons.person_off,
                          color: _statusColor,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _statusLabel,
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: _statusColor,
                              ),
                            ),
                            Text(
                              'RSSI: $_lastSmoothed dBm  |  임계: ${threshold.round()} dBm',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        color: Colors.grey,
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),

                  // ── 거리 게이지 바 ──
                  _buildDistanceBar(),
                ],
              ),
            ),
          ),

          // ── 설정 패널 ──
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: _buildSettingsPanel(),
            crossFadeState: _expanded
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 250),
          ),
        ],
      ),
    );
  }

  // ── 거리 게이지 바 ───────────────────────────────────────
  Widget _buildDistanceBar() {
    final ratio = (_currentDist / _maxDist).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              '0m',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
            Text(
              '감지 범위: ${_maxDist.toStringAsFixed(1)}m',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Stack(
          children: [
            // 배경 바
            Container(
              height: 12,
              decoration: BoxDecoration(
                color: Colors.grey[200],
                borderRadius: BorderRadius.circular(6),
              ),
            ),
            // 현재 거리 바
            AnimatedFractionallySizedBox(
              duration: const Duration(milliseconds: 400),
              widthFactor: ratio,
              child: Container(
                height: 12,
                decoration: BoxDecoration(
                  color: _statusColor,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
            // 감지 범위 끝 마커
            Positioned(
              right: 0,
              child: Container(width: 2, height: 12, color: Colors.black26),
            ),
          ],
        ),
      ],
    );
  }

  // ── 설정 패널 ────────────────────────────────────────────
  Widget _buildSettingsPanel() {
    final threshold = _distToRssi(_maxDist);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Divider(),

          // ── 감지 거리 슬라이더 ──
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '감지 거리',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              Text(
                '${_maxDist.toStringAsFixed(1)} m  →  ${threshold.round()} dBm',
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  color: Colors.blue,
                ),
              ),
            ],
          ),
          const Text(
            '이 거리를 초과하면 진동 알림',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: Colors.blue,
              thumbColor: Colors.blue,
              overlayColor: Colors.blue.withOpacity(0.2),
              inactiveTrackColor: Colors.blue.withOpacity(0.2),
              trackHeight: 5,
            ),
            child: Slider(
              value: _maxDist,
              min: 0.5,
              max: 5.0,
              divisions: 45, // 0.1m 단위
              onChanged: (v) {
                setState(() => _maxDist = v);
                _savePrefs();
              },
            ),
          ),
          // 눈금 레이블
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(10, (i) {
                final d = 0.5 + i * 0.5;
                return Text(
                  '${d.toStringAsFixed(d < 1 ? 1 : 0)}m',
                  style: TextStyle(
                    fontSize: 10,
                    color: (d - 0.05 <= _maxDist && _maxDist <= d + 0.05)
                        ? Colors.blue
                        : Colors.grey,
                    fontWeight: (d - 0.05 <= _maxDist && _maxDist <= d + 0.05)
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                );
              }),
            ),
          ),

          const Divider(height: 24),
          const Text(
            '거리 추정 파라미터',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
          ),
          const SizedBox(height: 4),
          const Text(
            'TX Power와 n 값을 실측 환경에 맞게 조절하세요.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 8),

          // TX Power
          _buildParamSlider(
            label: 'TX Power (1m 기준 RSSI)',
            value: _txPower,
            min: -80,
            max: -40,
            divisions: 40,
            display: '${_txPower.round()} dBm',
            onChanged: (v) {
              setState(() => _txPower = v);
              _savePrefs();
            },
          ),

          // n 값
          _buildParamSlider(
            label: '환경 계수 n  (실내 2~4 / 실외 1.6~2)',
            value: _pathN,
            min: 1.0,
            max: 5.0,
            divisions: 40,
            display: _pathN.toStringAsFixed(1),
            onChanged: (v) {
              setState(() => _pathN = v);
              _savePrefs();
            },
          ),

          const Divider(height: 24),

          // 진동 토글
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                '범위 초과 시 진동',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
              ),
              Switch(
                value: _vibEnabled,
                onChanged: (v) {
                  setState(() => _vibEnabled = v);
                  _savePrefs();
                },
              ),
            ],
          ),

          const SizedBox(height: 4),
          // 초기화 버튼
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () {
                setState(() {
                  _txPower = -59.0;
                  _pathN = 2.0;
                  _maxDist = 3.0;
                  _vibEnabled = true;
                });
                _savePrefs();
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('기본값으로 초기화'),
              style: TextButton.styleFrom(foregroundColor: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildParamSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text(label, style: const TextStyle(fontSize: 13))),
            Text(
              display,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          onChanged: onChanged,
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

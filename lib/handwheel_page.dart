import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';

import 'device_page.dart';
import 'ff_core.dart';

Color _focusPointColor(ColorScheme colors, bool isA) {
  final dark = colors.brightness == Brightness.dark;
  if (isA) return Color(dark ? 0xFFFFBF69 : 0xFF8A4600);
  return Color(dark ? 0xFF79B8FF : 0xFF1C5FA7);
}

enum FocusHapticStyle {
  standard('标准刻度', '每圈／全行程 60 格，轻巧清楚', 60, 80),
  dense('密集轻触', '每圈／全行程 120 格，细密轻触', 120, 35),
  firm('清晰段落', '每圈／全行程 30 格，段落感更强', 30, 100);

  final String label, description;
  final int detents, intervalMs;
  const FocusHapticStyle(
    this.label,
    this.description,
    this.detents,
    this.intervalMs,
  );

  Future<void> pulse() => switch (this) {
    FocusHapticStyle.standard => HapticFeedback.selectionClick(),
    FocusHapticStyle.dense => HapticFeedback.lightImpact(),
    FocusHapticStyle.firm => HapticFeedback.mediumImpact(),
  };
}

// Accumulate finger travel; never queue a burst of pulses after a fast drag.
class _FocusTicks {
  double _travel = 0;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  void reset() => _travel = 0;
  void move(double fraction, FocusHapticStyle style, bool enabled) {
    if (!enabled) {
      reset();
      return;
    }
    _travel += fraction.abs();
    final now = DateTime.now();
    if (_travel >= 1 / style.detents &&
        now.difference(_last).inMilliseconds >= style.intervalMs) {
      unawaited(style.pulse());
      _last = now;
      reset();
    }
  }
}

class HandwheelPage extends StatefulWidget {
  final FfCore core;
  const HandwheelPage({super.key, required this.core});

  @override
  State<HandwheelPage> createState() => _HandwheelPageState();
}

class _HandwheelPageState extends State<HandwheelPage>
    with WidgetsBindingObserver {
  ColorScheme get _colors => Theme.of(context).colorScheme;
  TextStyle get _hintStyle =>
      TextStyle(fontSize: 11, color: _colors.onSurfaceVariant);
  FfState _s = const FfState();
  StreamSubscription<FfState>? _sub;
  bool _haptics = true;
  FocusHapticStyle _hapticStyle = FocusHapticStyle.standard;
  bool _sliderMode = false;
  bool _settingsExpanded = false;
  double? _sliderDrag;
  final _sliderTicks = _FocusTicks();
  int? _arrivalSequence;
  double _duration = 2;
  final _parameterDrag = <int, double>{};
  bool get _canTune => _s.linkAlive && _s.fm03?.online == true && !_calRunning;
  bool get _calRunning =>
      !['idle', 'completed', 'cancelled', 'failed'].contains(_s.calStage);
  bool get _paused => _s.stopLatched && _s.strokeSteps > 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sub = widget.core.states().listen((s) {
      if (!mounted) return;
      if (_arrivalSequence != null &&
          s.wheelArrivalSequence != _arrivalSequence &&
          _haptics) {
        unawaited(HapticFeedback.heavyImpact());
      }
      _arrivalSequence = s.wheelArrivalSequence;
      setState(() {
        _s = s;
        if (!s.wheelReady) _sliderDrag = null;
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      unawaited(widget.core.stopPressed());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sub?.cancel();
    unawaited(widget.core.leaveLens());
    super.dispose();
  }

  Future<void> _calibrate() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('FM03 自动寻限位'),
        content: const Text(
          '电机会自动寻找镜头两端限位，请确认齿轮安装牢固。重新寻限位会清除本次 A/B 点。\n\n内部寻限位无法通过软件中止；“停止观察”只结束观察，立即中止需断开电机电源。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开始寻限位'),
          ),
        ],
      ),
    );
    if (ok == true) await widget.core.startAutoCalibration();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('手机跟焦手轮'),
          if (_s.appVersion.isNotEmpty)
            Text('v${_s.appVersion}', style: _hintStyle),
        ],
      ),
      actions: [
        IconButton(
          tooltip: '连接设备',
          icon: const Icon(LucideIcons.wifi),
          onPressed: () async {
            final device = await Navigator.of(context).push(
              MaterialPageRoute<FfDevice>(
                builder: (_) =>
                    DevicePage(core: widget.core, linkOpen: _s.connected),
              ),
            );
            if (device != null) {
              await widget.core.selectDevice(device);
              await widget.core.connect();
            }
          },
        ),
      ],
    ),
    body: SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, box) {
            if (box.maxWidth > 600 && box.maxWidth > box.maxHeight) {
              return Row(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        _inputSelector(),
                        Expanded(
                          child: Center(
                            child: SizedBox.square(
                              dimension: math.min(box.maxHeight - 56, 400),
                              child: _focusInput(),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      children: [
                        Expanded(
                          child: SingleChildScrollView(child: _controls()),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(width: double.infinity, child: _stopButton()),
                      ],
                    ),
                  ),
                ],
              );
            }
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 620),
                child: Column(
                  children: [
                    _status(),
                    const SizedBox(height: 8),
                    _inputSelector(),
                    const SizedBox(height: 8),
                    Center(
                      child: SizedBox.square(
                        dimension: math.min(
                          box.maxWidth,
                          math.min(350, box.maxHeight * .52),
                        ),
                        child: _focusInput(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: SingleChildScrollView(
                        key: const ValueKey('wheel-controls-scroll'),
                        child: _controls(showStatus: false),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(width: double.infinity, child: _stopButton()),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    ),
  );

  Widget _status() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          Chip(
            avatar: Icon(
              LucideIcons.circle,
              size: 10,
              color: _s.linkAlive && _s.canOk
                  ? _colors.primary
                  : _focusPointColor(_colors, true),
            ),
            label: Text(
              _s.linkAlive ? (_s.canOk ? 'CAN 在线' : '等待 CAN 反馈') : '未连接设备',
            ),
          ),
          Chip(
            label: Text(
              _paused
                  ? '已停止锁定'
                  : _calRunning
                  ? '正在寻限位'
                  : _s.wheelReady
                  ? (_s.wheelPulling
                        ? 'A/B 定时拉焦'
                        : _s.moving
                        ? ((_s.target - _s.pos).abs() <=
                                  (_s.fm03?.tolerance ?? 4)
                              ? '正在确认到位'
                              : '正在拉焦')
                        : _s.result == kResultRejected
                        ? '未到目标 · 已停止'
                        : '手轮就绪')
                  : '先完成寻限位',
            ),
          ),
          if (_s.wheelRangeEnabled) const Chip(label: Text('A/B 限位')),
        ],
      ),
      const SizedBox(height: 8),
      Text(
        _s.positionTrusted
            ? '实际 ${_s.pos} → 目标 ${_s.target} · 误差 ${(_s.target - _s.pos).abs()} / ±${_s.fm03?.tolerance ?? 4}'
            : '实际位置 --',
        style: TextStyle(color: _colors.onSurfaceVariant),
      ),
    ],
  );

  Widget _inputSelector() => SegmentedButton<bool>(
    selectedIcon: const Icon(LucideIcons.check),
    key: const ValueKey('focus-input-mode'),
    segments: const [
      ButtonSegment(
        value: false,
        icon: Icon(LucideIcons.rotateCw),
        label: Text('手轮'),
      ),
      ButtonSegment(
        value: true,
        icon: Icon(LucideIcons.moveHorizontal),
        label: Text('滑块'),
      ),
    ],
    selected: {_sliderMode},
    onSelectionChanged: (values) => setState(() {
      _sliderMode = values.single;
      _sliderDrag = null;
      _sliderTicks.reset();
    }),
  );

  Widget _focusInput() => _sliderMode ? _focusSlider() : _dial();

  Widget _focusSlider() {
    final value = (_sliderDrag ?? _s.slider).clamp(0.0, 1.0);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('目标焦点', style: TextStyle(color: _colors.onSurfaceVariant)),
          Text(
            '${(value * 100).toStringAsFixed(1)}%',
            style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w300),
          ),
          const SizedBox(height: 4),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 12,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 16),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
            ),
            child: LayoutBuilder(
              builder: (context, box) => SizedBox(
                height: 72,
                child: Stack(
                  children: [
                    Positioned(
                      top: 12,
                      left: 0,
                      right: 0,
                      child: Slider(
                        key: const ValueKey('focus-slider'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 8,
                        ),
                        value: value,
                        secondaryTrackValue: _s.positionTrusted
                            ? (_s.pos / 4096).clamp(0.0, 1.0)
                            : null,
                        semanticFormatterCallback: (v) =>
                            '目标焦点 ${(v * 100).toStringAsFixed(1)}%',
                        onChangeStart: _s.wheelReady
                            ? (_) => _sliderTicks.reset()
                            : null,
                        onChanged: _s.wheelReady
                            ? (v) {
                                _sliderTicks.move(
                                  v - (_sliderDrag ?? _s.slider),
                                  _hapticStyle,
                                  _haptics,
                                );
                                setState(() => _sliderDrag = v);
                                unawaited(widget.core.setSlider(v));
                              }
                            : null,
                        onChangeEnd: _s.wheelReady
                            ? (_) => setState(() => _sliderDrag = null)
                            : null,
                      ),
                    ),
                    if (_s.wheelA != null)
                      _sliderMarker(
                        'A',
                        _s.wheelA!,
                        _focusPointColor(_colors, true),
                        box.maxWidth,
                      ),
                    if (_s.wheelB != null)
                      _sliderMarker(
                        'B',
                        _s.wheelB!,
                        _focusPointColor(_colors, false),
                        box.maxWidth,
                      ),
                  ],
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [Text('0%'), Text('100%')],
            ),
          ),
          Wrap(
            spacing: 16,
            children: [
              Text(
                _s.wheelA == null
                    ? 'A 未设置'
                    : 'A ${(_s.wheelA! / 4096 * 100).toStringAsFixed(1)}%',
                key: const ValueKey('slider-a-value'),
                style: TextStyle(color: _focusPointColor(_colors, true)),
              ),
              Text(
                _s.wheelB == null
                    ? 'B 未设置'
                    : 'B ${(_s.wheelB! / 4096 * 100).toStringAsFixed(1)}%',
                key: const ValueKey('slider-b-value'),
                style: TextStyle(color: _focusPointColor(_colors, false)),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _s.wheelReady ? '拖动直接跟焦 · 遵循 A/B 限位' : '等待解锁与电机就绪',
            style: _hintStyle,
          ),
        ],
      ),
    );
  }

  Widget _sliderMarker(String name, int coordinate, Color color, double width) {
    final fraction = (coordinate / 4096).clamp(0.0, 1.0);
    final visual = Directionality.of(context) == TextDirection.rtl
        ? 1 - fraction
        : fraction;
    final line = Container(width: 2, height: 18, color: color);
    final label = Text(
      name,
      style: TextStyle(
        color: color,
        fontSize: 11,
        height: 16 / 11,
        fontWeight: FontWeight.bold,
      ),
    );
    return Positioned(
      left: 24 + (width - 48) * visual - 10,
      top: name == 'A' ? 0 : 38,
      width: 20,
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: Column(
            key: ValueKey('slider-marker-$name'),
            children: name == 'A' ? [label, line] : [line, label],
          ),
        ),
      ),
    );
  }

  Widget _dial() => WheelDial(
    enabled: _s.wheelReady,
    haptics: _haptics,
    hapticStyle: _hapticStyle,
    actual: _s.positionTrusted ? _s.pos / 4096 : null,
    target: _s.slider,
    a: _s.wheelA == null ? null : _s.wheelA! / 4096,
    b: _s.wheelB == null ? null : _s.wheelB! / 4096,
    label: _paused
        ? '已停止'
        : _s.positionTrusted
        ? '${(_s.pos / 4096 * 100).toStringAsFixed(1)}%'
        : '--',
    onTurn: widget.core.turnWheel,
  );

  Widget _controls({bool showStatus = true}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (showStatus) ...[_status(), const SizedBox(height: 12)],
      _motorParameter(
        '电机速度',
        kFm03MaxSpeed,
        _s.fm03?.maxSpeed ?? (_s.speedRevS * 4096).round(),
        256,
        '1～256 拨轮协议值，64 为原响应。新版固件调速同时影响小幅追赶和速度上限；可边转边调，不是 RPM。',
      ),
      Row(
        children: [
          Expanded(child: _point('A', _s.wheelA)),
          const SizedBox(width: 12),
          Expanded(child: _point('B', _s.wheelB)),
        ],
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('限制在 A/B 点之间'),
        subtitle: const Text('两点可任意先后；开启后手轮不会越过端点'),
        value: _s.wheelRangeEnabled,
        onChanged:
            _s.wheelReady &&
                !_s.moving &&
                _s.wheelA != null &&
                _s.wheelB != null
            ? widget.core.setWheelRange
            : null,
      ),
      Wrap(
        spacing: 12,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('A/B 拉焦时长'),
          DropdownButton<double>(
            icon: const Icon(LucideIcons.chevronDown),
            value: _duration,
            items: [
              for (final n in [.5, 1.0, 2.0, 4.0, 8.0])
                DropdownMenuItem(
                  value: n,
                  child: Text('${n.toStringAsFixed(n < 1 ? 1 : 0)} 秒'),
                ),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _duration = v);
            },
          ),
          TextButton(
            onPressed:
                !_s.moving &&
                    !_s.wheelPulling &&
                    (_s.wheelA != null || _s.wheelB != null)
                ? widget.core.clearWheelPoints
                : null,
            child: const Text('清除 A/B'),
          ),
        ],
      ),
      Row(
        children: [
          const Expanded(child: Text('A/B 拉焦曲线')),
          DropdownButton<String>(
            icon: const Icon(LucideIcons.chevronDown),
            key: const ValueKey('wheel-pull-curve'),
            value: _s.wheelPullCurve,
            items: const [
              DropdownMenuItem(value: 'smooth', child: Text('缓入缓出')),
              DropdownMenuItem(value: 'linear', child: Text('匀速目标')),
            ],
            onChanged: _s.wheelPulling
                ? null
                : (v) {
                    if (v != null) widget.core.setWheelPullCurve(v);
                  },
          ),
        ],
      ),
      Text(
        '仅控制下方“拉到 A/B”的目标节奏；“到 A/B 点”直接发送终点。转手轮实时跟随，不受时长与曲线影响。实际到位受速度与负载限制。',
        style: _hintStyle,
      ),
      Row(
        children: [
          for (final point in ['A', 'B'])
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: OutlinedButton.icon(
                  onPressed:
                      _s.wheelReady &&
                          (point == 'A' ? _s.wheelA : _s.wheelB) != null
                      ? () =>
                            widget.core.pullWheelTo(point, duration: _duration)
                      : null,
                  icon: const Icon(LucideIcons.arrowLeftRight),
                  label: Text('拉到 $point'),
                ),
              ),
            ),
        ],
      ),
      if (_s.wheelPulling)
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: LinearProgressIndicator(),
        ),
      const SizedBox(height: 16),
      const SizedBox(height: 8),
      Text(_s.msg, style: _hintStyle),
      if (!_s.wheelReady && !_paused && !_calRunning) ...[
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: _s.connected && _s.calSupported ? _calibrate : null,
          icon: const Icon(LucideIcons.refreshCw),
          label: const Text('FM03 自动寻限位'),
        ),
        if (!_s.connected)
          OutlinedButton.icon(
            onPressed: widget.core.connect,
            icon: const Icon(LucideIcons.wifi),
            label: const Text('连接电机'),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Text('手轮模式无需物距表。寻限位完成后即可控制。', style: _hintStyle),
        ),
      ],
      const SizedBox(height: 16),
      Card(
        child: ExpansionTile(
          title: const Text('手轮响应与设置'),
          trailing: Icon(
            _settingsExpanded ? LucideIcons.chevronUp : LucideIcons.chevronDown,
          ),
          onExpansionChanged: (expanded) =>
              setState(() => _settingsExpanded = expanded),
          leading: const Icon(LucideIcons.slidersHorizontal),
          childrenPadding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Expanded(child: Text('旋转灵敏度')),
                DropdownButton<double>(
                  icon: const Icon(LucideIcons.chevronDown),
                  value: [.25, .5, 1.0, 2.0].contains(_s.wheelSensitivity)
                      ? _s.wheelSensitivity
                      : null,
                  hint: Text('${_s.wheelSensitivity}×'),
                  items: [
                    for (final n in [.25, .5, 1.0, 2.0])
                      DropdownMenuItem(value: n, child: Text('$n×')),
                  ],
                  onChanged: (v) {
                    if (v != null) widget.core.setWheelSensitivity(v);
                  },
                ),
              ],
            ),
            Text('1×：手轮转一圈对应完整行程；0.25× 用于精细对焦。', style: _hintStyle),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('反转手轮方向'),
              value: _s.wheelReversed,
              onChanged: widget.core.setWheelReversed,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('触感反馈'),
              subtitle: const Text('手轮与滑块共用；实际到达端点时强触感'),
              value: _haptics,
              onChanged: (v) => setState(() => _haptics = v),
            ),
            DropdownButtonFormField<FocusHapticStyle>(
              icon: const Icon(LucideIcons.chevronDown),
              key: const ValueKey('focus-haptic-style'),
              initialValue: _hapticStyle,
              decoration: const InputDecoration(labelText: '触感效果'),
              items: [
                for (final style in FocusHapticStyle.values)
                  DropdownMenuItem(value: style, child: Text(style.label)),
              ],
              onChanged: _haptics
                  ? (v) {
                      if (v != null) {
                        setState(() {
                          _hapticStyle = v;
                          _sliderTicks.reset();
                        });
                      }
                    }
                  : null,
            ),
            const SizedBox(height: 8),
            Text('${_hapticStyle.description}；快速拖动会限制触发频率。', style: _hintStyle),
            const SizedBox(height: 12),
            _motorParameter(
              '启动加速',
              kFm03Acceleration,
              _s.fm03?.acceleration ?? 8,
              64,
              _s.fm03 != null && _s.fm03!.acceleration == null
                  ? '需要固件 2.1.0 或更新版本。'
                  : '每 50 毫秒增加的速度值。默认 8；响应慢可先试 16，再试 32。越大启动越快。',
              supported: _s.fm03?.acceleration != null,
            ),
            _motorParameter(
              '接近目标减速',
              kFm03Gain,
              _s.fm03?.gain ?? 4,
              64,
              '默认 4；越小，小幅转动越跟手；越大，接近目标越柔和。响应慢可先试 2。',
            ),
            _motorParameter(
              '到位容差（±坐标）',
              kFm03Tolerance,
              _s.fm03?.tolerance ?? 4,
              64,
              '默认 ±4。差几个坐标仍追焦可试 ±8 或 ±12；范围越大越容易停稳，但到位精度越低。运动中可调。',
            ),
            Text(
              '设备已回读：速度 ${_s.fm03?.maxSpeed ?? "--"} · 加速 ${_s.fm03?.acceleration ?? "--"} · 减速 ${_s.fm03?.gain ?? "--"} · 容差 ±${_s.fm03?.tolerance ?? "--"} · 拨轮输出 ${_s.fm03?.value ?? "--"}',
              style: _hintStyle,
            ),
            Text(
              '运动中调参需固件 2.1.1。参数以设备回读为准，停稳后保存到设备，自动模式也会使用。A/B 点在重连、离开模式或重新寻限位后清除。',
              style: _hintStyle,
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _s.connected && _s.calSupported && !_calRunning
                  ? _calibrate
                  : null,
              icon: const Icon(LucideIcons.refreshCw),
              label: const Text('重新寻限位'),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _stopButton() => FilledButton.icon(
    style: FilledButton.styleFrom(
      backgroundColor: _paused ? _colors.primary : const Color(0xFFAB4249),
      foregroundColor: _paused ? _colors.onPrimary : Colors.white,
      disabledForegroundColor: _colors.onSurfaceVariant,
      disabledBackgroundColor: _colors.surfaceContainerHighest,
      padding: const EdgeInsets.all(16),
    ),
    onPressed: _s.connected && (!_paused || _s.canResume)
        ? (_paused ? widget.core.resumeControl : widget.core.stopPressed)
        : null,
    icon: Icon(_paused ? LucideIcons.rotateCcw : LucideIcons.circleStop),
    label: Text(
      _paused
          ? '复位并继续手轮'
          : _calRunning
          ? '停止观察'
          : '停止并锁定',
    ),
  );

  Widget _motorParameter(
    String label,
    int key,
    int value,
    int max,
    String hint, {
    bool supported = true,
  }) {
    final current = (_parameterDrag[key] ?? value.toDouble()).clamp(
      1.0,
      max.toDouble(),
    );
    final enabled = _canTune && supported;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label ${current.round()} / $max'),
        Slider(
          key: ValueKey('wheel-parameter-$key'),
          min: 1,
          max: max.toDouble(),
          divisions: max - 1,
          value: current,
          label: '${current.round()}',
          onChanged: enabled
              ? (v) => setState(() => _parameterDrag[key] = v)
              : null,
          onChangeEnd: enabled
              ? (v) {
                  widget.core.setFm03(key, v.round());
                  setState(() => _parameterDrag.remove(key));
                }
              : null,
        ),
        Text(hint, style: _hintStyle),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _point(String name, int? coordinate) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Text(
            '$name 点',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            coordinate == null
                ? '未设置'
                : '$coordinate · ${(coordinate / 4096 * 100).toStringAsFixed(1)}%',
            style: _hintStyle,
          ),
          TextButton(
            onPressed: _s.wheelReady && !_s.moving && !_s.wheelPulling
                ? () => widget.core.setWheelPoint(name)
                : null,
            child: Text(coordinate == null ? '设置 $name 点' : '重设 $name 点'),
          ),
          OutlinedButton(
            onPressed: _s.wheelReady && coordinate != null
                ? () => widget.core.pullWheelTo(name)
                : null,
            child: Text('到 $name 点'),
          ),
        ],
      ),
    ),
  );
}

/// Touch geometry and haptics only; coordinate mapping and limits live in Swift.
class WheelDial extends StatefulWidget {
  final bool enabled, haptics;
  final FocusHapticStyle hapticStyle;
  final double? actual, a, b;
  final double target;
  final String label;
  final ValueChanged<double> onTurn;
  const WheelDial({
    super.key,
    required this.enabled,
    required this.haptics,
    this.hapticStyle = FocusHapticStyle.standard,
    required this.actual,
    required this.target,
    this.a,
    this.b,
    required this.label,
    required this.onTurn,
  });

  @override
  State<WheelDial> createState() => _WheelDialState();
}

class _WheelDialState extends State<WheelDial> {
  int? _pointer;
  bool _centerDrag = false;
  double? _angle;
  final _ticks = _FocusTicks();
  double? _touchAngle(Offset p, Size size) {
    final delta = p - Offset(size.width / 2, size.height / 2);
    if (delta.distance < size.shortestSide * .18) return null;
    return math.atan2(delta.dy, delta.dx);
  }

  void _endTouch(int pointer) {
    if (pointer != _pointer) return;
    _pointer = null;
    _angle = null;
  }

  @override
  void didUpdateWidget(covariant WheelDial oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) {
      _pointer = null;
      _angle = null;
      _ticks.reset();
    }
    if (widget.hapticStyle != oldWidget.hapticStyle ||
        widget.haptics != oldWidget.haptics) {
      _ticks.reset();
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final size = Size(box.maxWidth, box.maxHeight);
      final colors = Theme.of(context).colorScheme;
      return Semantics(
        label: '跟焦手轮',
        value: widget.label,
        increasedValue: widget.enabled ? '正向微调' : null,
        decreasedValue: widget.enabled ? '反向微调' : null,
        enabled: widget.enabled,
        onIncrease: widget.enabled ? () => widget.onTurn(1 / 120) : null,
        onDecrease: widget.enabled ? () => widget.onTurn(-1 / 120) : null,
        child: RawGestureDetector(
          // Own touches from pointer-down, including vertical starts, before a
          // containing scrollable can win the gesture arena.
          gestures: {
            EagerGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                  EagerGestureRecognizer.new,
                  (_) {},
                ),
          },
          child: Listener(
            key: const ValueKey('focus-wheel'),
            behavior: HitTestBehavior.opaque,
            onPointerDown: (e) {
              if (!widget.enabled || _pointer != null) return;
              _pointer = e.pointer;
              _angle = _touchAngle(e.localPosition, size);
              _centerDrag = _angle == null;
              _ticks.reset();
            },
            onPointerMove: (e) {
              if (!widget.enabled || e.pointer != _pointer) return;
              double turns = 0;
              if (_centerDrag) {
                // Starting in the hub gives a fine vertical adjustment; keep
                // that mode until release so crossing the hub cannot jump.
                turns = -e.delta.dy / size.height / 4;
              } else {
                final next = _touchAngle(e.localPosition, size);
                if (next != null && _angle != null) {
                  turns =
                      math.atan2(
                        math.sin(next - _angle!),
                        math.cos(next - _angle!),
                      ) /
                      (2 * math.pi);
                }
                _angle = next;
              }
              if (turns == 0) return;
              widget.onTurn(turns);
              _ticks.move(turns, widget.hapticStyle, widget.haptics);
            },
            onPointerUp: (e) => _endTouch(e.pointer),
            onPointerCancel: (e) => _endTouch(e.pointer),
            child: CustomPaint(
              painter: _WheelPainter(
                widget.actual,
                widget.target,
                widget.a,
                widget.b,
                widget.enabled,
                colors,
              ),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'FOCUS',
                      style: TextStyle(
                        fontSize: 11,
                        letterSpacing: 4,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      widget.label,
                      style: const TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      widget.enabled ? '轮缘旋转 · 中心上下微调' : '等待解锁与电机就绪',
                      style: TextStyle(
                        fontSize: 11,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _WheelPainter extends CustomPainter {
  final double? actual, a, b;
  final double target;
  final bool enabled;
  final ColorScheme colors;
  _WheelPainter(
    this.actual,
    this.target,
    this.a,
    this.b,
    this.enabled,
    this.colors,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.shortestSide * .43;
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..shader = RadialGradient(
          colors: [colors.surfaceContainer, colors.surfaceContainerLow],
        ).createShader(Rect.fromCircle(center: center, radius: r)),
    );
    canvas.drawCircle(
      center,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = colors.outlineVariant,
    );
    for (var i = 0; i < 60; i++) {
      final theta = i * math.pi / 30 - math.pi / 2;
      final unit = Offset(math.cos(theta), math.sin(theta));
      canvas.drawLine(
        center + unit * (r - (i % 5 == 0 ? 18 : 10)),
        center + unit * (r - 4),
        Paint()
          ..strokeWidth = i % 5 == 0 ? 2 : 1
          ..color = enabled ? colors.onSurfaceVariant : colors.outline,
      );
    }
    final ring = Rect.fromCircle(center: center, radius: r + 6);
    canvas.drawArc(
      ring,
      -math.pi / 2,
      2 * math.pi * target.clamp(0, 1),
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round
        ..color = enabled ? colors.primary : colors.outline,
    );
    void marker(double value, Color color, String? label) {
      final theta = value * 2 * math.pi - math.pi / 2;
      final unit = Offset(math.cos(theta), math.sin(theta));
      canvas.drawCircle(center + unit * (r - 27), 5, Paint()..color = color);
      if (label != null) {
        final text = TextPainter(
          text: TextSpan(
            text: label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.bold,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        text.paint(
          canvas,
          center + unit * (r + 18) - Offset(text.width / 2, text.height / 2),
        );
      }
    }

    if (a != null) marker(a!, _focusPointColor(colors, true), 'A');
    if (b != null) marker(b!, _focusPointColor(colors, false), 'B');
    if (actual != null) marker(actual!, colors.onSurface, null);
  }

  @override
  bool shouldRepaint(covariant _WheelPainter old) =>
      actual != old.actual ||
      target != old.target ||
      a != old.a ||
      b != old.b ||
      enabled != old.enabled ||
      colors != old.colors;
}

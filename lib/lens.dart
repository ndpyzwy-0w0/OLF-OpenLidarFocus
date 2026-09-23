import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'lens_lut.dart';

/// 一个镜头的持久化参数：名称、备注、行程标定、变远方向和距离标定表。
///
/// [strokeSteps] 是机械行程长度（脉冲），在 [strokeMicrosteps] 细分下量的，
/// 换细分后用 [strokeAt] 换算——它是**跨会话有效**的物理量。
///
/// [dir] = 焦距变远的旋转方向：+1 表示步数增大，-1 表示步数减小。对齐后由它
/// 决定允许运动的软限位区间，从而保证不会拧反、也不会超出标定过的行程。
///
/// “焦距最近点”是**每次进入都要重新对齐**的会话量：步进电机开环、掉电丢绝对
/// 位置，所以不在这里持久化。
class Lens {
  final String id;
  final String name;
  final String params;
  final LensLut lut;
  final int? strokeSteps;
  final int strokeMicrosteps;
  final int dir;

  Lens({
    required this.id,
    required this.name,
    this.params = '',
    LensLut? lut,
    this.strokeSteps,
    this.strokeMicrosteps = 16,
    this.dir = 1,
  }) : lut = lut ?? LensLut(const []);

  /// 行程是否已标定。未标定就不能对齐，也不能自动跟焦。
  bool get calibrated => (strokeSteps ?? 0).abs() > 0;

  static String newId() =>
      'lens-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

  /// 行程脉冲数，换算到指定细分。行程只记长度，不记绝对位置。
  int strokeAt(int microsteps) {
    final s = strokeSteps;
    if (s == null || s == 0) return 0;
    if (strokeMicrosteps <= 0 || microsteps <= 0) return s.abs();
    return (s.abs() * microsteps / strokeMicrosteps).round();
  }

  Lens copyWith({
    String? name,
    String? params,
    LensLut? lut,
    int? strokeSteps,
    int? strokeMicrosteps,
    int? dir,
  }) =>
      Lens(
        id: id,
        name: name ?? this.name,
        params: params ?? this.params,
        lut: lut ?? this.lut,
        strokeSteps: strokeSteps ?? this.strokeSteps,
        strokeMicrosteps: strokeMicrosteps ?? this.strokeMicrosteps,
        dir: dir ?? this.dir,
      );

  /// 清空行程标定（“重新标定行程”用），距离标定表和方向保留。
  Lens withoutStroke() => Lens(
        id: id,
        name: name,
        params: params,
        lut: lut,
        strokeMicrosteps: strokeMicrosteps,
        dir: dir,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'params': params,
        'dir': dir,
        if (strokeSteps != null) 'stroke': strokeSteps,
        'strokeMs': strokeMicrosteps,
        'lut': lut.toJson(),
      };

  factory Lens.fromJson(Map<String, dynamic> j) => Lens(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        params: (j['params'] ?? '').toString(),
        lut: LensLut.fromJson(
          Map<String, dynamic>.from(j['lut'] as Map? ?? const {}),
        ),
        strokeSteps: (j['stroke'] as num?)?.toInt(),
        strokeMicrosteps: (j['strokeMs'] as num?)?.toInt() ?? 16,
        dir: ((j['dir'] as num?)?.toInt() ?? 1) >= 0 ? 1 : -1,
      );
}

/// 对齐后的软限位区间：最近点 [near] 沿变远方向最多走 [stroke] 个脉冲。
///
/// 这就是“不会拧反、也不会超过标定行程”的落点：区间只在最近点到远端这一侧。
({int lo, int hi}) alignedRange(int near, int dir, int stroke) {
  final far = dir >= 0 ? near + stroke : near - stroke;
  return far >= near ? (lo: near, hi: far) : (lo: far, hi: near);
}

/// 从距离标定表推断“焦距变远”的方向：距离越远、步数越大就是 +1。
/// 表里不足两点或两点同值返回 null（让用户自己选）。
int? inferDir(LensLut lut) {
  if (!lut.ready) return null;
  final near = lut.points.first.steps;
  final far = lut.points.last.steps;
  if (near == far) return null;
  return far > near ? 1 : -1;
}

/// 对齐后把距离标定表平移到本次会话的坐标系：让表里距离最小（焦距最近）的那个
/// 点落在今天的最近点上。表里存的是标定当次会话的步数，跨会话必须重锚。
int lutRebaseDelta(int near, LensLut lut) =>
    lut.points.isEmpty ? 0 : near - lut.points.first.steps;

/// 镜头列表持久化，与旧的单镜头标定同目录：
/// `%APPDATA%\iphone_follow_focus\lenses.json`（Windows），
/// 其它平台用 `$HOME/iphone_follow_focus/lenses.json`。
class LensStore {
  final List<Lens> lenses;

  LensStore([List<Lens>? lenses]) : lenses = lenses ?? <Lens>[];

  static Directory _dir() {
    final base = Platform.environment['APPDATA'] ??
        Platform.environment['HOME'] ??
        Directory.systemTemp.path;
    final dir = Directory('$base${Platform.pathSeparator}iphone_follow_focus');
    dir.createSync(recursive: true);
    return dir;
  }

  static File _file() =>
      File('${_dir().path}${Platform.pathSeparator}lenses.json');
  static File _legacyFile() =>
      File('${_dir().path}${Platform.pathSeparator}lens_lut.json');

  static Future<LensStore> load() async {
    try {
      final f = _file();
      if (f.existsSync()) {
        final raw = f.readAsStringSync().trim();
        if (raw.isNotEmpty) return LensStore(_decode(raw));
      }
    } catch (e) {
      // 存档损坏不能让 App 起不来；当空列表处理，等下次保存再覆盖。
      debugPrint('镜头列表读取失败，按空列表处理：$e');
    }
    // 旧版只有一张全局标定表，迁移成第一个镜头，避免升级后标定丢失。
    final migrated = _migrateLegacy();
    final store = LensStore(migrated);
    if (migrated.isNotEmpty) await store.save();
    return store;
  }

  static List<Lens> _decode(String raw) {
    final root = jsonDecode(raw);
    final list = root is Map ? root['lenses'] : root;
    if (list is! List) return const [];
    return [
      for (final e in list)
        if (e is Map) Lens.fromJson(Map<String, dynamic>.from(e)),
    ];
  }

  static List<Lens> _migrateLegacy() {
    try {
      final f = _legacyFile();
      if (!f.existsSync()) return const [];
      final raw = f.readAsStringSync().trim();
      if (raw.isEmpty) return const [];
      final lut = LensLut.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      if (lut.points.isEmpty) return const [];
      return [Lens(id: 'legacy', name: '默认镜头', lut: lut)];
    } catch (e) {
      debugPrint('旧标定表迁移失败：$e');
      return const [];
    }
  }

  Lens upsert(Lens lens) {
    final i = lenses.indexWhere((l) => l.id == lens.id);
    if (i < 0) {
      lenses.add(lens);
    } else {
      lenses[i] = lens;
    }
    return lens;
  }

  void remove(String id) => lenses.removeWhere((l) => l.id == id);

  Future<void> save() async {
    _file().writeAsStringSync(jsonEncode({
      'lenses': [for (final l in lenses) l.toJson()],
    }));
  }
}

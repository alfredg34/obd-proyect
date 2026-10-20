import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';

String h2(int v) => v.toRadixString(16).toUpperCase().padLeft(2, '0');

// ───────────────────────── Transportes ─────────────────────────
abstract class Transport {
  Future<String> request(String cmd, int timeoutMs);
  Future<void> close();
}

class TcpTransport implements Transport {
  final Socket _s;
  final StringBuffer _buf = StringBuffer();
  Completer<String>? _wait;
  late final StreamSubscription<List<int>> _sub;

  TcpTransport._(this._s) {
    _sub = _s.listen((d) {
      _buf.write(latin1.decode(d, allowInvalid: true));
      final t = _buf.toString();
      if (t.contains('>')) {
        final c = _wait;
        _buf.clear();
        if (c != null && !c.isCompleted) c.complete(t.replaceAll('>', ''));
      }
    }, onError: (_) {}, onDone: () {});
  }

  static Future<TcpTransport> open(String host, int port) async {
    final s = await Socket.connect(host, port, timeout: const Duration(seconds: 6));
    s.setOption(SocketOption.tcpNoDelay, true);
    return TcpTransport._(s);
  }

  @override
  Future<String> request(String cmd, int timeoutMs) {
    _buf.clear();
    final c = Completer<String>();
    _wait = c;
    _s.write('$cmd\r');
    return c.future.timeout(Duration(milliseconds: timeoutMs), onTimeout: () {
      final t = _buf.toString();
      _buf.clear();
      return t;
    });
  }

  @override
  Future<void> close() async {
    try {
      await _sub.cancel();
      _s.destroy();
    } catch (_) {}
  }
}

const MethodChannel _ch = MethodChannel('obd/bt');

class BtTransport implements Transport {
  static Future<List<Map<String, String>>> bonded() async {
    final ok = await _ch.invokeMethod<bool>('permission');
    if (ok != true) throw 'Permiso de Bluetooth denegado';
    final l = await _ch.invokeMethod<List<dynamic>>('bonded') ?? <dynamic>[];
    return l.map((e) {
      final m = e as Map;
      return <String, String>{'name': '${m['name']}', 'address': '${m['address']}'};
    }).toList();
  }

  static Future<BtTransport> open(String address) async {
    await _ch.invokeMethod('connect', {'address': address});
    return BtTransport();
  }

  @override
  Future<String> request(String cmd, int timeoutMs) async {
    final r = await _ch.invokeMethod<String>('request', {'cmd': cmd, 'timeout': timeoutMs});
    return r ?? '';
  }

  @override
  Future<void> close() async {
    try {
      await _ch.invokeMethod('close');
    } catch (_) {}
  }
}

// ───────────────────────── Definición de PIDs ─────────────────────────
double _w(List<int> d) => d[0] * 256.0 + d[1];

class PidDef {
  final String name;
  final String unit;
  final int len;
  final double Function(List<int>) f;
  PidDef(this.name, this.unit, this.len, this.f);
}

final Map<int, PidDef> kPids = {
  0x04: PidDef('Carga del motor', '%', 1, (d) => d[0] * 100 / 255),
  0x05: PidDef('Refrigerante', '°C', 1, (d) => d[0] - 40.0),
  0x06: PidDef('Corrección corta B1', '%', 1, (d) => d[0] / 1.28 - 100),
  0x07: PidDef('Corrección larga B1', '%', 1, (d) => d[0] / 1.28 - 100),
  0x08: PidDef('Corrección corta B2', '%', 1, (d) => d[0] / 1.28 - 100),
  0x09: PidDef('Corrección larga B2', '%', 1, (d) => d[0] / 1.28 - 100),
  0x0A: PidDef('Presión combustible', 'kPa', 1, (d) => d[0] * 3.0),
  0x0B: PidDef('MAP', 'kPa', 1, (d) => d[0].toDouble()),
  0x0C: PidDef('RPM', 'rpm', 2, (d) => _w(d) / 4),
  0x0D: PidDef('Velocidad', 'km/h', 1, (d) => d[0].toDouble()),
  0x0E: PidDef('Avance de encendido', '°', 1, (d) => d[0] / 2 - 64),
  0x0F: PidDef('Aire de admisión', '°C', 1, (d) => d[0] - 40.0),
  0x10: PidDef('MAF', 'g/s', 2, (d) => _w(d) / 100),
  0x11: PidDef('Acelerador', '%', 1, (d) => d[0] * 100 / 255),
  0x14: PidDef('O2 B1S1', 'V', 1, (d) => d[0] / 200),
  0x15: PidDef('O2 B1S2', 'V', 1, (d) => d[0] / 200),
  0x16: PidDef('O2 B1S3', 'V', 1, (d) => d[0] / 200),
  0x17: PidDef('O2 B1S4', 'V', 1, (d) => d[0] / 200),
  0x18: PidDef('O2 B2S1', 'V', 1, (d) => d[0] / 200),
  0x19: PidDef('O2 B2S2', 'V', 1, (d) => d[0] / 200),
  0x1F: PidDef('Tiempo de motor', 's', 2, (d) => _w(d)),
  0x21: PidDef('Distancia con MIL', 'km', 2, (d) => _w(d)),
  0x24: PidDef('A/F λ B1S1', 'λ', 2, (d) => _w(d) * 2 / 65536),
  0x28: PidDef('A/F λ B2S1', 'λ', 2, (d) => _w(d) * 2 / 65536),
  0x2F: PidDef('Nivel de combustible', '%', 1, (d) => d[0] * 100 / 255),
  0x33: PidDef('Presión barométrica', 'kPa', 1, (d) => d[0].toDouble()),
  0x3C: PidDef('Catalizador B1S1', '°C', 2, (d) => _w(d) / 10 - 40),
  0x3D: PidDef('Catalizador B2S1', '°C', 2, (d) => _w(d) / 10 - 40),
  0x3E: PidDef('Catalizador B1S2', '°C', 2, (d) => _w(d) / 10 - 40),
  0x3F: PidDef('Catalizador B2S2', '°C', 2, (d) => _w(d) / 10 - 40),
  0x42: PidDef('Voltaje del módulo', 'V', 2, (d) => _w(d) / 1000),
  0x43: PidDef('Carga absoluta', '%', 2, (d) => _w(d) * 100 / 255),
  0x46: PidDef('Temperatura ambiente', '°C', 1, (d) => d[0] - 40.0),
  0x5C: PidDef('Temperatura de aceite', '°C', 1, (d) => d[0] - 40.0),
  0x5E: PidDef('Consumo de combustible', 'L/h', 2, (d) => _w(d) / 20),
};

class MonTest {
  final int mid, tid, val, min, max;
  MonTest(this.mid, this.tid, this.val, this.min, this.max);
  bool get ok => val >= min && val <= max;
}

// ───────────────────────── Cliente ELM327 ─────────────────────────
class Elm {
  Transport? t;
  Future<void> _q = Future<void>.value();

  Future<String> send(String cmd, {int timeoutMs = 3000}) {
    final c = Completer<String>();
    _q = _q.then((_) async {
      try {
        final tr = t;
        if (tr == null) throw 'Sin conexión';
        c.complete(await tr.request(cmd, timeoutMs));
      } catch (e) {
        c.completeError(e);
      }
    });
    return c.future;
  }

  Future<String> init() async {
    await send('ATZ', timeoutMs: 6000);
    await send('ATE0');
    await send('ATL0');
    await send('ATS0');
    await send('ATH0');
    await send('ATSP0');
    final id = (await send('ATI')).replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    final r = await send('0100', timeoutMs: 12000);
    if (parse(r).isEmpty) {
      throw 'El adaptador responde pero el auto no. ¿Contacto encendido y adaptador bien puesto?';
    }
    return id;
  }

  Future<void> close() async {
    final tr = t;
    t = null;
    await tr?.close();
  }

  /// Convierte la respuesta de texto en bytes (maneja multi-trama CAN).
  List<int> parse(String r) {
    final plain = <List<int>>[];
    final multi = <int>[];
    for (final raw in r.split(RegExp(r'[\r\n]+'))) {
      var l = raw.replaceAll(' ', '').toUpperCase();
      if (l.isEmpty) continue;
      var indexed = false;
      if (RegExp(r'^[0-9A-F]:').hasMatch(l)) {
        l = l.substring(2);
        indexed = true;
      } else if (RegExp(r'^[0-9A-F]{3}$').hasMatch(l)) {
        continue;
      }
      if (l.length < 2 || l.length.isOdd || !RegExp(r'^[0-9A-F]+$').hasMatch(l)) continue;
      final b = <int>[];
      for (var i = 0; i < l.length; i += 2) {
        b.add(int.parse(l.substring(i, i + 2), radix: 16));
      }
      if (indexed) {
        multi.addAll(b);
      } else {
        plain.add(b);
      }
    }
    if (multi.isNotEmpty) return multi;
    return plain.isEmpty ? <int>[] : plain.first;
  }

  List<int>? payload(List<int> b, int header, [int? pid]) {
    for (var i = 0; i < b.length; i++) {
      if (b[i] == header && (pid == null || (i + 1 < b.length && b[i + 1] == pid))) {
        return b.sublist(pid == null ? i + 1 : i + 2);
      }
    }
    return null;
  }

  Future<List<int>?> pidBytes(int pid, {int mode = 1}) async {
    if (mode == 2) {
      final b = parse(await send('02${h2(pid)}00'));
      final p = payload(b, 0x42, pid);
      return (p == null || p.length < 2) ? null : p.sublist(1);
    }
    final b = parse(await send('${h2(mode)}${h2(pid)}'));
    return payload(b, mode + 0x40, pid);
  }

  Future<double?> readPid(int pid, {int mode = 1}) async {
    final def = kPids[pid];
    if (def == null) return null;
    final d = await pidBytes(pid, mode: mode);
    if (d == null || d.length < def.len) return null;
    return def.f(d);
  }

  Future<Set<int>> supportedPids() async {
    final s = <int>{};
    for (final base in [0x00, 0x20, 0x40, 0x60]) {
      final d = await pidBytes(base);
      if (d == null || d.length < 4) break;
      for (var i = 0; i < 32; i++) {
        if (((d[i ~/ 8] >> (7 - i % 8)) & 1) == 1) s.add(base + i + 1);
      }
      if (!s.contains(base + 0x20)) break;
    }
    return s;
  }

  String _decodeDtc(int a, int c) =>
      '${'PCBU'[a >> 6]}${(a >> 4) & 3}${(a & 15).toRadixString(16).toUpperCase()}${h2(c)}';

  /// mode: 3 confirmados, 7 pendientes, 10 permanentes
  Future<List<String>> dtcs(int mode) async {
    final cmd = mode == 10 ? '0A' : '0$mode';
    final b = parse(await send(cmd, timeoutMs: 6000));
    var d = payload(b, mode == 10 ? 0x4A : 0x40 + mode);
    if (d == null) return [];
    if (d.length.isOdd) d = d.sublist(1);
    final out = <String>[];
    for (var i = 0; i + 1 < d.length; i += 2) {
      if (d[i] == 0 && d[i + 1] == 0) continue;
      final code = _decodeDtc(d[i], d[i + 1]);
      if (!out.contains(code)) out.add(code);
    }
    return out;
  }

  Future<bool> clearDtcs() async {
    final r = await send('04', timeoutMs: 6000);
    return r.replaceAll(' ', '').contains('44');
  }

  Future<Map<String, String>> freezeFrame() async {
    final out = <String, String>{};
    final dtc = await pidBytes(0x02, mode: 2);
    if (dtc == null) return out;
    out['Falla que lo causó'] = dtc.length >= 2 && !(dtc[0] == 0 && dtc[1] == 0)
        ? _decodeDtc(dtc[0], dtc[1])
        : 'ninguna';
    for (final p in [0x04, 0x05, 0x06, 0x07, 0x0B, 0x0C, 0x0D, 0x0F, 0x11]) {
      final v = await readPid(p, mode: 2);
      final def = kPids[p]!;
      if (v != null) out[def.name] = '${v.toStringAsFixed(p == 0x0C ? 0 : 1)} ${def.unit}';
    }
    return out;
  }

  Future<List<MonTest>> mode06(int mid) async {
    final b = parse(await send('06${h2(mid)}', timeoutMs: 5000));
    final out = <MonTest>[];
    final i = b.indexOf(0x46);
    if (i < 0) return out;
    var pos = i + 1;
    while (pos + 9 <= b.length && b[pos] == mid) {
      out.add(MonTest(
        mid,
        b[pos + 1],
        (b[pos + 3] << 8) | b[pos + 4],
        (b[pos + 5] << 8) | b[pos + 6],
        (b[pos + 7] << 8) | b[pos + 8],
      ));
      pos += 9;
    }
    return out;
  }

  Future<String> vin() async {
    final b = parse(await send('0902', timeoutMs: 6000));
    final p = payload(b, 0x49, 0x02);
    if (p == null || p.length < 2) return '';
    final chars = p.skip(1).where((c) => (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A)).toList();
    return String.fromCharCodes(chars);
  }

  Future<Map<String, String>> readiness() async {
    final d = await pidBytes(0x01);
    final m = <String, String>{};
    if (d == null || d.length < 4) return m;
    m['Luz MIL (check engine)'] = (d[0] & 0x80) != 0 ? 'ENCENDIDA' : 'apagada';
    m['Códigos almacenados'] = '${d[0] & 0x7F}';
    void mon(String n, bool sup, bool notReady) {
      if (sup) m[n] = notReady ? 'incompleto' : 'listo';
    }

    mon('Fallos de encendido', (d[1] & 0x01) != 0, (d[1] & 0x10) != 0);
    mon('Sistema de combustible', (d[1] & 0x02) != 0, (d[1] & 0x20) != 0);
    mon('Componentes', (d[1] & 0x04) != 0, (d[1] & 0x40) != 0);
    const names = ['Catalizador', 'Catalizador calefactado', 'EVAP', 'Aire secundario', 'A/C', 'Sensor O2', 'Calefactor O2', 'EGR'];
    for (var i = 0; i < 8; i++) {
      mon(names[i], ((d[2] >> i) & 1) != 0, ((d[3] >> i) & 1) != 0);
    }
    return m;
  }
}

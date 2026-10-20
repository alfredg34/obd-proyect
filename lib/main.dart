import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'dtc_db.dart';
import 'elm.dart';

void main() => runApp(const ObdApp());

const kBg = Color(0xFF060A18);
const kCard = Color(0xFF0F1A33);
const kTile = Color(0xFF16254A);
const kAccent = Color(0xFF29D3FF);
const kOrange = Color(0xFFFF8A3D);
const kOk = Color(0xFF3DDC97);
const kWarn = Color(0xFFFFC857);
const kBad = Color(0xFFFF5A5F);
const kMuted = Color(0xFF8FA0C8);

// ───────────────────────── Sesión global ─────────────────────────
class Session extends ChangeNotifier {
  final Elm elm = Elm();
  bool connected = false;
  bool busy = false;
  String status = 'Desconectado';
  String adapter = '';
  Set<int> supported = {};
  Set<int> watch = {};
  bool accum = false;
  final Map<int, double> v = {};
  bool _poll = false;
  DateTime? _last;

  double tripL = 0, tripKm = 0;
  double displacement = 1.8, price = 35.0, tank = 50.0;

  void resetTrip() {
    tripL = 0;
    tripKm = 0;
    notifyListeners();
  }

  Future<void> connectWifi(String host, int port) => _open(() async {
        elm.t = await TcpTransport.open(host, port);
      });

  Future<void> connectBt(String address) => _open(() async {
        elm.t = await BtTransport.open(address);
      });

  Future<void> _open(Future<void> Function() open) async {
    busy = true;
    status = 'Conectando…';
    notifyListeners();
    try {
      await open();
      adapter = await elm.init();
      supported = await elm.supportedPids();
      connected = true;
      status = 'Conectado';
      _startPoll();
    } catch (e) {
      status = 'Error: $e';
      connected = false;
      await elm.close();
    }
    busy = false;
    notifyListeners();
  }

  Future<void> disconnect() async {
    _poll = false;
    await elm.close();
    connected = false;
    status = 'Desconectado';
    v.clear();
    notifyListeners();
  }

  void _startPoll() {
    if (_poll) return;
    _poll = true;
    _loop();
  }

  Future<void> _loop() async {
    var fails = 0;
    while (_poll) {
      final list = watch.where((p) => supported.isEmpty || supported.contains(p)).toList();
      if (list.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        continue;
      }
      for (final p in list) {
        if (!_poll) break;
        try {
          final val = await elm.readPid(p);
          if (val != null) v[p] = val;
          fails = 0;
        } catch (_) {
          fails++;
        }
        if (fails >= 6) break;
      }
      if (fails >= 6) {
        await disconnect();
        status = 'Conexión perdida';
        notifyListeners();
        return;
      }
      _accumulate();
      notifyListeners();
    }
  }

  void _accumulate() {
    final now = DateTime.now();
    final l = _last;
    _last = now;
    if (!accum || l == null) return;
    final ms = now.difference(l).inMilliseconds;
    if (ms > 5000) return;
    final dt = ms / 3600000.0;
    final lph = fuelLph();
    final spd = v[0x0D];
    if (lph != null) tripL += lph * dt;
    if (spd != null) tripKm += spd * dt;
  }

  /// Litros/hora: PID directo, MAF, o estimado con MAP + RPM + temperatura (densidad-velocidad).
  double? fuelLph() {
    final direct = v[0x5E];
    if (direct != null) return direct;
    var maf = v[0x10];
    if (maf == null) {
      final rpm = v[0x0C], map = v[0x0B], iat = v[0x0F];
      if (rpm == null || map == null || iat == null) return null;
      final imap = rpm * map / (iat + 273.15) / 2;
      maf = imap / 60 * 0.85 * displacement * 28.97 / 8.314;
    }
    return maf / 14.7 / 745 * 3600;
  }
}

final Session session = Session();

// ───────────────────────── Utilidades UI ─────────────────────────
String fmt(double? x, {int dec = 0}) => x == null ? '—' : x.toStringAsFixed(dec);

Color? tempColor(double? t) {
  if (t == null) return null;
  if (t < 60) return kAccent;
  if (t <= 100) return kOk;
  if (t <= 105) return kWarn;
  return kBad;
}

List<String> alerts(Map<int, double> v) {
  final a = <String>[];
  final t = v[0x05];
  if (t != null && t > 105) a.add('Refrigerante a ${fmt(t)} °C: temperatura alta. Si sigue subiendo, apaga el motor.');
  final volt = v[0x42];
  if (volt != null && volt < 12.0) a.add('Voltaje bajo (${fmt(volt, dec: 1)} V): revisa batería y alternador.');
  final s = v[0x06], l = v[0x07];
  if (s != null && l != null && (s + l).abs() > 20) a.add('Corrección de mezcla muy alta (${fmt(s + l, dec: 1)} %): posible fuga de vacío o falla de combustible.');
  return a;
}

String mixVerdict(double? st, double? lt) {
  if (st == null && lt == null) return 'Sin datos de mezcla (motor encendido y en lazo cerrado).';
  final t = (st ?? 0) + (lt ?? 0);
  final s = fmt(t, dec: 1);
  if (t.abs() <= 10) return 'Mezcla correcta (corrección total $s %).';
  if (t > 0) {
    return 'Mezcla POBRE: la ECU agrega combustible ($s %). Revisa fugas de vacío, inyectores, filtro/presión de combustible, MAF/MAP.';
  }
  return 'Mezcla RICA: la ECU quita combustible ($s %). Revisa inyectores que gotean, presión de combustible, sensor O2/AF, filtro de aire.';
}

class Panel extends StatelessWidget {
  final String? title;
  final Widget child;
  final Color? accent;
  const Panel({super.key, this.title, required this.child, this.accent});

  @override
  Widget build(BuildContext context) {
    final c = accent ?? kAccent;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: kCard,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: c.withAlpha(50)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (title != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(title!, style: TextStyle(color: c, fontWeight: FontWeight.w800, letterSpacing: 1.1, fontSize: 12)),
          ),
        child,
      ]),
    );
  }
}

class Tile extends StatelessWidget {
  final String label, unit;
  final double? value;
  final int dec;
  final Color? color;
  const Tile(this.label, this.value, this.unit, {super.key, this.dec = 0, this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(color: kTile, borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(color: kMuted, fontSize: 11), maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 4),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Flexible(
              child: Text(fmt(value, dec: dec),
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: value == null ? kMuted : (color ?? Colors.white))),
            ),
            const SizedBox(width: 4),
            Text(unit, style: const TextStyle(color: kMuted, fontSize: 11)),
          ]),
        ]),
      );
}

class TileGrid extends StatelessWidget {
  final List<Widget> items;
  const TileGrid(this.items, {super.key});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (c, box) {
        final w = (box.maxWidth - 8) / 2;
        return Wrap(spacing: 8, runSpacing: 8, children: items.map((t) => SizedBox(width: w, child: t)).toList());
      });
}

class ArcGauge extends StatelessWidget {
  final double value, max, size;
  final String label, unit;
  final Color color;
  const ArcGauge({super.key, required this.value, required this.max, required this.label, required this.unit, required this.color, this.size = 150});

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: Stack(alignment: Alignment.center, children: [
          CustomPaint(size: Size.square(size), painter: _ArcPainter((value / max).clamp(0.0, 1.0), color)),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text(value.toStringAsFixed(0), style: TextStyle(fontSize: size * 0.23, fontWeight: FontWeight.w800)),
            Text(unit, style: const TextStyle(color: kMuted, fontSize: 11)),
            const SizedBox(height: 2),
            Text(label, style: TextStyle(color: color, fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.w700)),
          ]),
        ]),
      );
}

class _ArcPainter extends CustomPainter {
  final double f;
  final Color c;
  _ArcPainter(this.f, this.c);

  @override
  void paint(Canvas canvas, Size s) {
    final rect = Rect.fromLTWH(14, 14, s.width - 28, s.height - 28);
    const start = 3 * math.pi / 4;
    const sweep = 3 * math.pi / 2;
    final bg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..color = const Color(0xFF1B2A52);
    canvas.drawArc(rect, start, sweep, false, bg);
    if (f <= 0) return;
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..strokeCap = StrokeCap.round
      ..color = c.withAlpha(70)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
    final fg = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round
      ..color = c;
    canvas.drawArc(rect, start, sweep * f, false, glow);
    canvas.drawArc(rect, start, sweep * f, false, fg);
  }

  @override
  bool shouldRepaint(_ArcPainter o) => o.f != f || o.c != c;
}

class NotConnected extends StatelessWidget {
  const NotConnected({super.key});
  @override
  Widget build(BuildContext context) => const Panel(
        accent: kWarn,
        child: Text('Sin conexión. Ve a la pestaña «Conexión» para enlazar tu adaptador ELM327.'),
      );
}

void snack(BuildContext c, String m) =>
    ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));

// ───────────────────────── App y navegación ─────────────────────────
class ObdApp extends StatelessWidget {
  const ObdApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'OBD Libre',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          scaffoldBackgroundColor: kBg,
          colorScheme: const ColorScheme.dark(primary: kAccent, secondary: kOrange, surface: kCard),
        ),
        home: const Shell(),
      );
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  static const Map<int, List<int>> watches = {
    1: [0x0C, 0x0D, 0x05, 0x0F, 0x04, 0x11, 0x0B, 0x0E, 0x2F, 0x42, 0x10],
    3: [0x0C, 0x06, 0x07, 0x08, 0x09, 0x24, 0x28, 0x14, 0x15, 0x18, 0x19, 0x3C, 0x3E, 0x3D, 0x3F, 0x0B, 0x33, 0x05],
    4: [0x0C, 0x0D, 0x0B, 0x0F, 0x10, 0x2F, 0x5E, 0x33],
  };

  void _select(int i) {
    setState(() => tab = i);
    session.watch = (watches[i] ?? const <int>[]).toSet();
    session.accum = i == 1 || i == 4;
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      const ConnPage(),
      const LivePage(),
      const DtcPage(),
      const EnginePage(),
      const FuelPage(),
      const MorePage(),
    ];
    return Scaffold(
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text('OBD Libre', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: 1)),
        actions: [
          ListenableBuilder(
            listenable: session,
            builder: (c, _) => Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Row(children: [
                Icon(Icons.circle, size: 10, color: session.connected ? kOk : kBad),
                const SizedBox(width: 6),
                Text(session.connected ? 'En línea' : 'Sin conexión', style: const TextStyle(fontSize: 12, color: kMuted)),
              ]),
            ),
          ),
        ],
      ),
      body: SafeArea(child: pages[tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: _select,
        labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.bluetooth_searching), label: 'Conexión'),
          NavigationDestination(icon: Icon(Icons.speed), label: 'En vivo'),
          NavigationDestination(icon: Icon(Icons.warning_amber_rounded), label: 'Fallas'),
          NavigationDestination(icon: Icon(Icons.precision_manufacturing), label: 'Motor'),
          NavigationDestination(icon: Icon(Icons.local_gas_station), label: 'Consumo'),
          NavigationDestination(icon: Icon(Icons.more_horiz), label: 'Más'),
        ],
      ),
    );
  }
}

// ───────────────────────── Conexión ─────────────────────────
class ConnPage extends StatefulWidget {
  const ConnPage({super.key});
  @override
  State<ConnPage> createState() => _ConnPageState();
}

class _ConnPageState extends State<ConnPage> {
  final host = TextEditingController(text: '192.168.0.10');
  final port = TextEditingController(text: '35000');
  List<Map<String, String>> devices = [];
  String? err;

  Future<void> scan() async {
    try {
      final d = await BtTransport.bonded();
      if (!mounted) return;
      setState(() {
        devices = d;
        err = d.isEmpty ? 'No hay dispositivos emparejados. Empareja el adaptador en Ajustes > Bluetooth (PIN 1234 o 0000).' : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => err = '$e');
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (c, _) {
          final off = session.busy || session.connected;
          return ListView(padding: const EdgeInsets.all(16), children: [
            Panel(
              title: 'ESTADO',
              accent: session.connected ? kOk : kAccent,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(session.status, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                if (session.adapter.isNotEmpty) Text('Adaptador: ${session.adapter}', style: const TextStyle(color: kMuted)),
                if (session.connected) Text('${session.supported.length} sensores soportados por tu auto', style: const TextStyle(color: kMuted)),
                if (session.busy) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
                if (session.connected)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: FilledButton.tonalIcon(onPressed: session.disconnect, icon: const Icon(Icons.link_off), label: const Text('Desconectar')),
                  ),
              ]),
            ),
            Panel(
              title: 'BLUETOOTH (ELM327 clásico)',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('1) Contacto encendido. 2) Empareja el adaptador en Ajustes del teléfono. 3) Búscalo aquí.', style: TextStyle(color: kMuted, fontSize: 13)),
                const SizedBox(height: 10),
                FilledButton.icon(onPressed: off ? null : scan, icon: const Icon(Icons.search), label: const Text('Buscar adaptadores emparejados')),
                if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: kWarn))),
                ...devices.map((d) => ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.bluetooth, color: kAccent),
                      title: Text(d['name'] ?? '?'),
                      subtitle: Text(d['address'] ?? ''),
                      trailing: const Icon(Icons.chevron_right),
                      enabled: !off,
                      onTap: () => session.connectBt(d['address'] ?? ''),
                    )),
              ]),
            ),
            Panel(
              title: 'WIFI (ELM327 WiFi)',
              accent: kOrange,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Conecta el teléfono a la red WiFi del adaptador y mantén la conexión aunque diga «sin internet».', style: TextStyle(color: kMuted, fontSize: 13)),
                const SizedBox(height: 10),
                Row(children: [
                  Expanded(flex: 3, child: TextField(controller: host, decoration: const InputDecoration(labelText: 'IP', border: OutlineInputBorder()))),
                  const SizedBox(width: 8),
                  Expanded(flex: 2, child: TextField(controller: port, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Puerto', border: OutlineInputBorder()))),
                ]),
                const SizedBox(height: 10),
                FilledButton.icon(
                  onPressed: off ? null : () => session.connectWifi(host.text.trim(), int.tryParse(port.text.trim()) ?? 35000),
                  icon: const Icon(Icons.wifi),
                  label: const Text('Conectar por WiFi'),
                ),
              ]),
            ),
          ]);
        },
      );
}

// ───────────────────────── En vivo ─────────────────────────
class LivePage extends StatelessWidget {
  const LivePage({super.key});

  bool has(int p) => session.v.containsKey(p) || session.supported.contains(p);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (c, _) {
          final v = session.v;
          final rpm = v[0x0C] ?? 0, spd = v[0x0D] ?? 0;
          final al = alerts(v);
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (!session.connected) const NotConnected(),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              ArcGauge(value: rpm, max: 8000, label: 'RPM', unit: 'rpm', color: rpm < 5500 ? kAccent : (rpm < 6500 ? kWarn : kBad)),
              ArcGauge(value: spd, max: 220, label: 'VELOCIDAD', unit: 'km/h', color: kOrange),
            ]),
            const SizedBox(height: 12),
            if (al.isNotEmpty)
              Panel(
                title: 'ALERTAS',
                accent: kBad,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: al.map((a) => Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('• $a'))).toList(),
                ),
              ),
            Panel(
              title: 'TEMPERATURAS',
              child: TileGrid([
                Tile('Refrigerante', v[0x05], '°C', color: tempColor(v[0x05])),
                Tile('Aire de admisión', v[0x0F], '°C'),
              ]),
            ),
            Panel(
              title: 'MOTOR',
              accent: kOrange,
              child: TileGrid([
                Tile('Carga', v[0x04], '%'),
                Tile('Acelerador', v[0x11], '%'),
                Tile('MAP', v[0x0B], 'kPa'),
                Tile('Avance', v[0x0E], '°', dec: 1),
                Tile('Voltaje', v[0x42], 'V', dec: 1),
                Tile('Combustible', v[0x2F], '%'),
                if (has(0x10)) Tile('MAF', v[0x10], 'g/s', dec: 1),
              ]),
            ),
          ]);
        },
      );
}

// ───────────────────────── Fallas ─────────────────────────
class DtcPage extends StatefulWidget {
  const DtcPage({super.key});
  @override
  State<DtcPage> createState() => _DtcPageState();
}

class _DtcPageState extends State<DtcPage> {
  bool loading = false, done = false;
  List<String> confirmed = [], pending = [], permanent = [];
  Map<String, String> freeze = {};

  Future<void> run(Future<void> Function() job) async {
    if (!session.connected) {
      snack(context, 'Primero conecta el adaptador');
      return;
    }
    setState(() => loading = true);
    try {
      await job();
    } catch (e) {
      if (mounted) snack(context, 'Error: $e');
    }
    if (mounted) setState(() => loading = false);
  }

  Future<void> read() => run(() async {
        final a = await session.elm.dtcs(3);
        final b = await session.elm.dtcs(7);
        final p = await session.elm.dtcs(10);
        if (!mounted) return;
        setState(() {
          confirmed = a;
          pending = b;
          permanent = p;
          done = true;
        });
      });

  Future<void> clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('¿Borrar códigos?'),
        content: const Text('Se apagará la luz del motor y se borrarán la imagen fija y los monitores. Si la falla sigue, volverá a aparecer.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (ok != true) return;
    await run(() async {
      final r = await session.elm.clearDtcs();
      if (mounted) snack(context, r ? 'Códigos borrados' : 'El auto no confirmó el borrado');
      if (r) {
        setState(() {
          confirmed = [];
          pending = [];
          permanent = [];
          freeze = {};
        });
      }
    });
  }

  Future<void> readFreeze() => run(() async {
        final f = await session.elm.freezeFrame();
        if (!mounted) return;
        setState(() => freeze = f);
        if (f.isEmpty) snack(context, 'No hay imagen fija almacenada');
      });

  Widget codes(String title, List<String> list, Color c) {
    if (!done) return const SizedBox.shrink();
    return Panel(
      title: '$title (${list.length})',
      accent: list.isEmpty ? kOk : c,
      child: list.isEmpty
          ? const Text('Sin códigos', style: TextStyle(color: kMuted))
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: list.map((code) {
                final d = describe(code);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(code, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: c)),
                    Text(d[0], style: const TextStyle(fontWeight: FontWeight.w600)),
                    Text('Revisar: ${d[1]}', style: const TextStyle(color: kMuted, fontSize: 13)),
                  ]),
                );
              }).toList(),
            ),
    );
  }

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(onPressed: loading ? null : read, icon: const Icon(Icons.search), label: const Text('Leer fallas')),
          FilledButton.tonalIcon(onPressed: loading ? null : readFreeze, icon: const Icon(Icons.ac_unit), label: const Text('Imagen fija')),
          OutlinedButton.icon(onPressed: loading ? null : clear, icon: const Icon(Icons.delete_outline), label: const Text('Borrar')),
        ]),
        if (loading) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
        const SizedBox(height: 12),
        if (!session.connected) const NotConnected(),
        codes('CONFIRMADAS', confirmed, kBad),
        codes('PENDIENTES', pending, kWarn),
        codes('PERMANENTES', permanent, kOrange),
        if (freeze.isNotEmpty)
          Panel(
            title: 'IMAGEN FIJA (estado al ocurrir la falla)',
            child: Column(
              children: freeze.entries
                  .map((e) => Padding(
                        padding: const EdgeInsets.symmetric(vertical: 3),
                        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                          Text(e.key, style: const TextStyle(color: kMuted)),
                          Text(e.value, style: const TextStyle(fontWeight: FontWeight.w700)),
                        ]),
                      ))
                  .toList(),
            ),
          ),
      ]);
}

// ───────────────────────── Motor (mezcla, O2, catalizador, cilindros) ─────────────────────────
class EnginePage extends StatefulWidget {
  const EnginePage({super.key});
  @override
  State<EnginePage> createState() => _EnginePageState();
}

class _EnginePageState extends State<EnginePage> {
  bool busy = false;
  List<MapEntry<String, bool>> catRes = [], misRes = [];
  bool testing = false;
  String verdict = '';
  final rpmS = <double>[], mapS = <double>[];
  DateTime? t0;
  late final VoidCallback _l;

  @override
  void initState() {
    super.initState();
    _l = () {
      if (!testing) return;
      final r = session.v[0x0C], m = session.v[0x0B];
      if (r != null && m != null) {
        rpmS.add(r);
        mapS.add(m);
      }
      if (DateTime.now().difference(t0!).inSeconds >= 15) _finish();
    };
    session.addListener(_l);
  }

  @override
  void dispose() {
    session.removeListener(_l);
    super.dispose();
  }

  bool has(int p) => session.v.containsKey(p) || session.supported.contains(p);

  void _start() {
    if (!session.connected) {
      snack(context, 'Primero conecta el adaptador');
      return;
    }
    rpmS.clear();
    mapS.clear();
    t0 = DateTime.now();
    setState(() {
      testing = true;
      verdict = '';
    });
  }

  void _finish() {
    testing = false;
    if (rpmS.length < 8) {
      verdict = 'Muy pocos datos. Verifica que el motor esté encendido y que tu auto reporte RPM y MAP.';
    } else {
      final n = rpmS.length;
      final mr = rpmS.reduce((a, b) => a + b) / n;
      final mm = mapS.reduce((a, b) => a + b) / n;
      final sd = math.sqrt(rpmS.map((x) => (x - mr) * (x - mr)).reduce((a, b) => a + b) / n);
      final baro = session.v[0x33];
      final b = baro ?? 101.0;
      final ratio = (b - mm) / b;
      final lines = <String>['RPM promedio ${mr.toStringAsFixed(0)} · variación ±${sd.toStringAsFixed(0)} rpm'];
      if (mr > 1100) lines.add('El motor no está en ralentí. Repite sin acelerar y con motor caliente.');
      lines.add(sd <= 25
          ? 'Ralentí estable.'
          : (sd <= 60 ? 'Ralentí algo irregular: posible cilindro débil, fuga de vacío o inyector.' : 'Ralentí irregular: revisa encendido, vacío y combustible.'));
      lines.add('Vacío del múltiple: ${(b - mm).toStringAsFixed(0)} kPa (${(ratio * 100).toStringAsFixed(0)} % de la presión barométrica${baro == null ? ', asumida 101 kPa' : ''}).');
      lines.add(ratio >= 0.55
          ? 'Vacío bueno: no hay señales de mal sellado.'
          : (ratio >= 0.40
              ? 'Vacío bajo: posible fuga de vacío, distribución o desgaste.'
              : 'Vacío muy bajo: fuga grande, válvulas o anillos. Confírmalo con prueba de compresión.'));
      lines.add('Es una prueba indicativa; no sustituye el compresómetro.');
      verdict = lines.join('\n');
    }
    if (mounted) setState(() {});
  }

  Future<List<MapEntry<String, bool>>> scan(List<int> mids, String Function(int) label) async {
    final out = <MapEntry<String, bool>>[];
    for (final m in mids) {
      final tests = await session.elm.mode06(m);
      for (final x in tests) {
        out.add(MapEntry('${label(m)} · TID ${h2(x.tid)}: ${x.val}  (mín ${x.min} / máx ${x.max})', x.ok));
      }
    }
    return out;
  }

  Future<void> runScan(bool misfire) async {
    if (!session.connected) {
      snack(context, 'Primero conecta el adaptador');
      return;
    }
    setState(() => busy = true);
    List<MapEntry<String, bool>> r = [];
    try {
      r = misfire
          ? await scan([0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6], (m) => m == 0xA1 ? 'Motor (total)' : 'Cilindro ${m - 0xA1}')
          : await scan([0x21, 0x22], (m) => m == 0x21 ? 'Catalizador B1' : 'Catalizador B2');
    } catch (e) {
      r = [MapEntry('Error: $e', false)];
    }
    if (!mounted) return;
    setState(() {
      busy = false;
      if (misfire) {
        misRes = r;
      } else {
        catRes = r;
      }
    });
  }

  Widget results(List<MapEntry<String, bool>> l, String empty) => l.isEmpty
      ? Text(empty, style: const TextStyle(color: kMuted, fontSize: 13))
      : Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: l.map((e) => Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Text('${e.value ? '✔' : '✖'} ${e.key}', style: TextStyle(color: e.value ? kOk : kBad, fontSize: 13)))).toList(),
        );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (c, _) {
          final v = session.v;
          final o2 = <Widget>[
            if (has(0x24)) Tile('A/F B1S1 (λ)', v[0x24], 'λ', dec: 2),
            if (has(0x28)) Tile('A/F B2S1 (λ)', v[0x28], 'λ', dec: 2),
            if (has(0x14)) Tile('O2 B1S1', v[0x14], 'V', dec: 2),
            if (has(0x15)) Tile('O2 B1S2', v[0x15], 'V', dec: 2),
            if (has(0x18)) Tile('O2 B2S1', v[0x18], 'V', dec: 2),
            if (has(0x19)) Tile('O2 B2S2', v[0x19], 'V', dec: 2),
          ];
          final cat = <Widget>[
            if (has(0x3C)) Tile('Cat B1 entrada', v[0x3C], '°C'),
            if (has(0x3E)) Tile('Cat B1 salida', v[0x3E], '°C'),
            if (has(0x3D)) Tile('Cat B2 entrada', v[0x3D], '°C'),
            if (has(0x3F)) Tile('Cat B2 salida', v[0x3F], '°C'),
          ];
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (!session.connected) const NotConnected(),
            Panel(
              title: 'MEZCLA DE COMBUSTIBLE',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TileGrid([
                  Tile('Corrección corta B1', v[0x06], '%', dec: 1, color: v[0x06] == null ? null : (v[0x06]!.abs() <= 10 ? kOk : (v[0x06]!.abs() <= 20 ? kWarn : kBad))),
                  Tile('Corrección larga B1', v[0x07], '%', dec: 1, color: v[0x07] == null ? null : (v[0x07]!.abs() <= 10 ? kOk : (v[0x07]!.abs() <= 20 ? kWarn : kBad))),
                  if (has(0x08)) Tile('Corrección corta B2', v[0x08], '%', dec: 1),
                  if (has(0x09)) Tile('Corrección larga B2', v[0x09], '%', dec: 1),
                ]),
                const SizedBox(height: 10),
                Text(mixVerdict(v[0x06], v[0x07])),
              ]),
            ),
            Panel(
              title: 'SENSORES DE OXÍGENO / A-F',
              accent: kOrange,
              child: o2.isEmpty ? const Text('Tu auto no reporta estos sensores o aún no hay lectura.', style: TextStyle(color: kMuted)) : TileGrid(o2),
            ),
            Panel(
              title: 'CATALIZADOR',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (cat.isNotEmpty) TileGrid(cat) else const Text('Sin sensores de temperatura de catalizador en este auto.', style: TextStyle(color: kMuted)),
                const SizedBox(height: 8),
                const Text('Catalizador sano: sensor trasero estable (~0.5–0.7 V) mientras el delantero oscila, y la salida más caliente que la entrada.', style: TextStyle(color: kMuted, fontSize: 13)),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(onPressed: busy ? null : () => runScan(false), icon: const Icon(Icons.fact_check), label: const Text('Prueba del monitor (Modo 06)')),
                const SizedBox(height: 6),
                results(catRes, 'Sin resultados todavía.'),
              ]),
            ),
            Panel(
              title: 'COMBUSTIÓN POR CILINDRO',
              accent: kBad,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Lee los contadores de fallos de encendido por cilindro. Algunos Honda no los exponen; si sale vacío, guíate por los códigos P0301–P0304.', style: TextStyle(color: kMuted, fontSize: 13)),
                const SizedBox(height: 8),
                FilledButton.tonalIcon(onPressed: busy ? null : () => runScan(true), icon: const Icon(Icons.hub), label: const Text('Escanear cilindros (Modo 06)')),
                if (busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
                const SizedBox(height: 6),
                results(misRes, 'Sin resultados todavía.'),
              ]),
            ),
            Panel(
              title: 'PRUEBA DE RALENTÍ · SELLADO DEL MOTOR',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('Motor caliente, en ralentí, sin acelerar ni A/C. Dura 15 s.', style: TextStyle(color: kMuted, fontSize: 13)),
                const SizedBox(height: 8),
                FilledButton.icon(onPressed: testing ? null : _start, icon: const Icon(Icons.play_arrow), label: Text(testing ? 'Midiendo…' : 'Iniciar prueba')),
                if (testing) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
                if (verdict.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(verdict)),
              ]),
            ),
          ]);
        },
      );
}

// ───────────────────────── Consumo y gasolina ─────────────────────────
class FuelPage extends StatefulWidget {
  const FuelPage({super.key});
  @override
  State<FuelPage> createState() => _FuelPageState();
}

class _FuelPageState extends State<FuelPage> {
  final disp = TextEditingController(text: session.displacement.toString());
  final tank = TextEditingController(text: session.tank.toString());
  final price = TextEditingController(text: session.price.toString());

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: session,
        builder: (c, _) {
          const gal = 3.78541;
          final lph = session.fuelLph();
          final spd = session.v[0x0D];
          double? kmGal, l100;
          if (lph != null && spd != null && lph > 0.05 && spd > 3) {
            final kmL = spd / lph;
            kmGal = kmL * gal;
            l100 = 100 / kmL;
          }
          final avg = session.tripL > 0.01 ? session.tripKm / session.tripL * gal : null;
          final level = session.v[0x2F];
          final liters = level == null ? null : level / 100 * session.tank;
          final range = (liters != null && session.tripL > 0.05 && session.tripKm > 1) ? liters * (session.tripKm / session.tripL) : null;
          final cost = session.tripL / gal * session.price;
          return ListView(padding: const EdgeInsets.all(16), children: [
            if (!session.connected) const NotConnected(),
            Panel(
              title: 'CONSUMO INSTANTÁNEO',
              accent: kOrange,
              child: TileGrid([
                Tile('Gasto', lph, 'L/h', dec: 2),
                Tile('Rendimiento', kmGal, 'km/gal', dec: 1),
                Tile('Consumo', l100, 'L/100km', dec: 1),
                Tile('Velocidad', spd, 'km/h'),
              ]),
            ),
            Panel(
              title: 'MEDIDOR DE GASOLINA',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: LinearProgressIndicator(
                    value: level == null ? 0 : (level / 100).clamp(0.0, 1.0),
                    minHeight: 22,
                    backgroundColor: kTile,
                    color: level != null && level < 15 ? kBad : kOk,
                  ),
                ),
                const SizedBox(height: 8),
                Text(level == null
                    ? 'Sin dato de nivel (tu auto puede no reportarlo por OBD).'
                    : '${fmt(level)} % · ${fmt(liters, dec: 1)} L · ${fmt(liters == null ? null : liters / gal, dec: 1)} gal'),
                if (range != null) Text('Autonomía estimada: ${fmt(range)} km', style: const TextStyle(color: kOk, fontWeight: FontWeight.w700)),
              ]),
            ),
            Panel(
              title: 'VIAJE',
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                TileGrid([
                  Tile('Distancia', session.tripKm, 'km', dec: 1),
                  Tile('Combustible', session.tripL, 'L', dec: 2),
                  Tile('Promedio', avg, 'km/gal', dec: 1),
                  Tile('Costo', cost, 'Q', dec: 2),
                ]),
                const SizedBox(height: 8),
                OutlinedButton.icon(onPressed: session.resetTrip, icon: const Icon(Icons.restart_alt), label: const Text('Reiniciar viaje')),
                const SizedBox(height: 4),
                const Text('El viaje solo acumula mientras estás en las pestañas En vivo o Consumo.', style: TextStyle(color: kMuted, fontSize: 12)),
              ]),
            ),
            Panel(
              title: 'AJUSTES',
              child: Row(children: [
                Expanded(child: TextField(controller: disp, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Motor (L)', border: OutlineInputBorder()), onChanged: (t) => session.displacement = double.tryParse(t) ?? session.displacement)),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: tank, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Tanque (L)', border: OutlineInputBorder()), onChanged: (t) => session.tank = double.tryParse(t) ?? session.tank)),
                const SizedBox(width: 8),
                Expanded(child: TextField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Q/galón', border: OutlineInputBorder()), onChanged: (t) => session.price = double.tryParse(t) ?? session.price)),
              ]),
            ),
            const Text('El gasto se mide con el PID de consumo, el MAF o, si no existen, se estima con MAP + RPM + temperatura y la cilindrada (error típico ±10–15 %).', style: TextStyle(color: kMuted, fontSize: 12)),
          ]);
        },
      );
}

// ───────────────────────── Más herramientas ─────────────────────────
class MorePage extends StatefulWidget {
  const MorePage({super.key});
  @override
  State<MorePage> createState() => _MorePageState();
}

class _MorePageState extends State<MorePage> {
  final cmd = TextEditingController();
  final log = <String>[];
  String out = '';
  bool busy = false;

  Future<void> run(Future<String> Function() job) async {
    if (!session.connected) {
      snack(context, 'Primero conecta el adaptador');
      return;
    }
    setState(() => busy = true);
    String r;
    try {
      r = await job();
    } catch (e) {
      r = 'Error: $e';
    }
    if (!mounted) return;
    setState(() {
      busy = false;
      out = r;
    });
  }

  Future<void> sendRaw() async {
    final t = cmd.text.trim();
    if (t.isEmpty || !session.connected) return;
    setState(() => busy = true);
    String r;
    try {
      r = (await session.elm.send(t, timeoutMs: 6000)).trim();
    } catch (e) {
      r = 'Error: $e';
    }
    if (!mounted) return;
    setState(() {
      busy = false;
      log.insert(0, '> $t\n$r');
    });
  }

  @override
  Widget build(BuildContext context) => ListView(padding: const EdgeInsets.all(16), children: [
        if (!session.connected) const NotConnected(),
        Panel(
          title: 'DIAGNÓSTICO GENERAL',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              FilledButton.tonal(
                onPressed: busy ? null : () => run(() async => (await session.elm.readiness()).entries.map((e) => '${e.key}: ${e.value}').join('\n')),
                child: const Text('Monitores / MIL'),
              ),
              FilledButton.tonal(
                onPressed: busy ? null : () => run(() async {
                  final v = await session.elm.vin();
                  return v.isEmpty ? 'Tu auto no entregó el VIN por OBD.' : 'VIN: $v';
                }),
                child: const Text('VIN'),
              ),
              FilledButton.tonal(
                onPressed: busy ? null : () => run(() async {
                  final l = session.supported.toList()..sort();
                  return l.isEmpty ? 'Sin lista de sensores.' : l.map((p) => '${h2(p)} ${kPids[p]?.name ?? ''}').join('\n');
                }),
                child: const Text('Sensores soportados'),
              ),
              FilledButton.tonal(
                onPressed: busy ? null : () => run(() async => 'Voltaje del adaptador: ${(await session.elm.send('ATRV')).trim()}'),
                child: const Text('Voltaje batería'),
              ),
            ]),
            if (busy) const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
            if (out.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text(out)),
          ]),
        ),
        const Panel(
          title: 'LO QUE EL OBD-II ESTÁNDAR NO ENTREGA',
          accent: kWarn,
          child: Text(
            '• Posición del volante y presión hidráulica de la dirección: no existen PIDs estándar. En Honda viven en otros módulos (EPS/VSA) con protocolo propietario.\n\n'
            '• Nivel de aceite: no hay sensor estándar. Solo la temperatura de aceite (si el auto la reporta, aparece en «Sensores soportados») y los códigos de presión de aceite como P2646/P2647.\n\n'
            '• Posición del árbol de levas: no hay lectura directa; se vigila con los códigos P0010–P0017 y P0340–P0349 y con el avance de encendido.\n\n'
            '• Compresión real: solo con compresómetro. La prueba de ralentí en la pestaña Motor es indicativa.',
            style: TextStyle(fontSize: 13),
          ),
        ),
        Panel(
          title: 'CONSOLA AVANZADA (comandos ELM / OBD)',
          accent: kOrange,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Ejemplos: 010C · 0902 · ATDP · 2201 (modo 22 propietario, solo para explorar).', style: TextStyle(color: kMuted, fontSize: 12)),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: cmd, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Comando'), onSubmitted: (_) => sendRaw())),
              const SizedBox(width: 8),
              IconButton.filled(onPressed: busy ? null : sendRaw, icon: const Icon(Icons.send)),
            ]),
            const SizedBox(height: 8),
            ...log.take(12).map((l) => Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: kMuted)))),
          ]),
        ),
      ]);
}

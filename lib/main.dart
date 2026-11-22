import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:io';
import 'license.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart' show Printing;
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as pth;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

late Database db;
final tick = ValueNotifier(0);
final clinic = ValueNotifier<String>('العيادة');
final doctor = ValueNotifier<String>('');
final voiceOn = ValueNotifier<bool>(true);
final listening = ValueNotifier<TextEditingController?>(null);
final stt = SpeechToText();
final tts = FlutterTts();
bool sttReady = false, ttsReady = false;
String? arLocale;
final announced = <int>{};

bool micOk(String l) => !['الهاتف', 'السن', 'الرقم', 'رابط', 'مفتاح', 'كود', 'سعر'].any(l.startsWith);

Future<void> speak(String t) async {
  if (!ttsReady) {
    final ok = await tts.isLanguageAvailable('ar-EG');
    await tts.setLanguage(ok == true ? 'ar-EG' : 'ar');
    await tts.setSpeechRate(0.45);
    await tts.setVolume(1.0);
    ttsReady = true;
  }
  await tts.stop();
  await tts.speak(t);
}

Future<void> toggleMic(BuildContext c, TextEditingController ctl) async {
  if (listening.value == ctl) {
    await stt.stop();
    listening.value = null;
    return;
  }
  if (!sttReady) {
    sttReady = await stt.initialize(
        onStatus: (st) {
          if (st == 'done' || st == 'notListening') listening.value = null;
        },
        onError: (_) => listening.value = null);
    if (sttReady) {
      final ar = (await stt.locales()).where((l) => l.localeId.toLowerCase().startsWith('ar')).toList();
      if (ar.isNotEmpty) arLocale = ar.firstWhere((l) => l.localeId.replaceAll('-', '_') == 'ar_EG', orElse: () => ar.first).localeId;
    }
  }
  if (!sttReady) {
    if (c.mounted) toast(c, 'الإدخال الصوتي غير متاح — تأكد من إذن الميكروفون وخدمة التعرف على الكلام');
    return;
  }
  if (listening.value != null) await stt.stop();
  final base = ctl.text.isEmpty ? '' : '${ctl.text} ';
  listening.value = ctl;
  await stt.listen(
      localeId: arLocale,
      pauseFor: const Duration(seconds: 4),
      listenFor: const Duration(seconds: 40),
      listenOptions: SpeechListenOptions(partialResults: true),
      onResult: (r) {
        ctl.text = base + r.recognizedWords;
        ctl.selection = TextSelection.collapsed(offset: ctl.text.length);
      });
}

class MicButton extends StatelessWidget {
  final TextEditingController ctl;
  const MicButton(this.ctl, {super.key});
  @override
  Widget build(BuildContext c) => ValueListenableBuilder<TextEditingController?>(
      valueListenable: listening,
      builder: (_, v, __) => IconButton(
          icon: Icon(v == ctl ? Icons.mic : Icons.mic_none, color: v == ctl ? Colors.red : null),
          onPressed: () => toggleMic(c, ctl)));
}
void refresh() => tick.value++;
typedef DbRow = Map<String, Object?>;
const sts = ['محجوز', 'وصل', 'داخل الكشف', 'انتهى', 'ألغي'];
final fmt = DateFormat('yyyy-MM-dd HH:mm');
String day(DateTime t) => DateFormat('yyyy-MM-dd').format(t);
Future<List<DbRow>> q(String s, [List<Object?> a = const []]) => db.rawQuery(s, a);

const msgsSql = 'CREATE TABLE IF NOT EXISTS msgs(k TEXT PRIMARY KEY,dt TEXT)';
Future<Database> openDb() async => openDatabase(pth.join(await getDatabasesPath(), 'clinic.db'),
    version: 3,
    onCreate: (d, v) async {
      await d.execute('CREATE TABLE patients(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT,phone TEXT,age INTEGER,notes TEXT,uid TEXT,upd INTEGER DEFAULT 0,del INTEGER DEFAULT 0)');
      await d.execute('CREATE TABLE appts(id INTEGER PRIMARY KEY AUTOINCREMENT,pid INTEGER,dt TEXT,status TEXT,reason TEXT,uid TEXT,puid TEXT,fee REAL DEFAULT 0,paid INTEGER DEFAULT 0,upd INTEGER DEFAULT 0,del INTEGER DEFAULT 0)');
      await d.execute('CREATE TABLE records(id INTEGER PRIMARY KEY AUTOINCREMENT,pid INTEGER,dt TEXT,complaint TEXT,diagnosis TEXT,treatment TEXT)');
      await d.execute(msgsSql);
    },
    onUpgrade: (d, o, n) async {
      if (o < 2) await d.execute(msgsSql);
      if (o < 3) {
        for (final s in [
          'ALTER TABLE patients ADD COLUMN uid TEXT',
          'ALTER TABLE patients ADD COLUMN upd INTEGER DEFAULT 0',
          'ALTER TABLE patients ADD COLUMN del INTEGER DEFAULT 0',
          'ALTER TABLE appts ADD COLUMN uid TEXT',
          'ALTER TABLE appts ADD COLUMN puid TEXT',
          'ALTER TABLE appts ADD COLUMN fee REAL DEFAULT 0',
          'ALTER TABLE appts ADD COLUMN paid INTEGER DEFAULT 0',
          'ALTER TABLE appts ADD COLUMN upd INTEGER DEFAULT 0',
          'ALTER TABLE appts ADD COLUMN del INTEGER DEFAULT 0'
        ]) {
          await d.execute(s);
        }
        final now = nowMs();
        for (final t in ['patients', 'appts']) {
          for (final r in await d.query(t, columns: ['id'])) {
            await d.update(t, {'uid': newUid(), 'upd': now}, where: 'id=?', whereArgs: [r['id']]);
          }
        }
        await d.execute('UPDATE appts SET puid=(SELECT uid FROM patients WHERE patients.id=appts.pid)');
      }
    });

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  db = await openDb();
  final sp = await SharedPreferences.getInstance();
  clinic.value = sp.getString('clinic_name') ?? 'العيادة';
  doctor.value = sp.getString('doctor_name') ?? '';
  voiceOn.value = sp.getBool('voice_on') ?? true;
  defFee.value = sp.getDouble('def_fee') ?? 0;
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'عيادة - الاستقبال',
        navigatorKey: navKey,
        debugShowCheckedModeBanner: false,
        locale: const Locale('ar'),
        supportedLocales: const [Locale('ar')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate
        ],
        theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
        home: const LicenseGate(),
      );
}

class Live extends StatelessWidget {
  final Future<Widget> Function() b;
  const Live(this.b, {super.key});
  @override
  Widget build(BuildContext c) => ValueListenableBuilder<int>(
      valueListenable: tick,
      builder: (_, __, ___) => FutureBuilder<Widget>(
          future: b(), builder: (_, s) => s.data ?? const Center(child: CircularProgressIndicator())));
}

class Home extends StatefulWidget {
  const Home({super.key});
  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  int i = 0;
  Timer? tm, st;
  @override
  void initState() {
    super.initState();
    tm = Timer.periodic(const Duration(seconds: 45), (_) => checkUpcoming());
    st = Timer.periodic(const Duration(seconds: 15), (_) => syncNow());
    syncNow();
  }

  @override
  void dispose() {
    tm?.cancel();
    st?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext c) {
    final doc = role.value == 'doctor';
    final tabs = doc
        ? const <Widget>[MonitorTab(), TodayTab(), PatientsTab()]
        : const <Widget>[TodayTab(), ApptsTab(), PatientsTab(), AccountsTab(), MsgTab()];
    final dests = doc
        ? const [
            NavigationDestination(icon: Icon(Icons.monitor_heart), label: 'المتابعة'),
            NavigationDestination(icon: Icon(Icons.today), label: 'اليوم'),
            NavigationDestination(icon: Icon(Icons.people), label: 'المرضى'),
          ]
        : const [
            NavigationDestination(icon: Icon(Icons.today), label: 'اليوم'),
            NavigationDestination(icon: Icon(Icons.event), label: 'المواعيد'),
            NavigationDestination(icon: Icon(Icons.people), label: 'المرضى'),
            NavigationDestination(icon: Icon(Icons.payments), label: 'الحسابات'),
            NavigationDestination(icon: Icon(Icons.sms), label: 'الرسائل'),
          ];
    return Scaffold(
      appBar: AppBar(
        title: ValueListenableBuilder<String>(
            valueListenable: clinic,
            builder: (_, cl, __) => ValueListenableBuilder<String>(
                valueListenable: doctor,
                builder: (_, dr, __) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(cl, style: const TextStyle(fontSize: 18)),
                      Text('${doc ? 'واجهة الطبيب' : 'واجهة التمريض'}${dr.isNotEmpty ? ' • $dr' : ''}', style: const TextStyle(fontSize: 12)),
                    ]))),
        actions: [
          IconButton(icon: const Icon(Icons.lock), onPressed: () => unlocked.value = false),
          IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const SettingsPage()))),
        ],
      ),
      body: tabs[i],
      floatingActionButton: doc
          ? null
          : i <= 1
              ? FloatingActionButton(onPressed: () => addAppt(c), child: const Icon(Icons.add))
              : i == 2
                  ? FloatingActionButton(onPressed: () => addPatient(c), child: const Icon(Icons.person_add))
                  : null,
      bottomNavigationBar: NavigationBar(selectedIndex: i, onDestinationSelected: (v) => setState(() => i = v), destinations: dests),
    );
  }
}

Future<List<String>?> form(BuildContext c, String t, List<String> ls, {List<String>? init}) {
  final cs = [for (var i = 0; i < ls.length; i++) TextEditingController(text: init?[i] ?? '')];
  return showDialog<List<String>>(
      context: c,
      builder: (ctx) => AlertDialog(
            title: Text(t),
            content: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (var i = 0; i < ls.length; i++)
                TextField(controller: cs[i], decoration: InputDecoration(labelText: ls[i], suffixIcon: micOk(ls[i]) ? MicButton(cs[i]) : null))
            ])),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
              FilledButton(onPressed: () => Navigator.pop(ctx, [for (final x in cs) x.text]), child: const Text('حفظ'))
            ],
          ));
}

Future<void> addPatient(BuildContext c) async {
  final v = await form(c, 'مريض جديد', ['الاسم', 'الهاتف', 'السن', 'ملاحظات']);
  if (v == null || v[0].trim().isEmpty) return;
  await db.insert('patients', {'name': v[0].trim(), 'phone': v[1].trim(), 'age': int.tryParse(v[2]), 'notes': v[3], 'uid': newUid(), 'upd': nowMs(), 'del': 0});
  syncSoon();
  refresh();
}

Future<void> addAppt(BuildContext c) => apptForm(c);

Future<void> apptForm(BuildContext c, {DbRow? old}) async {
  final ps = await q('SELECT id,name FROM patients WHERE del=0 ORDER BY name');
  if (!c.mounted) return;
  if (ps.isEmpty) return toast(c, 'أضف مريضًا أولًا');
  int pid = (old?['pid'] as int?) ?? ps.first['id'] as int;
  var dt = old == null ? DateTime.now() : fmt.parse(old['dt'] as String);
  final rc = TextEditingController(text: '${old?['reason'] ?? ''}');
  await showDialog(
      context: c,
      builder: (_) => StatefulBuilder(
          builder: (ctx, set) => AlertDialog(
                title: Text(old == null ? 'موعد جديد' : 'تعديل الموعد'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  DropdownButton<int>(
                      isExpanded: true,
                      value: pid,
                      items: [for (final e in ps) DropdownMenuItem(value: e['id'] as int, child: Text('${e['name']}'))],
                      onChanged: (v) => set(() => pid = v!)),
                  ListTile(
                      title: Text(fmt.format(dt)),
                      trailing: const Icon(Icons.event),
                      onTap: () async {
                        final x = await showDatePicker(context: ctx, initialDate: dt, firstDate: DateTime(2020), lastDate: DateTime(2100));
                        if (x == null || !ctx.mounted) return;
                        final t = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(dt));
                        if (t == null) return;
                        set(() => dt = DateTime(x.year, x.month, x.day, t.hour, t.minute));
                      }),
                  TextField(controller: rc, decoration: InputDecoration(labelText: 'سبب الزيارة', suffixIcon: MicButton(rc))),
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
                  FilledButton(
                      onPressed: () async {
                        final lo = fmt.format(dt.subtract(const Duration(minutes: 14)));
                        final hi = fmt.format(dt.add(const Duration(minutes: 14)));
                        final clash = await q("SELECT a.dt,p.name FROM appts a JOIN patients p ON p.id=a.pid WHERE a.del=0 AND p.del=0 AND a.dt BETWEEN ? AND ? AND a.status!='ألغي' AND a.id!=?", [lo, hi, old?['id'] ?? -1]);
                        if (clash.isNotEmpty) {
                          if (!ctx.mounted) return;
                          final go = await confirm(ctx, 'يوجد موعد في نفس الوقت تقريبًا: ${clash.first['name']} (${clash.first['dt']}). هل تريد الحجز رغم ذلك؟');
                          if (!go) return;
                        }
                        final vals = {'pid': pid, 'dt': fmt.format(dt), 'reason': rc.text};
                        if (old == null) {
                          final pu = await q('SELECT uid FROM patients WHERE id=?', [pid]);
                          await db.insert('appts', {...vals, 'status': 'محجوز', 'uid': newUid(), 'puid': pu.first['uid'], 'fee': defFee.value, 'paid': 0, 'upd': nowMs(), 'del': 0});
                          syncSoon();
                        } else {
                          final pu = await q('SELECT uid FROM patients WHERE id=?', [pid]);
                          await touch('appts', {...vals, 'puid': pu.first['uid']}, old['id'] as int);
                          if (old['dt'] != vals['dt']) await db.delete('msgs', where: 'k=?', whereArgs: ['r${old['id']}']);
                        }
                        refresh();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('حفظ'))
                ],
              )));
}

Widget apptTile(BuildContext c, DbRow a) => Card(
        child: ListTile(
      title: Text('${a['name']}'),
      subtitle: Text('${a['dt']} • ${a['reason'] ?? ''}\n${a['paid'] == 1 ? '✓ مسدد' : 'لم يسدد'} • ${money((a['fee'] as num?) ?? 0)}'),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            await touch('appts', {'status': v}, a['id'] as int);
            refresh();
            if (v == 'انتهى' && role.value == 'nurse') await callNext(c, finished: '${a['name']}');
          },
          itemBuilder: (_) => [for (final s in sts) PopupMenuItem(value: s, child: Text(s))],
          child: Chip(label: Text('${a['status']}'))),
      onTap: () => apptForm(c, old: a),
      onLongPress: () async {
        if (!await confirm(c, 'حذف هذا الموعد؟')) return;
        await touch('appts', {'del': 1}, a['id'] as int);
        refresh();
      },
    ));

class TodayTab extends StatelessWidget {
  const TodayTab({super.key});
  @override
  Widget build(BuildContext c) => Live(() async {
        final r = await q('SELECT a.*,p.name,p.phone FROM appts a JOIN patients p ON p.id=a.pid WHERE a.del=0 AND p.del=0 AND a.dt LIKE ? ORDER BY a.dt', ['${day(DateTime.now())}%']);
        if (r.isEmpty) return const Center(child: Text('لا مواعيد اليوم'));
        return ListView(children: [
          if (role.value == 'nurse')
            Padding(
              padding: const EdgeInsets.all(8),
              child: FilledButton.icon(icon: const Icon(Icons.campaign), label: const Text('نداء المريض التالي'), onPressed: () => callNext(c))),
          for (final a in r) apptTile(c, a)
        ]);
      });
}

class ApptsTab extends StatelessWidget {
  const ApptsTab({super.key});
  @override
  Widget build(BuildContext c) => Live(() async {
        final r = await q('SELECT a.*,p.name,p.phone FROM appts a JOIN patients p ON p.id=a.pid WHERE a.del=0 AND p.del=0 AND a.dt >= ? ORDER BY a.dt', [day(DateTime.now())]);
        if (r.isEmpty) return const Center(child: Text('لا مواعيد قادمة'));
        return ListView(children: [for (final a in r) apptTile(c, a)]);
      });
}

class PatientsTab extends StatefulWidget {
  const PatientsTab({super.key});
  @override
  State<PatientsTab> createState() => _PatientsTabState();
}

class _PatientsTabState extends State<PatientsTab> {
  String s = '';
  final sc = TextEditingController();
  @override
  void initState() {
    super.initState();
    sc.addListener(() => setState(() => s = sc.text));
  }

  @override
  Widget build(BuildContext c) => Column(children: [
        Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
                controller: sc,
                decoration: InputDecoration(prefixIcon: const Icon(Icons.search), suffixIcon: MicButton(sc), hintText: 'بحث بالاسم أو الهاتف', border: const OutlineInputBorder()))),
        Expanded(
            child: Live(() async {
          final r = await q('SELECT * FROM patients WHERE del=0 AND (name LIKE ? OR phone LIKE ?) ORDER BY name', ['%$s%', '%$s%']);
          return ListView(children: [
            for (final p in r)
              ListTile(
                  leading: const CircleAvatar(child: Icon(Icons.person)),
                  title: Text('${p['name']}'),
                  subtitle: Text('${p['phone']}'),
                  onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => PatientPage(p))))
          ]);
        }))
      ]);
}

class PatientPage extends StatelessWidget {
  final DbRow p;
  const PatientPage(this.p, {super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
        appBar: AppBar(title: Text('${p['name']}'), actions: [
          IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () async {
                final v = await form(c, 'تعديل بيانات المريض', ['الاسم', 'الهاتف', 'السن', 'ملاحظات'],
                    init: ['${p['name']}', '${p['phone'] ?? ''}', '${p['age'] ?? ''}', '${p['notes'] ?? ''}']);
                if (v == null || v[0].trim().isEmpty) return;
                await touch('patients', {'name': v[0].trim(), 'phone': v[1].trim(), 'age': int.tryParse(v[2]), 'notes': v[3]}, p['id'] as int);
                refresh();
                if (c.mounted) Navigator.pop(c);
              }),
          if (role.value == 'doctor')
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () async {
                if (!await confirm(c, 'حذف المريض وكل مواعيده وسجلاته؟')) return;
                await db.update('appts', {'del': 1, 'upd': nowMs()}, where: 'pid=?', whereArgs: [p['id']]);
                await db.delete('records', where: 'pid=?', whereArgs: [p['id']]);
                await touch('patients', {'del': 1}, p['id'] as int);
                refresh();
                if (c.mounted) Navigator.pop(c);
              }),
        ]),
        floatingActionButton: role.value != 'doctor' ? null : FloatingActionButton.extended(
            icon: const Icon(Icons.note_add),
            label: const Text('كشف جديد'),
            onPressed: () async {
              final v = await form(c, 'سجل كشف', ['الشكوى', 'التشخيص', 'العلاج / الأدوية']);
              if (v == null) return;
              await db.insert('records', {'pid': p['id'], 'dt': day(DateTime.now()), 'complaint': v[0], 'diagnosis': v[1], 'treatment': v[2]});
              refresh();
            }),
        body: Live(() async {
          final r = await q('SELECT * FROM records WHERE pid=? ORDER BY id DESC', [p['id']]);
          return ListView(children: [
            ListTile(title: Text('${p['phone']} • السن: ${p['age'] ?? '-'}'), subtitle: Text('${p['notes'] ?? ''}')),
            const Divider(),
            if (role.value == 'doctor')
              for (final x in r)
              Card(
                  child: ListTile(
                      title: Text('${x['dt']} — ${x['diagnosis']}'),
                      subtitle: Text('الشكوى: ${x['complaint']}\nالعلاج: ${x['treatment']}'),
                      isThreeLine: true,
                      onLongPress: () async {
                        if (!await confirm(c, 'حذف هذا السجل؟')) return;
                        await db.delete('records', where: 'id=?', whereArgs: [x['id']]);
                        refresh();
                      }))
          ]);
        }),
      );
}

Future<void> sms(String ph, String body) => launchUrl(Uri.parse('sms:$ph?body=${Uri.encodeComponent(body)}'));
Future<void> wa(String ph, String body) {
  var n = ph.replaceAll(RegExp(r'\D'), '');
  if (n.startsWith('0')) n = '20${n.substring(1)}';
  return launchUrl(Uri.parse('https://wa.me/$n?text=${Uri.encodeComponent(body)}'), mode: LaunchMode.externalApplication);
}

Future<void> mark(String k) async {
  await db.insert('msgs', {'k': k, 'dt': fmt.format(DateTime.now())}, conflictAlgorithm: ConflictAlgorithm.replace);
  refresh();
}

Widget sendTile(String t, String sub, String ph, String body, String key, bool sent) => Card(
        child: ListTile(
      leading: Icon(sent ? Icons.check_circle : Icons.circle_outlined, color: sent ? Colors.green : null),
      title: Text(t),
      subtitle: Text(sub),
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(icon: const Icon(Icons.sms), onPressed: () { mark(key); sms(ph, body); }),
        IconButton(icon: const Icon(Icons.chat), onPressed: () { mark(key); wa(ph, body); }),
      ]),
    ));

class MsgTab extends StatelessWidget {
  const MsgTab({super.key});
  @override
  Widget build(BuildContext c) => Live(() async {
        final tm = day(DateTime.now().add(const Duration(days: 1)));
        final wk = day(DateTime.now().subtract(const Duration(days: 7)));
        final a = await q("SELECT a.*,p.name,p.phone FROM appts a JOIN patients p ON p.id=a.pid WHERE a.del=0 AND p.del=0 AND a.dt LIKE ? AND a.status='محجوز' ORDER BY a.dt", ['$tm%']);
        final r = await q('SELECT r.*,p.name,p.phone FROM records r JOIN patients p ON p.id=r.pid WHERE p.del=0 AND r.dt >= ? ORDER BY r.id DESC', [wk]);
        final sent = (await q('SELECT k FROM msgs')).map((e) => e['k']).toSet();
        return ListView(padding: const EdgeInsets.all(8), children: [
          const Text('تذكير بمواعيد الغد', style: TextStyle(fontWeight: FontWeight.bold)),
          if (a.isEmpty) const ListTile(title: Text('لا مواعيد غدًا')),
          for (final x in a)
            sendTile('${x['name']}', '${x['dt']}', '${x['phone']}',
                'مرحبًا ${x['name']}، نذكّرك بموعدك غدًا الساعة ${(x['dt'] as String).substring(11, 16)} في ${clinic.value}. نرجو الالتزام بالموعد.',
                'r${x['id']}', sent.contains('r${x['id']}')),
          const SizedBox(height: 16),
          const Text('متابعة الالتزام بالعلاج (آخر 7 أيام)', style: TextStyle(fontWeight: FontWeight.bold)),
          if (r.isEmpty) const ListTile(title: Text('لا كشوفات حديثة')),
          for (final x in r)
            sendTile('${x['name']}', '${x['dt']}${role.value == 'doctor' ? ' — ${x['treatment']}' : ''}', '${x['phone']}',
                'مرحبًا ${x['name']}، نطمئن على حالتك. هل تلتزم بالعلاج الموصوف${role.value == 'doctor' ? ' (${x['treatment']})' : ''}؟ برجاء إبلاغنا بأي أعراض.',
                'f${x['id']}', sent.contains('f${x['id']}')),
        ]);
      });
}

Future<bool> confirm(BuildContext c, String msg) async =>
    await showDialog<bool>(
        context: c,
        builder: (ctx) => AlertDialog(content: Text(msg), actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تأكيد'))
            ])) ??
    false;

void toast(BuildContext c, String m) {
  if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(m)));
}

class LockGate extends StatefulWidget {
  const LockGate({super.key});
  @override
  State<LockGate> createState() => _LockGateState();
}

class _LockGateState extends State<LockGate> {
  String? pn, pd;
  bool loaded = false;
  String err = '';
  final c = TextEditingController(), c2 = TextEditingController();
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    pn = p.getString('pin_nurse') ?? p.getString('pin');
    pd = p.getString('pin_doctor');
    if (pn != null && p.getString('pin_nurse') == null) await p.setString('pin_nurse', pn!);
    setState(() => loaded = true);
  }

  Future<void> submit() async {
    final p = await SharedPreferences.getInstance();
    if (pn == null || pd == null) {
      final n = pn ?? c.text, d = pd ?? c2.text;
      if (n.length < 4 || d.length < 4) return setState(() => err = 'كل رقم سري 4 أرقام على الأقل');
      if (n == d) return setState(() => err = 'يجب أن يختلف رقم الطبيب عن رقم الممرض');
      await p.setString('pin_nurse', n);
      await p.setString('pin_doctor', d);
      c.clear();
      c2.clear();
      setState(() {
        pn = n;
        pd = d;
        err = '';
      });
      return;
    }
    final v = c.text;
    if (v == pd) {
      role.value = 'doctor';
    } else if (v == pn) {
      role.value = 'nurse';
    } else {
      c.clear();
      return setState(() => err = 'رقم سري خاطئ');
    }
    c.clear();
    setState(() => err = '');
    unlocked.value = true;
  }

  @override
  Widget build(BuildContext ctx) {
    if (!loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    return ValueListenableBuilder<bool>(valueListenable: unlocked, builder: (_, u, __) => u ? const Home() : lockUi());
  }

  Widget lockUi() {
    final setup = pn == null || pd == null;
    return Scaffold(
        body: Center(
            child: SingleChildScrollView(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.lock, size: 64),
                  const SizedBox(height: 12),
                  Text(setup ? 'إعداد الأرقام السرية' : 'أدخل الرقم السري'),
                  if (!setup || pn == null)
                    TextField(controller: c, obscureText: true, keyboardType: TextInputType.number, textAlign: TextAlign.center, decoration: InputDecoration(labelText: setup ? 'الرقم السري للممرض' : null), onSubmitted: (_) => submit()),
                  if (setup && pd == null)
                    TextField(controller: c2, obscureText: true, keyboardType: TextInputType.number, textAlign: TextAlign.center, decoration: const InputDecoration(labelText: 'الرقم السري للطبيب'), onSubmitted: (_) => submit()),
                  if (err.isNotEmpty) Text(err, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: submit, child: Text(setup ? 'حفظ' : 'دخول')),
                ]))));
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext c) {
    final doc = role.value == 'doctor';
    return Scaffold(
        appBar: AppBar(title: const Text('الإعدادات')),
        body: ListView(children: [
          ValueListenableBuilder<bool>(
              valueListenable: voiceOn,
              builder: (_, v, __) => SwitchListTile(
                  secondary: const Icon(Icons.volume_up),
                  title: const Text('التنبيهات الصوتية'),
                  subtitle: const Text('نداء المريض التالي وتنبيه المواعيد القريبة'),
                  value: v,
                  onChanged: (x) async {
                    voiceOn.value = x;
                    (await SharedPreferences.getInstance()).setBool('voice_on', x);
                  })),
          ListTile(leading: const Icon(Icons.record_voice_over), title: const Text('تجربة الصوت'), onTap: () => speak('تجربة التنبيه الصوتي. المريض التالي، يرجى الاستعداد')),
          ValueListenableBuilder<String>(
              valueListenable: syncMsg,
              builder: (_, m, __) => ListTile(
                  leading: const Icon(Icons.cloud_sync),
                  title: const Text('حالة المزامنة'),
                  subtitle: Text(m),
                  trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: syncNow))),
          if (doc) ...[
            ListTile(
                leading: const Icon(Icons.lock),
                title: const Text('تغيير الأرقام السرية'),
                onTap: () async {
                  final v = await form(c, 'أرقام سرية جديدة', ['الرقم السري للممرض', 'الرقم السري للطبيب']);
                  if (v == null) return;
                  if (v[0].length < 4 || v[1].length < 4 || v[0] == v[1]) return toast(c, 'أرقام غير صالحة: 4 أرقام على الأقل ومختلفة');
                  final sp = await SharedPreferences.getInstance();
                  await sp.setString('pin_nurse', v[0]);
                  await sp.setString('pin_doctor', v[1]);
                  toast(c, 'تم تغيير الأرقام السرية');
                }),
            ListTile(
                leading: const Icon(Icons.local_hospital),
                title: const Text('اسم العيادة والطبيب'),
                onTap: () async {
                  final v = await form(c, 'بيانات العيادة', ['اسم العيادة', 'اسم الطبيب'], init: [clinic.value, doctor.value]);
                  if (v == null) return;
                  final sp = await SharedPreferences.getInstance();
                  final cn = v[0].trim().isEmpty ? 'العيادة' : v[0].trim();
                  await sp.setString('clinic_name', cn);
                  await sp.setString('doctor_name', v[1].trim());
                  clinic.value = cn;
                  doctor.value = v[1].trim();
                }),
            ListTile(
                leading: const Icon(Icons.payments),
                title: const Text('سعر الكشف الافتراضي'),
                subtitle: ValueListenableBuilder<double>(valueListenable: defFee, builder: (_, v, __) => Text(money(v))),
                onTap: () async {
                  final v = await form(c, 'سعر الكشف', ['سعر الكشف (جنيه)'], init: [defFee.value.toStringAsFixed(0)]);
                  if (v == null) return;
                  defFee.value = toNum(v[0]) ?? 0;
                  (await SharedPreferences.getInstance()).setDouble('def_fee', defFee.value);
                }),
            ListTile(
                leading: const Icon(Icons.cloud),
                title: const Text('إعداد المزامنة السحابية'),
                onTap: () async {
                  final sp = await SharedPreferences.getInstance();
                  if (!c.mounted) return;
                  final v = await form(c, 'المزامنة (Supabase)', ['رابط المشروع', 'مفتاح anon', 'كود العيادة (16 حرفًا فأكثر)'],
                      init: [sp.getString('sb_url') ?? '', sp.getString('sb_key') ?? '', sp.getString('clinic_code') ?? newUid()]);
                  if (v == null) return;
                  await sp.setString('sb_url', v[0].trim());
                  await sp.setString('sb_key', v[1].trim());
                  await sp.setString('clinic_code', v[2].trim());
                  for (final k in ['pull_patients', 'pull_appts', 'push_patients', 'push_appts']) {
                    await sp.remove(k);
                  }
                  syncNow();
                }),
            ListTile(leading: const Icon(Icons.backup), title: const Text('نسخة احتياطية (مشاركة الملف)'), onTap: () => backup(c)),
            ListTile(leading: const Icon(Icons.restore), title: const Text('استعادة نسخة احتياطية'), onTap: () => restore(c)),
          ],
        ]));
  }
}

Future<void> backup(BuildContext c) async {
  await db.rawQuery('PRAGMA wal_checkpoint(FULL)');
  await Share.shareXFiles([XFile(db.path, name: 'clinic_backup_${day(DateTime.now())}.db')]);
}

Future<void> restore(BuildContext c) async {
  final r = await FilePicker.platform.pickFiles();
  final src = r?.files.single.path;
  if (src == null || !c.mounted) return;
  final h = await File(src).openRead(0, 15).first;
  if (String.fromCharCodes(h) != 'SQLite format 3') return toast(c, 'الملف ليس نسخة صالحة');
  if (!c.mounted || !await confirm(c, 'سيتم استبدال كل البيانات الحالية بالنسخة المختارة. متابعة؟')) return;
  final dest = db.path;
  await db.close();
  for (final e in ['-wal', '-shm', '-journal']) {
    final f = File('$dest$e');
    if (await f.exists()) await f.delete();
  }
  await File(src).copy(dest);
  db = await openDb();
  final sp = await SharedPreferences.getInstance();
  for (final k in ['pull_patients', 'pull_appts', 'push_patients', 'push_appts']) {
    await sp.remove(k);
  }
  refresh();
  toast(c, 'تمت الاستعادة');
}

Future<void> checkUpcoming() async {
  if (!voiceOn.value || role.value != 'nurse') return;
  final now = DateTime.now();
  final r = await q("SELECT a.id,a.dt,p.name FROM appts a JOIN patients p ON p.id=a.pid WHERE a.del=0 AND p.del=0 AND a.dt LIKE ? AND a.status='محجوز'", ['${day(now)}%']);
  for (final a in r) {
    final id = a['id'] as int;
    if (announced.contains(id)) continue;
    final mins = fmt.parse(a['dt'] as String).difference(now).inMinutes;
    if (mins >= 0 && mins <= 10) {
      announced.add(id);
      await speak(mins == 0 ? 'تنبيه، حان الآن موعد ${a['name']}' : 'تنبيه، موعد ${a['name']} بعد $mins دقائق');
      return;
    }
  }
}

Future<DbRow?> nextPatient() async {
  final r = await q("SELECT a.*,p.name,p.phone FROM appts a JOIN patients p ON p.id=a.pid WHERE a.del=0 AND p.del=0 AND a.dt LIKE ? AND a.status IN ('وصل','محجوز') ORDER BY CASE a.status WHEN 'وصل' THEN 0 ELSE 1 END, a.dt LIMIT 1", ['${day(DateTime.now())}%']);
  return r.isEmpty ? null : r.first;
}

Future<void> callNext(BuildContext c, {String? finished}) async {
  final n = await nextPatient();
  if (!c.mounted) return;
  final done = finished == null ? '' : 'انتهى الكشف على $finished. ';
  if (n == null) {
    if (finished != null && voiceOn.value) speak('${done}لا يوجد مرضى آخرون في الانتظار');
    return toast(c, 'لا يوجد مريض تالٍ');
  }
  final text = '${done}المريض التالي ${n['name']}. يرجى الاستعداد للدخول.';
  final msg = 'مرحبًا ${n['name']}، دورك قريب في ${clinic.value}. برجاء الاستعداد للدخول.';
  final ph = '${n['phone']}';
  if (voiceOn.value) speak(text);
  await showModalBottomSheet(
      context: c,
      builder: (ctx) => Padding(
          padding: const EdgeInsets.all(16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('المريض التالي'),
            Text('${n['name']}', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
            Text('${n['dt']} • ${n['status']}'),
            const SizedBox(height: 12),
            Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
              FilledButton.icon(icon: const Icon(Icons.volume_up), label: const Text('نداء صوتي'), onPressed: () => speak(text)),
              OutlinedButton.icon(icon: const Icon(Icons.call), label: const Text('اتصال'), onPressed: () => launchUrl(Uri.parse('tel:$ph'))),
              OutlinedButton.icon(icon: const Icon(Icons.sms), label: const Text('SMS'), onPressed: () => sms(ph, msg)),
              OutlinedButton.icon(icon: const Icon(Icons.chat), label: const Text('واتساب'), onPressed: () => wa(ph, msg)),
              FilledButton.tonalIcon(
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('بدء الكشف'),
                  onPressed: () async {
                    await touch('appts', {'status': 'داخل الكشف'}, n['id'] as int);
                    refresh();
                    if (ctx.mounted) Navigator.pop(ctx);
                  }),
            ])
          ])));
}

// ================= الأدوار والمزامنة =================
final unlocked = ValueNotifier<bool>(false);
final role = ValueNotifier<String>('nurse');
final navKey = GlobalKey<NavigatorState>();
final defFee = ValueNotifier<double>(0);
final syncMsg = ValueNotifier<String>('المزامنة غير مفعلة');
bool syncing = false;
Timer? syncDebounce;

int nowMs() => DateTime.now().millisecondsSinceEpoch;
String newUid() {
  final r = Random.secure();
  return List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
}

Future<void> touch(String t, Map<String, Object?> v, int id) async {
  await db.update(t, {...v, 'upd': nowMs()}, where: 'id=?', whereArgs: [id]);
  syncSoon();
}

double? toNum(String s) {
  const a = '٠١٢٣٤٥٦٧٨٩';
  var t = s;
  for (var i = 0; i < 10; i++) {
    t = t.replaceAll(a[i], '$i');
  }
  return double.tryParse(t.trim());
}

String money(num v) => '${v.toStringAsFixed(0)} جنيه';

Future<Map<String, String>?> syncCfg() async {
  final p = await SharedPreferences.getInstance();
  final u = (p.getString('sb_url') ?? '').trim(), k = (p.getString('sb_key') ?? '').trim(), c = (p.getString('clinic_code') ?? '').trim();
  if (u.isEmpty || k.isEmpty || c.length < 16) return null;
  return {'u': u.endsWith('/') ? u.substring(0, u.length - 1) : u, 'k': k, 'c': c};
}

void syncSoon() {
  syncDebounce?.cancel();
  syncDebounce = Timer(const Duration(seconds: 2), syncNow);
}

Map<String, Object?> cols(String t, DbRow r) => {
      for (final k in (t == 'patients' ? ['uid', 'name', 'phone', 'age', 'notes', 'upd', 'del'] : ['uid', 'puid', 'dt', 'status', 'reason', 'fee', 'paid', 'upd', 'del'])) k: r[k]
    };

Future<void> applyRemote(String t, Map<String, dynamic> m, List<String> finished) async {
  final ex = await db.query(t, where: 'uid=?', whereArgs: [m['uid']]);
  if (ex.isNotEmpty && (ex.first['upd'] as int) >= (m['upd'] as int)) return;
  if (t == 'patients') {
    final v = {'name': m['name'], 'phone': m['phone'], 'age': m['age'], 'notes': m['notes'], 'upd': m['upd'], 'del': m['del'] ?? 0};
    if (ex.isEmpty) {
      await db.insert(t, {...v, 'uid': m['uid']});
    } else {
      await db.update(t, v, where: 'uid=?', whereArgs: [m['uid']]);
    }
    return;
  }
  final pr = await db.query('patients', columns: ['id', 'name'], where: 'uid=?', whereArgs: [m['puid']]);
  if (pr.isEmpty) return;
  final v = {
    'pid': pr.first['id'],
    'puid': m['puid'],
    'dt': m['dt'],
    'status': m['status'],
    'reason': m['reason'],
    'fee': (m['fee'] as num?)?.toDouble() ?? 0,
    'paid': m['paid'] ?? 0,
    'upd': m['upd'],
    'del': m['del'] ?? 0
  };
  final oldStatus = ex.isEmpty ? null : ex.first['status'];
  if (ex.isEmpty) {
    await db.insert(t, {...v, 'uid': m['uid']});
  } else {
    await db.update(t, v, where: 'uid=?', whereArgs: [m['uid']]);
    if (m['status'] == 'انتهى' && oldStatus != 'انتهى' && (m['del'] ?? 0) == 0 && '${m['dt']}'.startsWith(day(DateTime.now()))) {
      finished.add('${pr.first['name']}');
    }
  }
}

Future<void> syncNow() async {
  if (syncing) return;
  final cfg = await syncCfg();
  if (cfg == null) {
    syncMsg.value = 'المزامنة غير مفعلة';
    return;
  }
  syncing = true;
  try {
    final p = await SharedPreferences.getInstance();
    final h = {'apikey': cfg['k']!, 'Authorization': 'Bearer ${cfg['k']}', 'x-clinic': cfg['c']!, 'Content-Type': 'application/json'};
    final base = '${cfg['u']}/rest/v1';
    final finished = <String>[];
    var changed = false;
    for (final t in ['patients', 'appts']) {
      final lp = p.getInt('pull_$t') ?? 0;
      final res = await http.get(Uri.parse('$base/$t?clinic=eq.${cfg['c']}&upd=gt.$lp&order=upd.asc&limit=1000'), headers: h).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) throw 'HTTP ${res.statusCode}';
      var maxU = lp;
      for (final r in jsonDecode(res.body) as List) {
        final m = r as Map<String, dynamic>;
        if ((m['upd'] as int) > maxU) maxU = m['upd'] as int;
        await applyRemote(t, m, finished);
        changed = true;
      }
      await p.setInt('pull_$t', maxU);
    }
    for (final t in ['patients', 'appts']) {
      final lp = p.getInt('push_$t') ?? 0;
      final rows = await db.query(t, where: 'upd > ?', whereArgs: [lp], orderBy: 'upd ASC');
      if (rows.isEmpty) continue;
      final body = [for (final r in rows) {...cols(t, r), 'clinic': cfg['c']}];
      final res = await http
          .post(Uri.parse('$base/$t?on_conflict=clinic,uid'), headers: {...h, 'Prefer': 'resolution=merge-duplicates,return=minimal'}, body: jsonEncode(body))
          .timeout(const Duration(seconds: 30));
      if (res.statusCode >= 300) throw 'HTTP ${res.statusCode}';
      await p.setInt('push_$t', rows.last['upd'] as int);
    }
    syncMsg.value = 'آخر مزامنة: ${DateFormat('HH:mm:ss').format(DateTime.now())}';
    if (changed) refresh();
    if (role.value == 'nurse' && finished.isNotEmpty) {
      final c = navKey.currentContext;
      if (c != null && c.mounted) await callNext(c, finished: finished.last);
    }
  } catch (e) {
    syncMsg.value = 'تعذرت المزامنة (ستُعاد المحاولة): $e';
  } finally {
    syncing = false;
  }
}

// ================= الحسابات =================
Widget summary(List<DbRow> r) {
  double ps = 0, ds = 0;
  int pc = 0, dc = 0;
  for (final a in r) {
    final f = ((a['fee'] as num?) ?? 0).toDouble();
    if (a['paid'] == 1) {
      ps += f;
      pc++;
    } else {
      ds += f;
      dc++;
    }
  }
  Widget col(String t, int n, double v, Color k) => Expanded(
      child: Column(children: [
        Text(t),
        Text(money(v), style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: k)),
        Text('$n كشف', style: const TextStyle(fontSize: 12))
      ]));
  return Card(
      child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(children: [
            Text('الإجمالي: ${money(ps + ds)}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(children: [col('المسدد', pc, ps, Colors.green), col('غير المسدد', dc, ds, Colors.red)]),
          ])));
}

Widget accountTile(BuildContext c, DbRow a, bool edit) {
  final paid = a['paid'] == 1;
  return Card(
      child: ListTile(
    title: Text('${a['name']}'),
    subtitle: Text('${(a['dt'] as String).substring(11, 16)} • ${a['status']}'),
    trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text(money((a['fee'] as num?) ?? 0), style: const TextStyle(fontWeight: FontWeight.bold)),
      Text(paid ? 'مسدد ✓' : 'لم يسدد', style: TextStyle(color: paid ? Colors.green : Colors.red)),
    ]),
    onTap: edit ? () => feeForm(c, a) : null,
  ));
}

Future<void> feeForm(BuildContext c, DbRow a) async {
  final fc = TextEditingController(text: ((a['fee'] as num?) ?? 0).toStringAsFixed(0));
  var paid = a['paid'] == 1;
  await showDialog(
      context: c,
      builder: (_) => StatefulBuilder(
          builder: (ctx, set) => AlertDialog(
                title: Text('${a['name']}'),
                content: Column(mainAxisSize: MainAxisSize.min, children: [
                  TextField(controller: fc, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'المبلغ (جنيه)')),
                  SwitchListTile(title: const Text('تم السداد'), value: paid, onChanged: (v) => set(() => paid = v)),
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
                  FilledButton(
                      onPressed: () async {
                        await touch('appts', {'fee': toNum(fc.text) ?? 0, 'paid': paid ? 1 : 0}, a['id'] as int);
                        refresh();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('حفظ'))
                ],
              )));
}

class AccountsTab extends StatefulWidget {
  const AccountsTab({super.key});
  @override
  State<AccountsTab> createState() => _AccountsTabState();
}

class _AccountsTabState extends State<AccountsTab> {
  DateTime d = DateTime.now();
  @override
  Widget build(BuildContext c) => Live(() async {
        final r = await q("SELECT a.*,p.name FROM appts a JOIN patients p ON p.id=a.pid WHERE a.del=0 AND p.del=0 AND a.dt LIKE ? AND a.status!='ألغي' ORDER BY a.dt", ['${day(d)}%']);
        return ListView(padding: const EdgeInsets.all(8), children: [
          ListTile(
              title: Text('حسابات يوم ${day(d)}'),
              trailing: const Icon(Icons.calendar_month),
              onTap: () async {
                final x = await showDatePicker(context: c, initialDate: d, firstDate: DateTime(2020), lastDate: DateTime(2100));
                if (x != null) setState(() => d = x);
              }),
          summary(r),
          Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: FilledButton.tonalIcon(icon: const Icon(Icons.picture_as_pdf), label: const Text('تقرير الحسابات PDF'), onPressed: () => accountsPdf(c, d))),
          if (r.isEmpty) const ListTile(title: Text('لا كشوفات في هذا اليوم')),
          for (final a in r) accountTile(c, a, true),
        ]);
      });
}

Widget stat(String t, int v, Color col) => Expanded(
    child: Card(
        child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(children: [
              Text('$v', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: col)),
              Text(t, style: const TextStyle(fontSize: 12), textAlign: TextAlign.center),
            ]))));

class MonitorTab extends StatelessWidget {
  const MonitorTab({super.key});
  @override
  Widget build(BuildContext c) => Live(() async {
        final r = await q("SELECT a.*,p.name FROM appts a JOIN patients p ON p.id=a.pid WHERE a.del=0 AND p.del=0 AND a.dt LIKE ? ORDER BY a.dt", ['${day(DateTime.now())}%']);
        int n(String s) => r.where((a) => a['status'] == s).length;
        final live = r.where((a) => a['status'] != 'ألغي').toList();
        return ListView(padding: const EdgeInsets.all(8), children: [
          ValueListenableBuilder<String>(
              valueListenable: syncMsg,
              builder: (_, m, __) => ListTile(dense: true, leading: const Icon(Icons.cloud_sync), title: Text(m), trailing: IconButton(icon: const Icon(Icons.refresh), onPressed: syncNow))),
          Row(children: [
            stat('في الانتظار', n('وصل'), Colors.orange),
            stat('لم يصلوا بعد', n('محجوز'), Colors.blueGrey),
            stat('داخل الكشف', n('داخل الكشف'), Colors.teal),
            stat('انتهوا', n('انتهى'), Colors.green),
          ]),
          summary(live),
          Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: FilledButton.tonalIcon(icon: const Icon(Icons.picture_as_pdf), label: const Text('تقرير اليوم PDF'), onPressed: () => accountsPdf(c, DateTime.now()))),
          const Padding(padding: EdgeInsets.all(8), child: Text('كشوفات اليوم', style: TextStyle(fontWeight: FontWeight.bold))),
          for (final a in live) accountTile(c, a, false),
        ]);
      });
}

// ================= تقرير الحسابات PDF =================
Future<void> accountsPdf(BuildContext c, DateTime d) async {
  final r = await q("SELECT a.*,p.name FROM appts a JOIN patients p ON p.id=a.pid WHERE a.del=0 AND p.del=0 AND a.dt LIKE ? ORDER BY a.dt", ['${day(d)}%']);
  final live = r.where((a) => a['status'] != 'ألغي').toList();
  final cancelled = r.length - live.length;
  double ps = 0, ds = 0;
  int pc = 0, dc = 0;
  for (final a in live) {
    final f = ((a['fee'] as num?) ?? 0).toDouble();
    if (a['paid'] == 1) {
      ps += f;
      pc++;
    } else {
      ds += f;
      dc++;
    }
  }
  final reg = pw.Font.ttf(await rootBundle.load('assets/DejaVuSans.ttf'));
  final bold = pw.Font.ttf(await rootBundle.load('assets/DejaVuSans-Bold.ttf'));
  pw.Widget cell(String t, int flex, {bool b = false, PdfColor? color}) => pw.Expanded(
      flex: flex,
      child: pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 5, horizontal: 3),
          child: pw.Text(t, textAlign: pw.TextAlign.center, style: pw.TextStyle(fontWeight: b ? pw.FontWeight.bold : pw.FontWeight.normal, color: color, fontSize: 11))));
  pw.Widget line(List<pw.Widget> cs, {PdfColor? bg}) => pw.Container(
      decoration: pw.BoxDecoration(color: bg, border: const pw.Border(bottom: pw.BorderSide(width: 0.5, color: PdfColors.grey500))),
      child: pw.Row(children: cs));
  pw.Widget kv(String k, String v, {PdfColor? color}) => pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(children: [pw.Expanded(child: pw.Text(k)), pw.Text(v, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: color))]));
  final doc = pw.Document();
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(28),
    theme: pw.ThemeData.withFont(base: reg, bold: bold),
    textDirection: pw.TextDirection.rtl,
    footer: (ctx) => pw.Center(child: pw.Text('صفحة ${ctx.pageNumber} من ${ctx.pagesCount}', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700))),
    build: (_) => [
      pw.Center(child: pw.Text(clinic.value, style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold))),
      if (doctor.value.isNotEmpty) pw.Center(child: pw.Text(doctor.value)),
      pw.SizedBox(height: 6),
      pw.Center(child: pw.Text('تقرير الحسابات اليومي — ${day(d)}', style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold))),
      pw.SizedBox(height: 12),
      pw.Container(
          padding: const pw.EdgeInsets.all(10),
          decoration: pw.BoxDecoration(border: pw.Border.all(width: 0.8), borderRadius: pw.BorderRadius.circular(4)),
          child: pw.Column(children: [
            kv('عدد الكشوفات', '${live.length}'),
            kv('المسدد (${pc} كشف)', money(ps), color: PdfColors.green800),
            kv('غير المسدد (${dc} كشف)', money(ds), color: PdfColors.red800),
            pw.Divider(),
            kv('إجمالي الكشوفات', money(ps + ds)),
            kv('المحصّل فعليًا', money(ps), color: PdfColors.green800),
            if (cancelled > 0) kv('كشوفات ملغاة', '$cancelled'),
          ])),
      pw.SizedBox(height: 14),
      line([cell('م', 1, b: true), cell('اسم المريض', 5, b: true), cell('الوقت', 2, b: true), cell('الحالة', 3, b: true), cell('المبلغ', 3, b: true), cell('السداد', 3, b: true)], bg: PdfColors.grey300),
      for (var i = 0; i < live.length; i++)
        line([
          cell('${i + 1}', 1),
          cell('${live[i]['name']}', 5),
          cell((live[i]['dt'] as String).substring(11, 16), 2),
          cell('${live[i]['status']}', 3),
          cell(money((live[i]['fee'] as num?) ?? 0), 3),
          cell(live[i]['paid'] == 1 ? 'مسدد' : 'لم يسدد', 3, b: true, color: live[i]['paid'] == 1 ? PdfColors.green800 : PdfColors.red800),
        ]),
      if (live.isEmpty) pw.Padding(padding: const pw.EdgeInsets.all(12), child: pw.Center(child: pw.Text('لا توجد كشوفات في هذا اليوم'))),
      pw.SizedBox(height: 24),
      pw.Text('توقيع المسؤول: ....................................'),
      pw.SizedBox(height: 6),
      pw.Text('تاريخ الطباعة: ${fmt.format(DateTime.now())}', style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
    ],
  ));
  final bytes = await doc.save();
  await Printing.layoutPdf(name: 'accounts_${day(d)}.pdf', onLayout: (_) async => bytes);
}

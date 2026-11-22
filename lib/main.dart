import 'dart:io';
import 'license.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as pth;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

late Database db;
final tick = ValueNotifier(0);
final clinic = ValueNotifier<String>('العيادة');
final doctor = ValueNotifier<String>('');
void refresh() => tick.value++;
typedef Row = Map<String, Object?>;
const sts = ['محجوز', 'وصل', 'داخل الكشف', 'انتهى', 'ألغي'];
final fmt = DateFormat('yyyy-MM-dd HH:mm');
String day(DateTime t) => DateFormat('yyyy-MM-dd').format(t);
Future<List<Row>> q(String s, [List<Object?> a = const []]) => db.rawQuery(s, a);

const msgsSql = 'CREATE TABLE IF NOT EXISTS msgs(k TEXT PRIMARY KEY,dt TEXT)';
Future<Database> openDb() async => openDatabase(pth.join(await getDatabasesPath(), 'clinic.db'),
    version: 2,
    onCreate: (d, v) async {
      await d.execute('CREATE TABLE patients(id INTEGER PRIMARY KEY AUTOINCREMENT,name TEXT,phone TEXT,age INTEGER,notes TEXT)');
      await d.execute('CREATE TABLE appts(id INTEGER PRIMARY KEY AUTOINCREMENT,pid INTEGER,dt TEXT,status TEXT,reason TEXT)');
      await d.execute('CREATE TABLE records(id INTEGER PRIMARY KEY AUTOINCREMENT,pid INTEGER,dt TEXT,complaint TEXT,diagnosis TEXT,treatment TEXT)');
      await d.execute(msgsSql);
    },
    onUpgrade: (d, o, n) async {
      if (o < 2) await d.execute(msgsSql);
    });

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  db = await openDb();
  final sp = await SharedPreferences.getInstance();
  clinic.value = sp.getString('clinic_name') ?? 'العيادة';
  doctor.value = sp.getString('doctor_name') ?? '';
  runApp(const App());
}

class App extends StatelessWidget {
  const App({super.key});
  @override
  Widget build(BuildContext c) => MaterialApp(
        title: 'عيادة - الاستقبال',
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
  @override
  Widget build(BuildContext c) {
    const tabs = [TodayTab(), ApptsTab(), PatientsTab(), MsgTab()];
    return Scaffold(
      appBar: AppBar(title: ValueListenableBuilder<String>(
          valueListenable: clinic,
          builder: (_, cl, __) => ValueListenableBuilder<String>(
              valueListenable: doctor,
              builder: (_, dr, __) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(cl, style: const TextStyle(fontSize: 18)),
                    if (dr.isNotEmpty) Text(dr, style: const TextStyle(fontSize: 12))
                  ]))), actions: [
        IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const SettingsPage())))
      ]),
      body: tabs[i],
      floatingActionButton: i <= 1
          ? FloatingActionButton(onPressed: () => addAppt(c), child: const Icon(Icons.add))
          : i == 2
              ? FloatingActionButton(onPressed: () => addPatient(c), child: const Icon(Icons.person_add))
              : null,
      bottomNavigationBar: NavigationBar(selectedIndex: i, onDestinationSelected: (v) => setState(() => i = v), destinations: const [
        NavigationDestination(icon: Icon(Icons.today), label: 'اليوم'),
        NavigationDestination(icon: Icon(Icons.event), label: 'المواعيد'),
        NavigationDestination(icon: Icon(Icons.people), label: 'المرضى'),
        NavigationDestination(icon: Icon(Icons.sms), label: 'الرسائل'),
      ]),
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
                TextField(controller: cs[i], decoration: InputDecoration(labelText: ls[i]))
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
  await db.insert('patients', {'name': v[0].trim(), 'phone': v[1].trim(), 'age': int.tryParse(v[2]), 'notes': v[3]});
  refresh();
}

Future<void> addAppt(BuildContext c) => apptForm(c);

Future<void> apptForm(BuildContext c, {Row? old}) async {
  final ps = await q('SELECT id,name FROM patients ORDER BY name');
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
                  TextField(controller: rc, decoration: const InputDecoration(labelText: 'سبب الزيارة')),
                ]),
                actions: [
                  TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('إلغاء')),
                  FilledButton(
                      onPressed: () async {
                        final lo = fmt.format(dt.subtract(const Duration(minutes: 14)));
                        final hi = fmt.format(dt.add(const Duration(minutes: 14)));
                        final clash = await q("SELECT a.dt,p.name FROM appts a JOIN patients p ON p.id=a.pid WHERE a.dt BETWEEN ? AND ? AND a.status!='ألغي' AND a.id!=?", [lo, hi, old?['id'] ?? -1]);
                        if (clash.isNotEmpty) {
                          if (!ctx.mounted) return;
                          final go = await confirm(ctx, 'يوجد موعد في نفس الوقت تقريبًا: ${clash.first['name']} (${clash.first['dt']}). هل تريد الحجز رغم ذلك؟');
                          if (!go) return;
                        }
                        final vals = {'pid': pid, 'dt': fmt.format(dt), 'reason': rc.text};
                        if (old == null) {
                          await db.insert('appts', {...vals, 'status': 'محجوز'});
                        } else {
                          await db.update('appts', vals, where: 'id=?', whereArgs: [old['id']]);
                          if (old['dt'] != vals['dt']) await db.delete('msgs', where: 'k=?', whereArgs: ['r${old['id']}']);
                        }
                        refresh();
                        if (ctx.mounted) Navigator.pop(ctx);
                      },
                      child: const Text('حفظ'))
                ],
              )));
}

Widget apptTile(BuildContext c, Row a) => Card(
        child: ListTile(
      title: Text('${a['name']}'),
      subtitle: Text('${a['dt']} • ${a['reason'] ?? ''}'),
      trailing: PopupMenuButton<String>(
          onSelected: (v) async {
            await db.update('appts', {'status': v}, where: 'id=?', whereArgs: [a['id']]);
            refresh();
          },
          itemBuilder: (_) => [for (final s in sts) PopupMenuItem(value: s, child: Text(s))],
          child: Chip(label: Text('${a['status']}'))),
      onTap: () => apptForm(c, old: a),
      onLongPress: () async {
        if (!await confirm(c, 'حذف هذا الموعد؟')) return;
        await db.delete('appts', where: 'id=?', whereArgs: [a['id']]);
        refresh();
      },
    ));

class TodayTab extends StatelessWidget {
  const TodayTab({super.key});
  @override
  Widget build(BuildContext c) => Live(() async {
        final r = await q('SELECT a.*,p.name,p.phone FROM appts a JOIN patients p ON p.id=a.pid WHERE a.dt LIKE ? ORDER BY a.dt', ['${day(DateTime.now())}%']);
        if (r.isEmpty) return const Center(child: Text('لا مواعيد اليوم'));
        return ListView(children: [for (final a in r) apptTile(c, a)]);
      });
}

class ApptsTab extends StatelessWidget {
  const ApptsTab({super.key});
  @override
  Widget build(BuildContext c) => Live(() async {
        final r = await q('SELECT a.*,p.name,p.phone FROM appts a JOIN patients p ON p.id=a.pid WHERE a.dt >= ? ORDER BY a.dt', [day(DateTime.now())]);
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
  @override
  Widget build(BuildContext c) => Column(children: [
        Padding(
            padding: const EdgeInsets.all(8),
            child: TextField(
                decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'بحث بالاسم أو الهاتف', border: OutlineInputBorder()),
                onChanged: (v) => setState(() => s = v))),
        Expanded(
            child: Live(() async {
          final r = await q('SELECT * FROM patients WHERE name LIKE ? OR phone LIKE ? ORDER BY name', ['%$s%', '%$s%']);
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
  final Row p;
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
                await db.update('patients', {'name': v[0].trim(), 'phone': v[1].trim(), 'age': int.tryParse(v[2]), 'notes': v[3]}, where: 'id=?', whereArgs: [p['id']]);
                refresh();
                if (c.mounted) Navigator.pop(c);
              }),
          IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () async {
                if (!await confirm(c, 'حذف المريض وكل مواعيده وسجلاته؟')) return;
                for (final t in ['appts', 'records']) {
                  await db.delete(t, where: 'pid=?', whereArgs: [p['id']]);
                }
                await db.delete('patients', where: 'id=?', whereArgs: [p['id']]);
                refresh();
                if (c.mounted) Navigator.pop(c);
              }),
        ]),
        floatingActionButton: FloatingActionButton.extended(
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
        final a = await q("SELECT a.*,p.name,p.phone FROM appts a JOIN patients p ON p.id=a.pid WHERE a.dt LIKE ? AND a.status='محجوز' ORDER BY a.dt", ['$tm%']);
        final r = await q('SELECT r.*,p.name,p.phone FROM records r JOIN patients p ON p.id=r.pid WHERE r.dt >= ? ORDER BY r.id DESC', [wk]);
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
            sendTile('${x['name']}', '${x['dt']} — ${x['treatment']}', '${x['phone']}',
                'مرحبًا ${x['name']}، نطمئن على حالتك. هل تلتزم بالعلاج الموصوف (${x['treatment']})؟ برجاء إبلاغنا بأي أعراض.',
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
  String? pin;
  bool loaded = false, ok = false;
  String err = '';
  final c = TextEditingController();
  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) => setState(() {
          pin = p.getString('pin');
          loaded = true;
        }));
  }

  Future<void> submit() async {
    final v = c.text;
    if (pin == null) {
      if (v.length < 4) return setState(() => err = 'الرقم السري 4 أرقام على الأقل');
      (await SharedPreferences.getInstance()).setString('pin', v);
      setState(() { pin = v; ok = true; });
    } else if (v == pin) {
      setState(() => ok = true);
    } else {
      c.clear();
      setState(() => err = 'رقم سري خاطئ');
    }
  }

  @override
  Widget build(BuildContext ctx) {
    if (!loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (ok) return const Home();
    return Scaffold(
        body: Center(
            child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.lock, size: 64),
                  const SizedBox(height: 12),
                  Text(pin == null ? 'أنشئ رقمًا سريًا للتطبيق' : 'أدخل الرقم السري'),
                  TextField(controller: c, obscureText: true, keyboardType: TextInputType.number, textAlign: TextAlign.center, onSubmitted: (_) => submit()),
                  if (err.isNotEmpty) Text(err, style: const TextStyle(color: Colors.red)),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: submit, child: const Text('دخول')),
                ]))));
  }
}

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});
  @override
  Widget build(BuildContext c) => Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: ListView(children: [
        ListTile(
            leading: const Icon(Icons.lock),
            title: const Text('تغيير الرقم السري'),
            onTap: () async {
              final v = await form(c, 'رقم سري جديد', ['الرقم السري (4 أرقام على الأقل)']);
              if (v == null || v[0].length < 4) return;
              (await SharedPreferences.getInstance()).setString('pin', v[0]);
              toast(c, 'تم تغيير الرقم السري');
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
        ListTile(leading: const Icon(Icons.backup), title: const Text('نسخة احتياطية (مشاركة الملف)'), onTap: () => backup(c)),
        ListTile(leading: const Icon(Icons.restore), title: const Text('استعادة نسخة احتياطية'), onTap: () => restore(c)),
      ]));
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
  refresh();
  toast(c, 'تمت الاستعادة');
}

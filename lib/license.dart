import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'main.dart' show LockGate;

// ===== إعدادات المالك (عدّلها قبل البناء) =====
const ownerName = 'م. جمال غنيمي';
const ownerPhone = '201027488896'; // رقم واتساب المالك بالصيغة الدولية بدون +
const trialDays = 3;
const licSecret = 'e13cdf58299ff9ecdd661192d9576d4651147eef728b7dd3'; // سري: يجب أن يطابق keygen.py

String codeFor(String id) {
  final h = Hmac(sha256, utf8.encode(licSecret)).convert(utf8.encode(id)).toString().toUpperCase().substring(0, 16);
  return [for (var i = 0; i < 16; i += 4) h.substring(i, i + 4)].join('-');
}

class LicenseGate extends StatefulWidget {
  const LicenseGate({super.key});
  @override
  State<LicenseGate> createState() => _LicenseGateState();
}

class _LicenseGateState extends State<LicenseGate> {
  bool loaded = false, activated = false, expired = false, proceed = false;
  String id = '', err = '';
  int daysLeft = 0;
  final cc = TextEditingController();

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    var d = p.getString('dev_id');
    if (d == null) {
      const a = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
      final r = Random.secure();
      String g(int n) => List.generate(n, (_) => a[r.nextInt(a.length)]).join();
      d = '${g(5)}-${g(5)}';
      await p.setString('dev_id', d);
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final start = p.getInt('trial_start') ?? now;
    if (!p.containsKey('trial_start')) await p.setInt('trial_start', start);
    final seen = max(now, p.getInt('last_seen') ?? now); // يمنع الرجوع بتاريخ الجهاز
    await p.setInt('last_seen', seen);
    const day = 86400000;
    final left = trialDays * day - (seen - start);
    setState(() {
      id = d!;
      activated = p.getString('act_code') == codeFor(d);
      expired = left <= 0;
      daysLeft = (left / day).ceil();
      loaded = true;
    });
  }

  Future<void> activate() async {
    final v = cc.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final real = codeFor(id).replaceAll('-', '');
    if (v == real) {
      await (await SharedPreferences.getInstance()).setString('act_code', codeFor(id));
      setState(() => activated = true);
    } else {
      setState(() => err = 'كود التفعيل غير صحيح');
    }
  }

  @override
  Widget build(BuildContext c) {
    if (!loaded) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    if (activated || (!expired && proceed)) return const LockGate();
    final msg = 'السلام عليكم م. جمال، أرغب في كود تفعيل تطبيق العيادة. رقم الجهاز: $id';
    return Scaffold(
        body: SafeArea(
            child: Center(
                child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(children: [
                      const Icon(Icons.local_hospital, size: 80, color: Colors.teal),
                      const SizedBox(height: 8),
                      const Text('مرحبًا بك في تطبيق العيادة الذكية', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 12),
                      const Text('تم تطوير هذا التطبيق بواسطة'),
                      Text(ownerName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.teal)),
                      const SizedBox(height: 16),
                      Text(
                          expired ? 'انتهت الفترة التجريبية ($trialDays أيام). برجاء طلب كود التفعيل من مالك البرنامج.' : 'نسخة تجريبية — المتبقي $daysLeft يوم',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: expired ? Colors.red : null, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      Card(
                          child: ListTile(
                              title: const Text('رقم الجهاز'),
                              subtitle: SelectableText(id, style: const TextStyle(fontSize: 18, letterSpacing: 2)),
                              trailing: IconButton(icon: const Icon(Icons.copy), onPressed: () => Clipboard.setData(ClipboardData(text: id))))),
                      OutlinedButton.icon(
                          icon: const Icon(Icons.chat),
                          label: const Text('طلب كود التفعيل عبر واتساب'),
                          onPressed: () => launchUrl(Uri.parse('https://wa.me/$ownerPhone?text=${Uri.encodeComponent(msg)}'), mode: LaunchMode.externalApplication)),
                      const SizedBox(height: 16),
                      TextField(
                          controller: cc,
                          textCapitalization: TextCapitalization.characters,
                          textAlign: TextAlign.center,
                          decoration: InputDecoration(labelText: 'كود التفعيل', border: const OutlineInputBorder(), errorText: err.isEmpty ? null : err)),
                      const SizedBox(height: 8),
                      FilledButton(onPressed: activate, child: const Text('تفعيل')),
                      if (!expired) TextButton(onPressed: () => setState(() => proceed = true), child: const Text('متابعة النسخة التجريبية')),
                    ])))));
  }
}

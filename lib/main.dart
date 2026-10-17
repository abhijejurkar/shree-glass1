import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import 'package:sqflite/sqflite.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CashDatabase.instance.database;
  runApp(const ShreeGlassApp());
}

const brand = Color(0xFF9D0644);
const brandDark = Color(0xFF78002F);
const ink = Color(0xFF14274A);
const canvas = Color(0xFFF7F5F6);
const incomeGreen = Color(0xFF18845D);
const expenseRed = Color(0xFFD64D4D);
const linePink = Color(0xFFF5D9E3);

String money(int paise) => NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2).format(paise / 100);
String amountText(int paise) => NumberFormat('#,##,##0.00', 'en_IN').format(paise / 100);
String cleanFileName(String value) => value.trim().replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_').replaceAll(RegExp('_+'), '_').replaceAll(RegExp(r'^_|_$'), '');
bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

String _underThousand(int n) {
  const ones = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten', 'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'];
  const tens = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];
  final parts = <String>[];
  if (n >= 100) { parts.add('${ones[n ~/ 100]} Hundred'); n %= 100; }
  if (n >= 20) { parts.add(tens[n ~/ 10]); n %= 10; }
  if (n > 0) parts.add(ones[n]);
  return parts.join(' ');
}

String amountInWords(int paise) {
  var n = paise ~/ 100;
  if (n == 0) return 'Zero Rupees Only';
  final parts = <String>[];
  for (final unit in <(int, String)>[(10000000, 'Crore'), (100000, 'Lakh'), (1000, 'Thousand'), (1, '')]) {
    final count = n ~/ unit.$1;
    if (count > 0) {
      parts.add(_underThousand(count) + (unit.$2.isEmpty ? '' : ' ${unit.$2}'));
      n %= unit.$1;
    }
  }
  final paiseRemainder = paise % 100;
  return '${parts.join(' ')} Rupees${paiseRemainder > 0 ? ' and ${_underThousand(paiseRemainder)} Paise' : ''} Only';
}

class ReceiptItem {
  final String description;
  final int ratePaise;
  final double quantity;
  const ReceiptItem({required this.description, required this.ratePaise, required this.quantity});
  int get amountPaise => (ratePaise * quantity).round();
  Map<String, dynamic> toMap() => {'description': description, 'rate_paise': ratePaise, 'quantity': quantity};
  factory ReceiptItem.fromMap(Map<String, dynamic> map) => ReceiptItem(
    description: map['description'] as String? ?? '',
    ratePaise: (map['rate_paise'] as num?)?.toInt() ?? 0,
    quantity: (map['quantity'] as num?)?.toDouble() ?? 1,
  );
}

class CashEntry {
  final int? id;
  final String type;
  final String description;
  final String customer;
  final int amountPaise; // Full bill / transaction amount
  final String note;
  final DateTime date;
  final String paymentStatus; // paid or credit
  final String paymentMethod; // Cash or Online
  final int collectedPaise;
  final String village;
  final String billNo;
  final List<ReceiptItem> items;

  const CashEntry({this.id, required this.type, required this.description, required this.customer,
    required this.amountPaise, required this.note, required this.date, this.paymentStatus = 'paid',
    this.paymentMethod = 'Cash', this.collectedPaise = 0, this.village = '', this.billNo = '', this.items = const []});
  int get remainingPaise => (amountPaise - collectedPaise).clamp(0, amountPaise);
  Map<String, Object?> toMap() => {
    'id': id, 'type': type, 'description': description.trim(), 'customer': customer.trim(),
    'amount_paise': amountPaise, 'note': note.trim(), 'entry_date': date.toIso8601String(),
    'payment_status': remainingPaise == 0 ? 'paid' : 'credit', 'payment_method': paymentMethod,
    'collected_paise': collectedPaise, 'village': village.trim(), 'bill_no': billNo,
    'items_json': jsonEncode(items.map((e) => e.toMap()).toList()),
  };
  factory CashEntry.fromMap(Map<String, Object?> map) {
    List<ReceiptItem> items = [];
    final raw = map['items_json'] as String?;
    if (raw != null && raw.isNotEmpty) {
      try { items = (jsonDecode(raw) as List).map((e) => ReceiptItem.fromMap(Map<String, dynamic>.from(e as Map))).toList(); } catch (_) { items = []; }
    }
    final amount = map['amount_paise'] as int;
    final collected = (map['collected_paise'] as int?) ?? ((map['payment_status'] == null || map['payment_status'] == 'paid') ? amount : 0);
    if (items.isEmpty) items = [ReceiptItem(description: map['description'] as String? ?? 'Item', ratePaise: amount, quantity: 1)];
    return CashEntry(id: map['id'] as int?, type: map['type'] as String, description: map['description'] as String? ?? '',
      customer: map['customer'] as String? ?? '', amountPaise: amount, note: map['note'] as String? ?? '',
      date: DateTime.parse(map['entry_date'] as String), paymentStatus: (map['payment_status'] as String?) ?? 'paid',
      paymentMethod: (map['payment_method'] as String?) ?? 'Cash', collectedPaise: collected,
      village: map['village'] as String? ?? '', billNo: map['bill_no'] as String? ?? '', items: items);
  }
}

class CashDatabase {
  CashDatabase._();
  static final instance = CashDatabase._();
  Database? _db;
  Future<Database> get database async {
    if (_db != null) return _db!;
    final root = await getDatabasesPath();
    _db = await openDatabase(p.join(root, 'shree_glass_cashflow.db'), version: 3,
      onCreate: (db, version) async {
        await db.execute('''CREATE TABLE cash_entries (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          type TEXT NOT NULL CHECK(type IN ('income','expense')),
          description TEXT NOT NULL, customer TEXT NOT NULL DEFAULT '',
          amount_paise INTEGER NOT NULL CHECK(amount_paise > 0), note TEXT NOT NULL DEFAULT '',
          entry_date TEXT NOT NULL, payment_status TEXT NOT NULL DEFAULT 'paid',
          payment_method TEXT NOT NULL DEFAULT 'Cash', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
          collected_paise INTEGER NOT NULL DEFAULT 0, village TEXT NOT NULL DEFAULT '',
          bill_no TEXT NOT NULL DEFAULT '', items_json TEXT NOT NULL DEFAULT '[]'
        )''');
        await db.execute('CREATE INDEX idx_cash_entries_date ON cash_entries(entry_date)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute("ALTER TABLE cash_entries ADD COLUMN payment_status TEXT NOT NULL DEFAULT 'paid'");
          await db.execute("ALTER TABLE cash_entries ADD COLUMN payment_method TEXT NOT NULL DEFAULT 'Cash'");
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE cash_entries ADD COLUMN collected_paise INTEGER NOT NULL DEFAULT 0');
          await db.execute("ALTER TABLE cash_entries ADD COLUMN village TEXT NOT NULL DEFAULT ''");
          await db.execute("ALTER TABLE cash_entries ADD COLUMN bill_no TEXT NOT NULL DEFAULT ''");
          await db.execute("ALTER TABLE cash_entries ADD COLUMN items_json TEXT NOT NULL DEFAULT '[]'");
          await db.execute("UPDATE cash_entries SET collected_paise = amount_paise WHERE payment_status = 'paid'");
        }
      });
    return _db!;
  }
  Future<List<CashEntry>> allEntries() async => (await (await database).query('cash_entries', orderBy: 'entry_date DESC, id DESC')).map(CashEntry.fromMap).toList();
  Future<int> save(CashEntry entry) async {
    final db = await database;
    final values = entry.toMap()..remove('id');
    if (entry.id == null) return db.insert('cash_entries', values);
    await db.update('cash_entries', values, where: 'id = ?', whereArgs: [entry.id]);
    return entry.id!;
  }
  Future<void> delete(int id) async => (await database).delete('cash_entries', where: 'id = ?', whereArgs: [id]);
  Future<int> nextBillNo() async {
    final rows = await (await database).rawQuery("SELECT MAX(CAST(bill_no AS INTEGER)) AS last_no FROM cash_entries WHERE bill_no != ''");
    return ((rows.first['last_no'] as int?) ?? 0) + 1;
  }
}

class ShreeGlassApp extends StatelessWidget {
  const ShreeGlassApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Shree Glass Hardware', debugShowCheckedModeBanner: false,
    theme: ThemeData(useMaterial3: true, scaffoldBackgroundColor: canvas,
      colorScheme: ColorScheme.fromSeed(seedColor: brand), appBarTheme: const AppBarTheme(backgroundColor: canvas, foregroundColor: ink, elevation: 0),
      inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: Colors.white, contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE8DDE2))),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: Color(0xFFE8DDE2))),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: brand, width: 1.4)))),
    home: const HomeScreen());
}

class HomeScreen extends StatefulWidget { const HomeScreen({super.key}); @override State<HomeScreen> createState() => _HomeScreenState(); }
class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0; bool _loading = true; List<CashEntry> _entries = [];
  @override void initState() { super.initState(); _refresh(); }
  Future<void> _refresh() async { final data = await CashDatabase.instance.allEntries(); if (mounted) setState(() { _entries = data; _loading = false; }); }
  Future<void> _addEntry({CashEntry? entry}) async {
    final result = await showModalBottomSheet<CashEntry>(context: context, isScrollControlled: true, useSafeArea: true, backgroundColor: canvas,
      builder: (_) => EntryForm(entry: entry));
    if (result == null || !mounted) return;
    final savedId = await CashDatabase.instance.save(result);
    await _refresh();
    final saved = _entries.firstWhere((e) => e.id == savedId);
    if (saved.type == 'income') await _receiptActions(saved);
  }
  Future<void> _receiptActions(CashEntry entry) async {
    if (!mounted) return;
    await showModalBottomSheet<void>(context: context, showDragHandle: true, backgroundColor: Colors.white, builder: (sheetContext) => Padding(
      padding: const EdgeInsets.fromLTRB(22, 6, 22, 28), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Receipt ready', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: ink)),
        const SizedBox(height: 5), Text('Bill ${entry.billNo} • ${entry.customer.isEmpty ? 'Customer' : entry.customer}', style: const TextStyle(color: Colors.black54)),
        const SizedBox(height: 18),
        _actionRow(Icons.picture_as_pdf_rounded, 'Save receipt on this phone', 'PDF named with customer and date', () async { Navigator.pop(sheetContext); await _saveReceipt(entry); }),
        _actionRow(Icons.share_rounded, 'Share receipt / WhatsApp', 'Choose WhatsApp or another app', () async { Navigator.pop(sheetContext); await _shareReceipt(entry); }),
        _actionRow(Icons.open_in_new_rounded, 'Open / export receipt PDF', 'Choose an app to view, save, or send it', () async { Navigator.pop(sheetContext); await _previewReceipt(entry); }),
      ])));
  }
  Future<File> _createReceipt(CashEntry e) async {
    final doc = pw.Document();
    final dateText = DateFormat('dd/MM/yyyy').format(e.date);
    final items = e.items.isEmpty ? [ReceiptItem(description: e.description, ratePaise: e.amountPaise, quantity: 1)] : e.items;
    doc.addPage(pw.Page(pageFormat: PdfPageFormat.a4, margin: const pw.EdgeInsets.all(24), build: (context) {
      final border = PdfColor.fromHex('#9D0644'); final pale = PdfColor.fromHex('#FBE8EF'); final navy = PdfColor.fromHex('#14274A');
      return pw.Container(decoration: pw.BoxDecoration(border: pw.Border.all(color: border, width: 1.6)), padding: const pw.EdgeInsets.all(14), child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.stretch, children: [
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [pw.Text('☎  9527226277', style: pw.TextStyle(color: border, fontSize: 12, fontWeight: pw.FontWeight.bold)), pw.Container(color: pale, padding: const pw.EdgeInsets.symmetric(horizontal: 12, vertical: 7), child: pw.Text('CASH / CREDIT MEMO', style: pw.TextStyle(color: border, fontWeight: pw.FontWeight.bold, fontSize: 10)))]),
        pw.SizedBox(height: 10),
        pw.Container(color: border, padding: const pw.EdgeInsets.symmetric(vertical: 13, horizontal: 6), child: pw.Center(child: pw.Text('SHREE GLASS HARDWARE', style: pw.TextStyle(color: PdfColors.white, fontSize: 22, fontWeight: pw.FontWeight.bold)))),
        pw.SizedBox(height: 15),
        pw.Row(mainAxisAlignment: pw.MainAxisAlignment.spaceBetween, children: [pw.RichText(text: pw.TextSpan(children: [pw.TextSpan(text: 'Bill No.: ', style: pw.TextStyle(color: border, fontWeight: pw.FontWeight.bold)), pw.TextSpan(text: e.billNo.isEmpty ? '${e.id ?? ''}' : e.billNo, style: pw.TextStyle(color: PdfColors.red, fontSize: 16, fontWeight: pw.FontWeight.bold))])), pw.RichText(text: pw.TextSpan(children: [pw.TextSpan(text: 'Date: ', style: pw.TextStyle(color: border, fontWeight: pw.FontWeight.bold)), pw.TextSpan(text: dateText, style: pw.TextStyle(color: navy, fontWeight: pw.FontWeight.bold))]))]),
        pw.SizedBox(height: 8), pw.Row(children: [pw.Expanded(child: pw.RichText(text: pw.TextSpan(children: [pw.TextSpan(text: 'Customer: ', style: pw.TextStyle(color: border, fontWeight: pw.FontWeight.bold)), pw.TextSpan(text: e.customer.isEmpty ? 'Walk-in Customer' : e.customer, style: pw.TextStyle(color: navy, fontWeight: pw.FontWeight.bold))]))), pw.Text('Village: ${e.village}', style: pw.TextStyle(color: navy))]),
        pw.SizedBox(height: 12),
        pw.Table(border: pw.TableBorder.all(color: border, width: .8), columnWidths: {0: const pw.FlexColumnWidth(4.3), 1: const pw.FlexColumnWidth(1.4), 2: const pw.FlexColumnWidth(1.3), 3: const pw.FlexColumnWidth(2)}, children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(color: pale),
            children: [
              pw.Padding(
                padding: const pw.EdgeInsets.all(7),
                child: pw.Text('Description', textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(color: border, fontSize: 9, fontWeight: pw.FontWeight.bold)),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.all(7),
                child: pw.Text('Rate (₹)', textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(color: border, fontSize: 9, fontWeight: pw.FontWeight.bold)),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.all(7),
                child: pw.Text('Qty / Sq.Ft', textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(color: border, fontSize: 9, fontWeight: pw.FontWeight.bold)),
              ),
              pw.Padding(
                padding: const pw.EdgeInsets.all(7),
                child: pw.Text('Amount (₹)', textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(color: border, fontSize: 9, fontWeight: pw.FontWeight.bold)),
              ),
            ],
          ),
          ...items.map((it) => pw.TableRow(children: [pw.Padding(padding: const pw.EdgeInsets.all(7), child: pw.Text(it.description, style: pw.TextStyle(color: navy, fontSize: 9))), pw.Padding(padding: const pw.EdgeInsets.all(7), child: pw.Text(amountText(it.ratePaise), textAlign: pw.TextAlign.right, style: pw.TextStyle(color: navy, fontSize: 9))), pw.Padding(padding: const pw.EdgeInsets.all(7), child: pw.Text(it.quantity.toString().replaceAll(RegExp(r'\.0$'), ''), textAlign: pw.TextAlign.center, style: pw.TextStyle(color: navy, fontSize: 9))), pw.Padding(padding: const pw.EdgeInsets.all(7), child: pw.Text(amountText(it.amountPaise), textAlign: pw.TextAlign.right, style: pw.TextStyle(color: navy, fontSize: 9, fontWeight: pw.FontWeight.bold)))])),
          pw.TableRow(decoration: pw.BoxDecoration(color: pale), children: [pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text('TOTAL AMOUNT', style: pw.TextStyle(color: border, fontWeight: pw.FontWeight.bold))), pw.SizedBox(), pw.SizedBox(), pw.Padding(padding: const pw.EdgeInsets.all(8), child: pw.Text('₹ ${amountText(e.amountPaise)}', textAlign: pw.TextAlign.right, style: pw.TextStyle(color: navy, fontWeight: pw.FontWeight.bold, fontSize: 11)))])
        ]),
        pw.SizedBox(height: 10),
        pw.Container(color: pale, padding: const pw.EdgeInsets.all(9), child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
          pw.Text('AMOUNT IN WORDS', style: pw.TextStyle(color: border, fontSize: 8, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 3),
          pw.Text(amountInWords(e.amountPaise), style: pw.TextStyle(color: navy, fontSize: 10, fontWeight: pw.FontWeight.bold)),
        ])),
        pw.SizedBox(height: 8),
        pw.Center(child: pw.Text('SHREE GLASS HARDWARE', style: pw.TextStyle(color: PdfColor.fromHex('#F3DDE5'), fontSize: 16, fontWeight: pw.FontWeight.bold))),
        pw.SizedBox(height: 6),
        pw.Container(color: pale, padding: const pw.EdgeInsets.all(10), child: pw.Column(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [pw.Text('Amount Collected: ₹ ${amountText(e.collectedPaise)}', style: pw.TextStyle(color: navy, fontWeight: pw.FontWeight.bold, fontSize: 10)), pw.SizedBox(height: 4), pw.Text('Remaining Balance: ₹ ${amountText(e.remainingPaise)}', style: pw.TextStyle(color: e.remainingPaise > 0 ? border : navy, fontWeight: pw.FontWeight.bold, fontSize: 11)), pw.SizedBox(height: 4), pw.Text('Payment Mode: ${e.paymentMethod}', style: pw.TextStyle(color: navy, fontSize: 10))])),
        pw.Spacer(), pw.Divider(color: border), pw.SizedBox(height: 8), pw.Center(child: pw.Text('SHREE GLASS HARDWARE', style: pw.TextStyle(color: border, fontSize: 15, fontWeight: pw.FontWeight.bold))),
        pw.SizedBox(height: 20), pw.Align(alignment: pw.Alignment.centerRight, child: pw.Column(children: [pw.Container(width: 130, height: 1, color: navy), pw.SizedBox(height: 4), pw.Text('Signature', style: pw.TextStyle(color: navy, fontSize: 9))]))
      ]));
    }));
    final dir = await getApplicationDocumentsDirectory();
    final folder = Directory(p.join(dir.path, 'Receipts'));
    if (!await folder.exists()) await folder.create(recursive: true);
    final name = cleanFileName(e.customer.isEmpty ? 'Customer' : e.customer);
    final date = DateFormat('yyyy-MM-dd').format(e.date);
    final bill = cleanFileName(e.billNo.isEmpty ? '${e.id ?? 'bill'}' : e.billNo);
    final file = File(p.join(folder.path, '${name}_${date}_Bill_$bill.pdf'));
    await file.writeAsBytes(await doc.save(), flush: true);
    return file;
  }
  Future<void> _saveReceipt(CashEntry e) async {
    try { final file = await _createReceipt(e); if (mounted) _message('Receipt saved on this phone as ${p.basename(file.path)}. Use Share to send it on WhatsApp or save a copy elsewhere.'); }
    catch (_) { if (mounted) _message('Could not save receipt. Please try again.'); }
  }
  Future<void> _shareReceipt(CashEntry e) async {
    try { final file = await _createReceipt(e); await Share.shareXFiles([XFile(file.path, mimeType: 'application/pdf')], text: 'Receipt from SHREE GLASS HARDWARE • Bill ${e.billNo} • ${e.customer}'); }
    catch (_) { if (mounted) _message('Could not share receipt. Please try again.'); }
  }
  Future<void> _previewReceipt(CashEntry e) async {
    try { final file = await _createReceipt(e); await Share.shareXFiles([XFile(file.path, mimeType: 'application/pdf')], subject: 'Receipt ${e.billNo}', text: 'Open or save this PDF receipt.'); }
    catch (_) { if (mounted) _message('Could not prepare receipt PDF.'); }
  }
  void _message(String text) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text))); }
  Future<void> _delete(CashEntry entry) async {
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: const Text('Delete entry?'), content: Text('Delete ${entry.description}?'), actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete'))]));
    if (ok == true && entry.id != null) { await CashDatabase.instance.delete(entry.id!); await _refresh(); }
  }
  @override Widget build(BuildContext context) {
    final now = DateTime.now(); final today = _entries.where((e) => sameDay(e.date, now)).toList();
    int sum(Iterable<CashEntry> list) => list.fold<int>(0, (s, e) => s + e.amountPaise);
    final todayIn = sum(today.where((e) => e.type == 'income')); final todayOut = sum(today.where((e) => e.type == 'expense'));
    final totalIn = sum(_entries.where((e) => e.type == 'income')); final totalOut = sum(_entries.where((e) => e.type == 'expense'));
    return Scaffold(appBar: AppBar(title: Row(children: [Container(width: 42, height: 42, decoration: BoxDecoration(color: brand, borderRadius: BorderRadius.circular(13)), child: const Icon(Icons.window_rounded, color: Colors.white)), const SizedBox(width: 10), const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('SHREE GLASS', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, letterSpacing: .7)), Text('Hardware • Cash book', style: TextStyle(fontSize: 12, color: Colors.black54))])]), actions: [IconButton(onPressed: _refresh, icon: const Icon(Icons.refresh_rounded))]),
      body: _loading ? const Center(child: CircularProgressIndicator()) : _tab == 0 ? _dashboard(todayIn, todayOut, totalIn - totalOut, totalIn, totalOut) : _history(),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _addEntry(), backgroundColor: brand, foregroundColor: Colors.white, icon: const Icon(Icons.add_rounded), label: const Text('Add entry', style: TextStyle(fontWeight: FontWeight.w800))),
      bottomNavigationBar: NavigationBar(selectedIndex: _tab, onDestinationSelected: (v) => setState(() => _tab = v), backgroundColor: Colors.white, indicatorColor: linePink, destinations: const [NavigationDestination(icon: Icon(Icons.space_dashboard_outlined), selectedIcon: Icon(Icons.space_dashboard), label: 'Overview'), NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'History')]));
  }
  Widget _dashboard(int todayIn, int todayOut, int balance, int totalIn, int totalOut) => RefreshIndicator(onRefresh: _refresh, child: ListView(padding: const EdgeInsets.fromLTRB(17, 8, 17, 100), children: [
    Container(padding: const EdgeInsets.all(22), decoration: BoxDecoration(gradient: const LinearGradient(colors: [brandDark, brand], begin: Alignment.topLeft, end: Alignment.bottomRight), borderRadius: BorderRadius.circular(24), boxShadow: [BoxShadow(color: brand.withValues(alpha: .16), blurRadius: 20, offset: const Offset(0, 8))]), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Row(children: [Icon(Icons.account_balance_wallet_outlined, color: Colors.white70), SizedBox(width: 8), Text('NET RECORDED BALANCE', style: TextStyle(color: Colors.white70, fontSize: 11, letterSpacing: 1, fontWeight: FontWeight.w800))]), const SizedBox(height: 12), FittedBox(alignment: Alignment.centerLeft, child: Text(money(balance), style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.w900))), const SizedBox(height: 5), const Text('Total money in minus money out', style: TextStyle(color: Colors.white70, fontSize: 12)), const SizedBox(height: 18), const Divider(color: Colors.white24), Row(children: [Expanded(child: _metric('TOTAL IN', totalIn, Icons.south_west)), Expanded(child: _metric('TOTAL OUT', totalOut, Icons.north_east))])])),
    const SizedBox(height: 22), Row(children: [const Expanded(child: Text("Today's activity", style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: ink))), Text(DateFormat('EEE, d MMM').format(DateTime.now()), style: const TextStyle(color: Colors.black54, fontSize: 12))]), const SizedBox(height: 12), Row(children: [Expanded(child: _todayCard('Money in', todayIn, incomeGreen, Icons.south_west)), const SizedBox(width: 12), Expanded(child: _todayCard('Money out', todayOut, expenseRed, Icons.north_east))]),
    const SizedBox(height: 23), Row(children: [const Expanded(child: Text('Recent entries', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w900, color: ink))), TextButton(onPressed: () => setState(() => _tab = 1), child: const Text('View all'))]),
    ...(_entries.isEmpty ? <Widget>[_empty()] : _entries.take(5).map<Widget>(_entryTile).toList()),
  ]));
  Widget _metric(String label, int amount, IconData icon) => Padding(padding: const EdgeInsets.only(top: 12, right: 8), child: Row(children: [Icon(icon, color: Colors.white, size: 18), const SizedBox(width: 7), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label, style: const TextStyle(color: Colors.white70, fontSize: 10, fontWeight: FontWeight.w800)), const SizedBox(height: 4), FittedBox(alignment: Alignment.centerLeft, child: Text(money(amount), style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)))]))]));
  Widget _todayCard(String title, int amount, Color color, IconData icon) => Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18), border: Border.all(color: const Color(0xFFE9E2E5))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Container(padding: const EdgeInsets.all(9), decoration: BoxDecoration(color: color.withValues(alpha: .1), borderRadius: BorderRadius.circular(12)), child: Icon(icon, color: color)), const SizedBox(height: 12), Text(title, style: const TextStyle(color: Colors.black54, fontSize: 12)), const SizedBox(height: 5), FittedBox(alignment: Alignment.centerLeft, child: Text(money(amount), style: TextStyle(color: color, fontSize: 20, fontWeight: FontWeight.w900)))]));
  Widget _history() => ListView(padding: const EdgeInsets.fromLTRB(17, 10, 17, 100), children: [const Text('Transaction history', style: TextStyle(fontSize: 25, fontWeight: FontWeight.w900, color: ink)), const SizedBox(height: 5), Text('${_entries.length} entries saved on this device', style: const TextStyle(color: Colors.black54)), const SizedBox(height: 16), ...(_entries.isEmpty ? <Widget>[_empty()] : _entries.map<Widget>(_entryTile).toList())]);
  Widget _entryTile(CashEntry e) {
    final inc = e.type == 'income';
    return Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(13), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(17), border: Border.all(color: const Color(0xFFE9E2E5))), child: Row(children: [Container(width: 43, height: 43, decoration: BoxDecoration(color: (inc ? incomeGreen : expenseRed).withValues(alpha: .1), borderRadius: BorderRadius.circular(13)), child: Icon(inc ? Icons.south_west : Icons.north_east, color: inc ? incomeGreen : expenseRed)), const SizedBox(width: 11), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(e.description, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800, color: ink)), if (e.customer.isNotEmpty) Text(e.customer, style: const TextStyle(fontSize: 12, color: Colors.black54)), const SizedBox(height: 4), Text('${DateFormat('d MMM yyyy').format(e.date)} • ${e.paymentMethod} • ${e.remainingPaise > 0 ? 'Due ${money(e.remainingPaise)}' : 'Paid'}', style: TextStyle(fontSize: 10, color: e.remainingPaise > 0 ? brand : Colors.black45))])), const SizedBox(width: 5), Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text('${inc ? '+' : '−'}${money(e.amountPaise)}', style: TextStyle(color: inc ? incomeGreen : expenseRed, fontWeight: FontWeight.w900, fontSize: 12)), PopupMenuButton<String>(padding: EdgeInsets.zero, iconSize: 20, onSelected: (v) async { if (v == 'receipt' && inc) await _receiptActions(e); if (v == 'edit') await _addEntry(entry: e); if (v == 'delete') await _delete(e); }, itemBuilder: (_) => [if (inc) const PopupMenuItem(value: 'receipt', child: Text('Receipt: save/share')), const PopupMenuItem(value: 'edit', child: Text('Edit entry')), const PopupMenuItem(value: 'delete', child: Text('Delete entry'))])])]));
  }
  Widget _empty() => Container(padding: const EdgeInsets.all(25), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20)), child: const Column(children: [Icon(Icons.receipt_long, color: brand, size: 34), SizedBox(height: 10), Text('Your cash book starts here', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16)), SizedBox(height: 5), Text('Add a sale, payment received, purchase or shop expense.', textAlign: TextAlign.center, style: TextStyle(color: Colors.black54))]));
  Widget _actionRow(IconData icon, String title, String subtitle, VoidCallback action) => ListTile(contentPadding: EdgeInsets.zero, leading: Container(padding: const EdgeInsets.all(11), decoration: BoxDecoration(color: linePink, borderRadius: BorderRadius.circular(13)), child: Icon(icon, color: brand)), title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)), subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)), onTap: action);
}

class EntryForm extends StatefulWidget { final CashEntry? entry; const EntryForm({super.key, this.entry}); @override State<EntryForm> createState() => _EntryFormState(); }
class _EntryFormState extends State<EntryForm> {
  final _key = GlobalKey<FormState>(); late String _type, _method; late DateTime _date;
  late TextEditingController _customer, _village, _note, _bill;
  final List<_ItemControllers> _items = [];
  late TextEditingController _collected;
  bool _saving = false;
  @override void initState() { super.initState(); final e = widget.entry; _type = e?.type ?? 'income'; _method = e?.paymentMethod ?? 'Cash'; _date = e?.date ?? DateTime.now(); _customer = TextEditingController(text: e?.customer ?? ''); _village = TextEditingController(text: e?.village ?? ''); _note = TextEditingController(text: e?.note ?? ''); _bill = TextEditingController(text: e?.billNo ?? ''); _collected = TextEditingController(text: ((e?.collectedPaise ?? 0) / 100).toStringAsFixed(2));
    if (e != null) { for (final item in e.items) { _items.add(_ItemControllers(item.description, (item.ratePaise / 100).toStringAsFixed(2), item.quantity.toString().replaceAll(RegExp(r'\.0$'), ''))); } }
    if (_items.isEmpty) _items.add(_ItemControllers('', '', '1'));
    if (e == null) { WidgetsBinding.instance.addPostFrameCallback((_) async { final n = await CashDatabase.instance.nextBillNo(); if (mounted && _bill.text.isEmpty) setState(() => _bill.text = n.toString()); }); }
  }
  @override void dispose() { _customer.dispose(); _village.dispose(); _note.dispose(); _bill.dispose(); _collected.dispose(); for (final i in _items) { i.dispose(); } super.dispose(); }
  int get _totalPaise => _items.fold<int>(0, (s, i) => s + i.amountPaise);
  int get _collectedPaise { final n = double.tryParse(_collected.text.trim().replaceAll(',', '')) ?? 0; return (n * 100).round().clamp(0, _totalPaise); }
  Future<void> _pickDate() async { final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2000), lastDate: DateTime.now().add(const Duration(days: 365))); if (d != null) setState(() => _date = DateTime(d.year, d.month, d.day, _date.hour, _date.minute)); }
  Future<void> _save() async {
    if (!_key.currentState!.validate()) return;
    if (_type == 'income' && _items.any((i) => i.description.text.trim().isEmpty || i.ratePaise <= 0 || i.quantity <= 0)) { _toast('Complete every item row with description, rate and quantity.'); return; }
    if (_totalPaise <= 0) { _toast('Total amount must be greater than zero.'); return; }
    final collected = _collectedPaise;
    if (collected > _totalPaise) { _toast('Collected amount cannot exceed the total amount.'); return; }
    setState(() => _saving = true);
    final list = _type == 'income' ? _items.map((i) => ReceiptItem(description: i.description.text.trim(), ratePaise: i.ratePaise, quantity: i.quantity)).toList() : [ReceiptItem(description: _items.first.description.text.trim().isEmpty ? 'Expense' : _items.first.description.text.trim(), ratePaise: _totalPaise, quantity: 1)];
    final desc = list.map((i) => i.description).take(2).join(', ');
    Navigator.pop(context, CashEntry(id: widget.entry?.id, type: _type, description: desc.isEmpty ? 'Shop expense' : desc, customer: _customer.text.trim(), amountPaise: _totalPaise, note: _note.text, date: _date, paymentStatus: collected >= _totalPaise ? 'paid' : 'credit', paymentMethod: _method, collectedPaise: collected, village: _village.text, billNo: _bill.text.trim(), items: list));
  }
  void _toast(String s) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  @override Widget build(BuildContext context) {
    final isIncome = _type == 'income'; final remaining = (_totalPaise - _collectedPaise).clamp(0, _totalPaise);
    return Padding(padding: EdgeInsets.fromLTRB(18, 8, 18, 16 + MediaQuery.of(context).viewInsets.bottom), child: SingleChildScrollView(child: Form(key: _key, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Center(child: Container(width: 42, height: 4, decoration: BoxDecoration(color: const Color(0xFFD7DFDA), borderRadius: BorderRadius.circular(9)))), const SizedBox(height: 18),
      Text(widget.entry == null ? 'Create ${isIncome ? 'money-in receipt' : 'money-out entry'}' : 'Edit entry', style: const TextStyle(fontSize: 23, fontWeight: FontWeight.w900, color: ink)), const SizedBox(height: 5), const Text('Receipt for money in • Cash flow for money out', style: TextStyle(color: Colors.black54, fontSize: 12)), const SizedBox(height: 16),
      Container(padding: const EdgeInsets.all(4), decoration: BoxDecoration(color: const Color(0xFFEDE5E9), borderRadius: BorderRadius.circular(14)), child: Row(children: [Expanded(child: _typeButton('income', 'Money In', incomeGreen)), Expanded(child: _typeButton('expense', 'Money Out', expenseRed))])),
      const SizedBox(height: 17), _label('CUSTOMER / SUPPLIER NAME'), const SizedBox(height: 6), TextFormField(controller: _customer, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'Customer or supplier name'), validator: (v) => isIncome && (v == null || v.trim().isEmpty) ? 'Enter customer name for receipt' : null),
      if (isIncome) ...[const SizedBox(height: 13), _label('VILLAGE (OPTIONAL)'), const SizedBox(height: 6), TextFormField(controller: _village, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(hintText: 'Village / town')), const SizedBox(height: 13), _label('BILL NUMBER'), const SizedBox(height: 6), TextFormField(controller: _bill, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'Auto-generated bill number'))],
      const SizedBox(height: 18), Row(children: [Expanded(child: _label(isIncome ? 'ITEMS / RECEIPT DETAILS' : 'EXPENSE DETAILS')), if (isIncome) TextButton.icon(onPressed: () => setState(() => _items.add(_ItemControllers('', '', '1'))), icon: const Icon(Icons.add, size: 18), label: const Text('Add item'))]),
      ...List.generate(_items.length, (index) => _itemCard(index, isIncome)),
      const SizedBox(height: 12), Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), border: Border.all(color: linePink)), child: Row(children: [const Expanded(child: Text('TOTAL BILL AMOUNT', style: TextStyle(color: brand, fontWeight: FontWeight.w900, fontSize: 12))), Text(money(_totalPaise), style: const TextStyle(fontSize: 20, color: ink, fontWeight: FontWeight.w900))])),
      ...[const SizedBox(height: 18), _label(isIncome ? 'PAYMENT MODE' : 'PAYMENT MODE (SUPPLIER PAYMENT)'), const SizedBox(height: 7), SegmentedButton<String>(segments: const [ButtonSegment(value: 'Cash', label: Text('Cash'), icon: Icon(Icons.payments_outlined)), ButtonSegment(value: 'Online', label: Text('Online / UPI'), icon: Icon(Icons.phone_android_rounded))], selected: {_method}, onSelectionChanged: (v) => setState(() => _method = v.first), showSelectedIcon: false), const SizedBox(height: 16), _label(isIncome ? 'AMOUNT COLLECTED (₹)' : 'AMOUNT PAID (₹)'), const SizedBox(height: 6), TextFormField(controller: _collected, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {}), decoration: const InputDecoration(prefixText: '₹ ', hintText: 'Enter amount received'), validator: (v) { final n = double.tryParse((v ?? '').trim().replaceAll(',', '')); if (n == null || n < 0) return 'Enter a valid amount'; if (n * 100 > _totalPaise) return 'Amount cannot exceed total'; return null; }), const SizedBox(height: 11), Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: remaining > 0 ? const Color(0xFFFFF4E5) : const Color(0xFFE7F5EE), borderRadius: BorderRadius.circular(14)), child: Row(children: [Icon(remaining > 0 ? Icons.pending_actions : Icons.check_circle, color: remaining > 0 ? const Color(0xFFAD6A00) : incomeGreen), const SizedBox(width: 10), Expanded(child: Text(remaining > 0 ? (isIncome ? 'Remaining balance / customer due' : 'Remaining supplier balance') : (isIncome ? 'Fully collected' : 'Fully paid'), style: const TextStyle(fontWeight: FontWeight.w800))), Text(money(remaining), style: TextStyle(fontWeight: FontWeight.w900, color: remaining > 0 ? const Color(0xFFAD6A00) : incomeGreen))]))],
      const SizedBox(height: 17), _label('DATE'), const SizedBox(height: 6), InkWell(onTap: _pickDate, borderRadius: BorderRadius.circular(14), child: Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: const Color(0xFFE8DDE2))), child: Row(children: [const Icon(Icons.calendar_month, color: brand), const SizedBox(width: 10), Expanded(child: Text(DateFormat('EEEE, d MMMM yyyy').format(_date), style: const TextStyle(fontWeight: FontWeight.w700))), const Icon(Icons.keyboard_arrow_down)]))),
      const SizedBox(height: 13), _label('NOTE (OPTIONAL)'), const SizedBox(height: 6), TextFormField(controller: _note, maxLines: 2, decoration: const InputDecoration(hintText: 'Additional details')),
      const SizedBox(height: 20), SizedBox(width: double.infinity, height: 53, child: FilledButton.icon(onPressed: _saving ? null : _save, style: FilledButton.styleFrom(backgroundColor: brand, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))), icon: const Icon(Icons.receipt_long), label: Text(_saving ? 'Saving...' : isIncome ? 'Save & Generate Receipt' : 'Save Money Out', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)))), const SizedBox(height: 8),
    ]))));
  }
  Widget _itemCard(int index, bool isIncome) {
    final item = _items[index];
    return Container(margin: const EdgeInsets.only(bottom: 10), padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(15), border: Border.all(color: const Color(0xFFE9E2E5))), child: Column(children: [Row(children: [Expanded(child: Text('Item ${index + 1}', style: const TextStyle(fontWeight: FontWeight.w900, color: brand))), if (isIncome && _items.length > 1) IconButton(visualDensity: VisualDensity.compact, onPressed: () { setState(() { _items.removeAt(index).dispose(); }); }, icon: const Icon(Icons.delete_outline, color: expenseRed))]), TextFormField(controller: item.description, textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(hintText: 'Description (e.g. Sliding window)'), validator: (v) => isIncome && (v == null || v.trim().isEmpty) ? 'Enter item description' : null), const SizedBox(height: 9), Row(children: [Expanded(child: TextFormField(controller: item.rate, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Rate (₹)', prefixText: '₹ '), validator: (v) { final n = double.tryParse((v ?? '').trim().replaceAll(',', '')); return n == null || n <= 0 ? 'Enter rate' : null; })), const SizedBox(width: 9), Expanded(child: TextFormField(controller: item.quantityText, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: 'Qty / Sq.Ft'), validator: (v) { final n = double.tryParse((v ?? '').trim()); return n == null || n <= 0 ? 'Enter quantity' : null; }))]), const SizedBox(height: 7), Align(alignment: Alignment.centerRight, child: Text('Amount: ${money(item.amountPaise)}', style: const TextStyle(fontWeight: FontWeight.w900, color: ink)))]));
  }
  Widget _typeButton(String type, String text, Color color) { final selected = _type == type; return InkWell(onTap: () => setState(() { _type = type; if (_type == 'income' && _collected.text.trim().isEmpty) _collected.text = '0'; }), borderRadius: BorderRadius.circular(11), child: Container(padding: const EdgeInsets.symmetric(vertical: 12), decoration: BoxDecoration(color: selected ? Colors.white : Colors.transparent, borderRadius: BorderRadius.circular(11)), child: Center(child: Text(text, style: TextStyle(fontWeight: FontWeight.w900, color: selected ? color : Colors.black54))))); }
  Widget _label(String s) => Text(s, style: const TextStyle(fontSize: 10, letterSpacing: .8, fontWeight: FontWeight.w900, color: Color(0xFF6D5861)));
}

class _ItemControllers {
  final TextEditingController description, rate, quantityText;
  _ItemControllers(String d, String r, String q) : description = TextEditingController(text: d), rate = TextEditingController(text: r), quantityText = TextEditingController(text: q);
  int get ratePaise { final n = double.tryParse(rate.text.trim().replaceAll(',', '')) ?? 0; return (n * 100).round(); }
  double get quantity => double.tryParse(quantityText.text.trim()) ?? 0;
  int get amountPaise => (ratePaise * quantity).round();
  void dispose() { description.dispose(); rate.dispose(); quantityText.dispose(); }
}

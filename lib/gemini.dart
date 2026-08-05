
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

void main() {
  runApp(const InvoiceApp());
}

class InvoiceApp extends StatelessWidget {
  const InvoiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'WiFi Thermal Invoice',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const InvoiceScreen(),
    );
  }
}

class InvoiceScreen extends StatefulWidget {
  const InvoiceScreen({super.key});

  @override
  State<InvoiceScreen> createState() => _InvoiceScreenState();
}

class _InvoiceScreenState extends State<InvoiceScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ipCtrl = TextEditingController(text: '192.168.1.100');
  final _customerNameCtrl = TextEditingController();
  final _itemCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  bool _isPrinting = false;

  Future<void> _printDirectToThermal() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isPrinting = true);

    try {
      // 1. Load Printer Profile and Generator (Defaulting to 80mm paper size)
      final profile = await CapabilityProfile.load();
      final generator = Generator(PaperSize.mm80, profile);
      List<int> bytes = [];

      // 2. Build the ESC/POS Receipt
      // Header
      bytes += generator.text(
        'INVOICE',
        styles: const PosStyles(
          align: PosAlign.center,
          height: PosTextSize.size2,
          width: PosTextSize.size2,
          bold: true,
        ),
      );
      bytes += generator.feed(1);

      // Date & Customer
      bytes += generator.text('Date: ${DateTime.now().toString().split(' ')[0]}');
      bytes += generator.text('Billed To: ${_customerNameCtrl.text}');
      bytes += generator.hr(); // Draws a dashed line

      // Table Header (Widths must add up to 12)
      bytes += generator.row([
        PosColumn(
          text: 'Description',
          width: 8,
          styles: const PosStyles(bold: true),
        ),
        PosColumn(
          text: 'Amount',
          width: 4,
          styles: const PosStyles(bold: true, align: PosAlign.right),
        ),
      ]);
      bytes += generator.hr();

      // Table Row
      bytes += generator.row([
        PosColumn(
          text: _itemCtrl.text,
          width: 8,
        ),
        PosColumn(
          text: '\$${_amountCtrl.text}',
          width: 4,
          styles: const PosStyles(align: PosAlign.right),
        ),
      ]);
      bytes += generator.feed(1);

      // Total
      bytes += generator.text(
        'Total: \$${_amountCtrl.text}',
        styles: const PosStyles(align: PosAlign.right, bold: true),
      );

      // Cut paper and feed
      bytes += generator.feed(2);
      bytes += generator.cut();

      // 3. Open Socket directly to Printer IP on port 9100
      final printerIp = _ipCtrl.text.trim();
      final socket = await Socket.connect(printerIp, 9100, timeout: const Duration(seconds: 5));

      // 4. Send raw ESC/POS bytes and close
      socket.add(bytes);
      await socket.flush();
      await socket.close();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Receipt printed successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Connection failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isPrinting = false);
      }
    }
  }

  @override
  void dispose() {
    _ipCtrl.dispose();
    _customerNameCtrl.dispose();
    _itemCtrl.dispose();
    _amountCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WiFi Thermal Print')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _ipCtrl,
                decoration: const InputDecoration(
                  labelText: 'Printer IP Address (e.g. 192.168.1.50)',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.wifi),
                ),
                keyboardType: TextInputType.number,
                validator: (value) => value!.isEmpty ? 'IP is required' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _customerNameCtrl,
                decoration: const InputDecoration(
                  labelText: 'Customer Name',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _itemCtrl,
                decoration: const InputDecoration(
                  labelText: 'Item Description',
                  border: OutlineInputBorder(),
                ),
                validator: (value) => value!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _amountCtrl,
                decoration: const InputDecoration(
                  labelText: 'Amount',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                validator: (value) => value!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: _isPrinting ? null : _printDirectToThermal,
                  icon: _isPrinting
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Icon(Icons.receipt_long),
                  label: Text(_isPrinting ? 'Printing...' : 'Print Receipt', style: const TextStyle(fontSize: 18)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
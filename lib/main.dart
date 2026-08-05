// main.dart
//
// Offline Flutter invoice app for 80mm ESC/POS thermal printers (e.g. Xprinter XP-80)
// -------------------------------------------------------------------------------------
// IMPORTANT DESIGN NOTE (read this before you ask "where did the `pdf` package go?"):
//
// Your original spec asked for A4 PDF generation via the `pdf` package. That approach
// does NOT work for your use case, because:
//
//   1. The XP-80 is an ESC/POS 80mm thermal receipt printer, not a page-based printer.
//      It doesn't understand PDF. Port 9100 raw printing to this class of device expects
//      ESC/POS *commands* (text commands or raster image commands), not PDF bytes.
//   2. ESC/POS printers render text using built-in bitmap fonts baked into the printer's
//      firmware/codepage tables. Those tables are Latin/CJK/Cyrillic-oriented and do NOT
//      contain Myanmar (Burmese) Unicode glyphs. Sending UTF-8 Myanmar text as raw ESC/POS
//      text commands will print garbage/boxes, regardless of encoding tricks.
//
// THE FIX: We never send "text" to the printer at all. Instead we:
//   1. Draw the entire receipt ourselves using Flutter's `dart:ui` Canvas/TextPainter
//      (which DOES render Myanmar correctly, using a bundled Myanmar font — see pubspec
//      instructions below).
//   2. Rasterize that canvas into a plain RGBA bitmap in memory.
//   3. Threshold it to pure 1-bit black & white (no dithering — this is a text/line
//      receipt, not a photo, so a hard threshold gives the crispest thermal output).
//   4. Pack the 1-bit bitmap into ESC/POS "GS v 0" raster bit-image commands, chunked
//      into bands so we don't overflow the printer's small raster buffer.
//   5. Push those raw bytes directly over a TCP socket to port 9100.
//
// This is the standard, reliable technique used by production Myanmar POS apps
// (and identical to how apps print QR codes / logos on ESC/POS printers).

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const InvoicePrinterApp());
}

class InvoicePrinterApp extends StatelessWidget {
  const InvoicePrinterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Direct Invoice Printer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF2F6FED)),
      ),
      home: const InvoicePrinterScreen(),
    );
  }
}

// =====================================================================================
// ESC/POS RASTER CONFIGURATION
// =====================================================================================
// 80mm roll paper has a printable width of ~72mm. At the XP-80's native 203 DPI that is:
//     72mm / 25.4mm-per-inch * 203dpi ≈ 576 dots
// 576 is also a clean multiple of 8, which raster printing requires (8 pixels per byte).
//
// If your test print comes out cropped on the right edge or shifted, your unit is
// configured for the narrower 512-dot profile — just change kPrintWidth below to 512.
const int kPrintWidth = 576;

// Myanmar font family name — must exactly match the `family:` key you set in pubspec.yaml.
const String kMyanmarFont = 'NotoSansMyanmar';

// Max rows sent per single GS v 0 raster command. Keeping this modest avoids overflowing
// the small print buffer on cheap ESC/POS boards. 256 is a safe, widely-used value.
const int kRasterChunkHeight = 256;

class InvoicePrinterScreen extends StatefulWidget {
  const InvoicePrinterScreen({super.key});

  @override
  State<InvoicePrinterScreen> createState() => _InvoicePrinterScreenState();
}

class _InvoicePrinterScreenState extends State<InvoicePrinterScreen> {
  final _formKey = GlobalKey<FormState>();

  final _ipController = TextEditingController(text: '192.168.1.100');
  final _nameController = TextEditingController();
  final _itemController = TextEditingController();
  final _amountController = TextEditingController();

  bool _isPrinting = false;

  @override
  void dispose() {
    _ipController.dispose();
    _nameController.dispose();
    _itemController.dispose();
    _amountController.dispose();
    super.dispose();
  }

  // -----------------------------------------------------------------------------------
  // PRINT ENTRY POINT
  // -----------------------------------------------------------------------------------
  Future<void> _printReceipt() async {
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) return;

    setState(() => _isPrinting = true);

    try {
      final bytes = await _buildEscPosReceipt(
        customerName: _nameController.text.trim(),
        itemDescription: _itemController.text.trim(),
        amountText: _amountController.text.trim(),
      );

      await _sendToPrinter(
        ip: _ipController.text.trim(),
        port: 9100,
        data: bytes,
      );

      if (!mounted) return;
      _showSnack('Printed successfully.', success: true);
    } catch (e) {
      if (!mounted) return;
      _showSnack('Print failed: $e', success: false);
    } finally {
      if (mounted) setState(() => _isPrinting = false);
    }
  }

  void _showSnack(String message, {required bool success}) {
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? Colors.green.shade700 : Colors.red.shade700,
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // -----------------------------------------------------------------------------------
  // RAW TCP SOCKET PRINTING (Port 9100)
  // -----------------------------------------------------------------------------------
  Future<void> _sendToPrinter({
    required String ip,
    required int port,
    required Uint8List data,
  }) async {
    Socket? socket;
    try {
      socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
      socket.add(data);
      await socket.flush();
    } on SocketException catch (e) {
      throw 'Could not reach printer at $ip:$port (${e.osError?.message ?? e.message})';
    } on TimeoutException {
      throw 'Connection to $ip:$port timed out. Check the printer is on the same WiFi network.';
    } finally {
      await socket?.close();
    }
  }

  // -----------------------------------------------------------------------------------
  // RECEIPT GENERATION: Canvas draw -> rasterize -> threshold -> ESC/POS packing
  // -----------------------------------------------------------------------------------
  Future<Uint8List> _buildEscPosReceipt({
    required String customerName,
    required String itemDescription,
    required String amountText,
  }) async {
     double printWidth = kPrintWidth.toDouble();
    const double marginX = 24;
     double contentWidth = printWidth - marginX * 2;

    final now = DateTime.now();
    final dateStr =
        '${now.year}-${_two(now.month)}-${_two(now.day)}  ${_two(now.hour)}:${_two(now.minute)}';

    final amountValue = double.tryParse(amountText) ?? 0;
    final amountStr = _formatAmount(amountValue);

    final blocks = <_ReceiptBlock>[];
    double cursorY = 30;

    TextPainter buildPainter(
        String text, {
          double fontSize = 28,
          FontWeight weight = FontWeight.normal,
          TextAlign align = TextAlign.left,
          required double width,
        }) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: Colors.black,
            fontSize: fontSize,
            fontWeight: weight,
            fontFamily: kMyanmarFont,
            height: 1.25,
          ),
        ),
        textAlign: align,
        textDirection: TextDirection.ltr,
      );
      tp.layout(minWidth: width, maxWidth: width);
      return tp;
    }

    void addFullWidth(TextPainter tp, {double gapBefore = 6}) {
      cursorY += gapBefore;
      blocks.add(_ReceiptBlock.text(tp, Offset(0, cursorY)));
      cursorY += tp.height;
    }

    void addContent(TextPainter tp, {double gapBefore = 6}) {
      cursorY += gapBefore;
      blocks.add(_ReceiptBlock.text(tp, Offset(marginX, cursorY)));
      cursorY += tp.height;
    }

    void addDivider({double gapBefore = 14, double gapAfter = 14}) {
      cursorY += gapBefore;
      blocks.add(_ReceiptBlock.divider(Offset(marginX, cursorY), contentWidth));
      cursorY += 3;
      cursorY += gapAfter;
    }

    // Header
    addFullWidth(
      buildPainter('INVOICE', fontSize: 46, weight: FontWeight.bold, align: TextAlign.center, width: printWidth),
      gapBefore: 8,
    );

    // Date
    addContent(
      buildPainter('Date: $dateStr', fontSize: 24, width: contentWidth),
      gapBefore: 16,
    );

    // Billed To
    addContent(
      buildPainter('Billed To: $customerName', fontSize: 26, weight: FontWeight.w600, width: contentWidth),
      gapBefore: 10,
    );

    addDivider();

    // Item description
    addContent(
      buildPainter(itemDescription, fontSize: 26, width: contentWidth),
      gapBefore: 0,
    );

    // Amount (right aligned, on its own line so long Myanmar text never collides)
    addContent(
      buildPainter('Amount: $amountStr', fontSize: 26, align: TextAlign.right, width: contentWidth),
      gapBefore: 10,
    );

    addDivider();

    // Total (bold, right aligned)
    addFullWidth(
      buildPainter('TOTAL: $amountStr', fontSize: 34, weight: FontWeight.bold, align: TextAlign.right, width: printWidth - marginX),
      gapBefore: 6,
    );

    cursorY += 40; // bottom padding before the feed/cut

    final totalHeight = cursorY.ceil();

    // ---- Paint everything onto one canvas -------------------------------------------
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, printWidth, totalHeight.toDouble()));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, printWidth, totalHeight.toDouble()),
      Paint()..color = Colors.white,
    );
    for (final block in blocks) {
      if (block.isDivider) {
        canvas.drawRect(
          Rect.fromLTWH(block.offset.dx, block.offset.dy, block.dividerWidth!, 3),
          Paint()..color = Colors.black,
        );
      } else {
        block.painter!.paint(canvas, block.offset);
      }
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(printWidth.toInt(), totalHeight);

    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (byteData == null) {
      throw 'Failed to rasterize receipt image.';
    }
    final rgba = byteData.buffer.asUint8List();

    return _rgbaToEscPos(
      rgba: rgba,
      width: printWidth.toInt(),
      height: totalHeight,
    );
  }

  // -----------------------------------------------------------------------------------
  // RGBA -> pure 1-bit B/W -> chunked ESC/POS "GS v 0" raster commands
  // -----------------------------------------------------------------------------------
  Uint8List _rgbaToEscPos({
    required Uint8List rgba,
    required int width,
    required int height,
  }) {
    final bytesPerRow = (width + 7) ~/ 8;
    final packed = Uint8List(bytesPerRow * height);

    const threshold = 200; // luminance below this = printed black

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final i = (y * width + x) * 4;
        final r = rgba[i];
        final g = rgba[i + 1];
        final b = rgba[i + 2];
        final a = rgba[i + 3];

        final luminance = 0.299 * r + 0.587 * g + 0.114 * b;
        final isBlack = a > 10 && luminance < threshold;

        if (isBlack) {
          final byteIndex = y * bytesPerRow + (x >> 3);
          final bitIndex = 7 - (x & 7);
          packed[byteIndex] |= (1 << bitIndex);
        }
      }
    }

    final out = BytesBuilder();

    // ESC @  -> initialize printer
    out.add(const [0x1B, 0x40]);

    // Send in horizontal bands so we never overflow the printer's raster buffer.
    for (int y = 0; y < height; y += kRasterChunkHeight) {
      final chunkHeight = (height - y) < kRasterChunkHeight ? (height - y) : kRasterChunkHeight;
      final chunkBytes = Uint8List(bytesPerRow * chunkHeight);
      final start = y * bytesPerRow;
      final len = bytesPerRow * chunkHeight;
      chunkBytes.setRange(0, len, packed, start);

      final xL = bytesPerRow & 0xFF;
      final xH = (bytesPerRow >> 8) & 0xFF;
      final yL = chunkHeight & 0xFF;
      final yH = (chunkHeight >> 8) & 0xFF;

      // GS v 0 m xL xH yL yH d1...dk  -> print raster bit image
      out.add([0x1D, 0x76, 0x30, 0x00, xL, xH, yL, yH]);
      out.add(chunkBytes);
    }

    // Feed a few lines then partial cut (GS V 66 0). If your XP-80 has no auto-cutter,
    // this command is simply ignored by the firmware — safe either way.
    out.add(const [0x0A, 0x0A, 0x0A, 0x0A]);
    out.add(const [0x1D, 0x56, 0x42, 0x00]);

    return out.toBytes();
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _formatAmount(double value) {
    final fixed = value.toStringAsFixed(2);
    final parts = fixed.split('.');
    final intPart = parts[0];
    final buffer = StringBuffer();
    for (int i = 0; i < intPart.length; i++) {
      final posFromEnd = intPart.length - i;
      buffer.write(intPart[i]);
      if (posFromEnd > 1 && posFromEnd % 3 == 1) buffer.write(',');
    }
    return '${buffer.toString()}.${parts[1]}';
  }

  // -----------------------------------------------------------------------------------
  // UI
  // -----------------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Direct Invoice Printer'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            return SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight - 40),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Card(
                        elevation: 0,
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline, color: Theme.of(context).colorScheme.primary),
                              const SizedBox(width: 12),
                              const Expanded(
                                child: Text(
                                  'This app prints directly to your 80mm ESC/POS WiFi printer '
                                      '(e.g. Xprinter XP-80) over Port 9100. No internet or system '
                                      'print spooler is used.',
                                  style: TextStyle(fontSize: 13),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),

                      TextFormField(
                        controller: _ipController,
                        decoration: const InputDecoration(
                          labelText: 'Printer IP Address',
                          prefixIcon: Icon(Icons.wifi),
                          border: OutlineInputBorder(),
                          hintText: '192.168.0.200',
                        ),
                        keyboardType: TextInputType.number,
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Enter the printer IP address';
                          final regex = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$');
                          if (!regex.hasMatch(v.trim())) return 'Enter a valid IPv4 address';
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Customer Name',
                          prefixIcon: Icon(Icons.person_outline),
                          border: OutlineInputBorder(),
                        ),
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter customer name' : null,
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        controller: _itemController,
                        decoration: const InputDecoration(
                          labelText: 'Item Description',
                          prefixIcon: Icon(Icons.description_outlined),
                          border: OutlineInputBorder(),
                        ),
                        maxLines: 2,
                        validator: (v) => (v == null || v.trim().isEmpty) ? 'Enter item description' : null,
                      ),
                      const SizedBox(height: 16),

                      TextFormField(
                        controller: _amountController,
                        decoration: const InputDecoration(
                          labelText: 'Amount',
                          prefixIcon: Icon(Icons.payments_outlined),
                          border: OutlineInputBorder(),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                        ],
                        validator: (v) {
                          if (v == null || v.trim().isEmpty) return 'Enter an amount';
                          final val = double.tryParse(v.trim());
                          if (val == null || val <= 0) return 'Enter a valid amount';
                          return null;
                        },
                      ),

                      const SizedBox(height: 32),

                      SizedBox(
                        height: 52,
                        child: ElevatedButton(
                          onPressed: _isPrinting ? null : _printReceipt,
                          style: ElevatedButton.styleFrom(
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: _isPrinting
                              ? const SizedBox(
                            height: 22,
                            width: 22,
                            child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
                          )
                              : const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.print),
                              SizedBox(width: 10),
                              Text('Direct Print', style: TextStyle(fontSize: 16)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

// A single drawable element on the receipt canvas: either laid-out text, or a divider bar.
class _ReceiptBlock {
  final TextPainter? painter;
  final Offset offset;
  final bool isDivider;
  final double? dividerWidth;

  _ReceiptBlock.text(this.painter, this.offset)
      : isDivider = false,
        dividerWidth = null;

  _ReceiptBlock.divider(this.offset, this.dividerWidth)
      : painter = null,
        isDivider = true;
}

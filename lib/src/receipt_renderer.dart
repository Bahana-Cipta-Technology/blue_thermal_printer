import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'receipt.dart';

/// Satu tata letak untuk pratinjau dan raster thermal.
///
/// [width] (piksel raster) dan [fontFamily] sengaja jadi parameter
/// constructor, bukan konstanta tetap -- plugin ini dipakai lintas app, jadi
/// tidak boleh mengasumsikan lebar kertas 58 mm maupun font brand tertentu
/// (mis. `'Nunito'`) yang cuma dibundel oleh satu app konsumen tertentu.
/// Default `fontFamily: null` berarti font sistem.
class ReceiptRenderer {
  const ReceiptRenderer({this.width = 384, this.fontFamily});

  final int width;
  final String? fontFamily;

  // Warna tinta/kertas fisik, tidak mengikuti tema aplikasi mana pun.
  static const ink = Color(0xFF000000);
  static const paper = Color(0xFFFFFFFF);

  Future<ui.Image> render(Receipt receipt) async {
    // Raster ESC/POS dikemas 8 piksel per byte; lebar yang bukan kelipatan 8
    // membuat [encode] membaca piksel baris berikutnya (gambar bergeser) atau
    // keluar batas buffer di baris terakhir.
    if (width <= 0 || width % 8 != 0) {
      throw ArgumentError.value(
        width,
        'width',
        'harus bilangan positif kelipatan 8',
      );
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    double y = 8;
    for (final line in receipt.lines) {
      if (line is ReceiptBlank) {
        y += 8;
        continue;
      }
      if (line is ReceiptDivider) {
        canvas.drawRect(
          Rect.fromLTWH(16, y + 3, width - 32, 2),
          Paint()..color = ink,
        );
        y += 8;
        continue;
      }
      if (line is ReceiptQr) {
        // Modul berukuran bulat dengan quiet zone minimal empat modul.
        final code = QrCode.fromData(
          data: line.data,
          errorCorrectLevel: QrErrorCorrectLevel.M,
        );
        final qr = QrImage(code);
        const module = 6.0;
        final size = (qr.moduleCount + 8) * module;
        final left = (width - size) / 2 + 4 * module;
        for (var row = 0; row < qr.moduleCount; row++) {
          for (var col = 0; col < qr.moduleCount; col++) {
            if (qr.isDark(row, col)) {
              canvas.drawRect(
                Rect.fromLTWH(
                  left + col * module,
                  y + 24 + row * module,
                  module,
                  module,
                ),
                Paint()..color = ink,
              );
            }
          }
        }
        y += size;
        continue;
      }
      final text = switch (line) {
        ReceiptCenter(:final text) => text,
        ReceiptRow(:final label, :final value) => '$label: $value',
        _ => '',
      };
      final bold = switch (line) {
        ReceiptCenter(:final emphasized) => emphasized,
        ReceiptRow(:final emphasized) => emphasized,
        _ => false,
      };
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(
            color: ink,
            fontFamily: fontFamily,
            fontSize: bold ? 26 : 20,
            fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: line is ReceiptCenter ? TextAlign.center : TextAlign.left,
      )..layout(minWidth: width - 32, maxWidth: width - 32);
      painter.paint(canvas, Offset(16, y));
      y += painter.height + 3;
      painter.dispose();
    }
    final content = recorder.endRecording();
    final background = ui.PictureRecorder();
    final output = Canvas(background)..drawColor(paper, BlendMode.src);
    output.drawPicture(content);
    final picture = background.endRecording();
    final image = await picture.toImage(width, (y + 10).ceil());
    content.dispose();
    picture.dispose();
    return image;
  }

  Future<Uint8List> preview(Receipt receipt) async {
    final image = await render(receipt);
    try {
      return (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  Future<List<int>> encode(Receipt receipt) async {
    final image = await render(receipt);
    try {
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final bytes = <int>[27, 64];
      // Kirim raster per pita agar tinggi gambar tidak melampaui buffer printer.
      for (var top = 0; top < image.height; top += 128) {
        final height = (image.height - top).clamp(0, 128);
        bytes.addAll([29, 118, 48, 0, width ~/ 8, 0, height, 0]);
        for (var y = top; y < top + height; y++) {
          for (var x = 0; x < width; x += 8) {
            var value = 0;
            for (var bit = 0; bit < 8; bit++) {
              if (data.getUint8((y * width + x + bit) * 4) < 128) {
                value |= 128 >> bit;
              }
            }
            bytes.add(value);
          }
        }
      }
      bytes.addAll([27, 100, 2]);
      return bytes;
    } finally {
      image.dispose();
    }
  }
}

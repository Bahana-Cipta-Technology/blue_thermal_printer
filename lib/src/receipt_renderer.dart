import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show visibleForTesting;
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
    final int height;
    final Uint8List rgba;
    try {
      height = image.height;
      rgba = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!.buffer.asUint8List();
    } finally {
      image.dispose();
    }
    // Render dan toByteData wajib di isolate utama (`dart:ui`), tapi
    // pengemasan bit ratusan ribu piksel adalah kerja CPU murni -- dijalankan
    // di isolate terpisah supaya tidak membuat UI patah-patah di EDC kelas
    // bawah.
    final w = width;
    return Isolate.run(() => packRaster(rgba, w, height));
  }

  /// Kemas piksel RGBA jadi perintah raster ESC/POS: `ESC @`, pita
  /// `GS v 0` setinggi <=128 baris (agar tidak melampaui buffer printer),
  /// lalu feed `ESC d 2`. Piksel dengan kanal merah < 128 dicetak hitam.
  /// Fungsi murni tanpa `dart:ui`, sehingga aman dijalankan di isolate lain.
  @visibleForTesting
  static Uint8List packRaster(Uint8List rgba, int width, int height) {
    final bytesPerRow = width ~/ 8;
    final bandCount = (height + 127) ~/ 128;
    final out = Uint8List(2 + bandCount * 8 + bytesPerRow * height + 3);
    var i = 0;
    out[i++] = 27;
    out[i++] = 64;
    for (var top = 0; top < height; top += 128) {
      final bandHeight = (height - top).clamp(0, 128);
      out.setAll(i, [29, 118, 48, 0, bytesPerRow, 0, bandHeight, 0]);
      i += 8;
      for (var y = top; y < top + bandHeight; y++) {
        for (var x = 0; x < width; x += 8) {
          var value = 0;
          for (var bit = 0; bit < 8; bit++) {
            if (rgba[(y * width + x + bit) * 4] < 128) value |= 128 >> bit;
          }
          out[i++] = value;
        }
      }
    }
    out.setAll(i, const [27, 100, 2]);
    return out;
  }
}

/// Satu baris pada struk.
///
/// Model ini netral terhadap merek printer maupun app konsumen: tiap backend
/// (ESC/POS, SDK vendor) menerjemahkannya jadi perintah cetak versinya
/// sendiri.
sealed class ReceiptLine {
  const ReceiptLine();
}

/// Teks rata tengah, biasanya judul atau catatan kaki.
final class ReceiptCenter extends ReceiptLine {
  const ReceiptCenter(this.text, {this.emphasized = false});

  final String text;
  final bool emphasized;
}

/// Pasangan label di kiri dan nilai di kanan.
final class ReceiptRow extends ReceiptLine {
  const ReceiptRow(this.label, this.value, {this.emphasized = false});

  final String label;
  final String value;
  final bool emphasized;
}

/// Garis pemisah.
final class ReceiptDivider extends ReceiptLine {
  const ReceiptDivider();
}

/// Baris kosong.
final class ReceiptBlank extends ReceiptLine {
  const ReceiptBlank();
}

enum ReceiptKind { customer, vehicle }

/// QR hanya berisi nomor tiket untuk pencarian transaksi.
final class ReceiptQr extends ReceiptLine {
  const ReceiptQr(this.data);
  final String data;
}

/// Struk lengkap siap cetak.
class Receipt {
  const Receipt({
    required this.lines,
    this.width = 32,
    this.kind = ReceiptKind.customer,
  });

  final List<ReceiptLine> lines;
  final ReceiptKind kind;

  /// Lebar kertas dalam karakter. 32 setara kertas 58 mm.
  final int width;

  /// Render menjadi teks polos -- dipakai pratinjau pada mode prototipe dan
  /// berguna sebagai keluaran uji.
  String toPlainText() {
    final buffer = StringBuffer();
    for (final line in lines) {
      switch (line) {
        case ReceiptCenter(:final text):
          final pad = ((width - text.length) / 2).floor().clamp(0, width);
          buffer.writeln(' ' * pad + text);
        case ReceiptRow(:final label, :final value):
          final gap = width - label.length - value.length;
          buffer.writeln(
            gap > 0 ? '$label${' ' * gap}$value' : '$label $value',
          );
        case ReceiptDivider():
          buffer.writeln('-' * width);
        case ReceiptQr(:final data):
          buffer.writeln(data);
        case ReceiptBlank():
          buffer.writeln();
      }
    }
    return buffer.toString();
  }
}

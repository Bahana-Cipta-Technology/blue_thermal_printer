package id.kakzaki.blue_thermal_printer;

import java.io.ByteArrayOutputStream;

/**
 * Konversi piksel ARGB jadi perintah raster ESC/POS {@code GS v 0} -- Java murni (tanpa
 * {@code android.graphics.Bitmap}) supaya bisa dites JUnit; {@link Utils#decodeBitmap} cuma
 * mengambil piksel lalu mendelegasikan ke sini.
 *
 * Menggantikan implementasi lama berbasis string heksadesimal yang menulis dimensi big-endian
 * tanpa padding (mis. tinggi 300 jadi {@code "12c"+"00"}), sehingga header gambar setinggi
 * &ge;256 piksel rusak dan printer membaca sisa data sebagai gambar raksasa.
 */
public final class RasterImageEncoder {

  /** Tinggi maksimum satu pita {@code GS v 0} -- menjaga satu perintah tetap muat di buffer
   * printer murah, sama seperti encoder Dart ({@code ReceiptRenderer.encode}). */
  public static final int MAX_BAND_HEIGHT = 128;

  // Ambang batas kecerahan RGB (0-255) untuk anggap piksel "putih".
  static final int WHITE_PIXEL_THRESHOLD = 160;

  private RasterImageEncoder() {}

  /**
   * @param argb piksel baris demi baris ({@code width * height} elemen, format
   *     {@code Bitmap.getPixels}).
   * @return perintah {@code GS v 0} (dipecah per pita {@link #MAX_BAND_HEIGHT} baris), atau
   *     {@code null} bila dimensinya tidak valid.
   */
  public static byte[] encode(int[] argb, int width, int height) {
    if (width <= 0 || height <= 0 || argb == null || argb.length < width * height) {
      return null;
    }
    int bytesPerRow = (width + 7) / 8;
    if (bytesPerRow > 0xFFFF) return null;

    ByteArrayOutputStream out = new ByteArrayOutputStream(
        bytesPerRow * height + 8 * ((height + MAX_BAND_HEIGHT - 1) / MAX_BAND_HEIGHT));
    for (int top = 0; top < height; top += MAX_BAND_HEIGHT) {
      int bandHeight = Math.min(MAX_BAND_HEIGHT, height - top);
      // GS v 0 m xL xH yL yH -- dimensi little-endian.
      out.write(0x1D);
      out.write(0x76);
      out.write(0x30);
      out.write(0x00);
      out.write(bytesPerRow & 0xFF);
      out.write((bytesPerRow >> 8) & 0xFF);
      out.write(bandHeight & 0xFF);
      out.write((bandHeight >> 8) & 0xFF);
      for (int y = top; y < top + bandHeight; y++) {
        int rowOffset = y * width;
        for (int column = 0; column < bytesPerRow; column++) {
          int value = 0;
          for (int bit = 0; bit < 8; bit++) {
            int x = column * 8 + bit;
            // Kolom padding di luar lebar gambar dibiarkan putih (bit 0).
            if (x < width && isDark(argb[rowOffset + x])) {
              value |= 0x80 >> bit;
            }
          }
          out.write(value);
        }
      }
    }
    return out.toByteArray();
  }

  /** Piksel dikomposit di atas kertas putih dulu, supaya area transparan (alpha 0) tercetak
   * putih -- bukan hitam seperti implementasi lama yang mengabaikan alpha. */
  static boolean isDark(int pixel) {
    int alpha = (pixel >>> 24) & 0xFF;
    int r = composite((pixel >> 16) & 0xFF, alpha);
    int g = composite((pixel >> 8) & 0xFF, alpha);
    int b = composite(pixel & 0xFF, alpha);
    return !(r > WHITE_PIXEL_THRESHOLD && g > WHITE_PIXEL_THRESHOLD && b > WHITE_PIXEL_THRESHOLD);
  }

  private static int composite(int channel, int alpha) {
    return (channel * alpha + 255 * (255 - alpha)) / 255;
  }
}

package id.kakzaki.blue_thermal_printer;

/**
 * Helper murni (tanpa dependency Android) untuk respons {@code GS I n} (transmit printer ID) --
 * dipisah dari {@link BlueThermalPrinterPlugin} dan transport LAN/USB supaya bisa dites JUnit.
 */
public final class EscPosPrinterId {

  private EscPosPrinterId() {}

  /** Nomor {@code n} untuk Type ID pada {@code GS I n}. */
  public static final int TYPE_ID = 2;

  /** Bit Type ID yang menandakan autocutter terpasang. */
  public static final int AUTO_CUTTER_BIT = 0x02;

  /**
   * Byte ID 1-byte ({@code GS I 1..3}) punya bit 4 = 0 dan bit 7 = 0 (tetap, menurut spesifikasi
   * ESC/POS). Status {@code DLE EOT} dan XON {@code 0x11}/XOFF {@code 0x13} justru bit 4 = 1,
   * jadi keduanya tidak pernah terbaca sebagai ID.
   */
  public static boolean isValidIdResponse(int value) {
    return (value & 0x90) == 0x00;
  }

  /**
   * Indeks byte pertama di {@code buffer[0..length)} yang merupakan respons ID sah, atau
   * {@code -1} kalau tidak ada.
   */
  public static int indexOfIdResponse(byte[] buffer, int length) {
    for (int i = 0; i < length; i++) {
      if (isValidIdResponse(buffer[i] & 0xFF)) return i;
    }
    return -1;
  }

  /** Perintah {@code GS I n} untuk {@code idType} 1..3, atau {@code null} bila tidak didukung. */
  public static byte[] queryCommand(int idType) {
    if (idType < 1 || idType > 3) return null;
    return new byte[] {0x1D, 0x49, (byte) idType};
  }
}

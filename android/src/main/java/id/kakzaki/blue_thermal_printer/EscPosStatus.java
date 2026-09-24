package id.kakzaki.blue_thermal_printer;

/**
 * Helper murni (tanpa dependency Android) untuk respons query status real-time ESC/POS
 * ({@code DLE EOT n}) -- dipisah dari {@link BlueThermalPrinterPlugin} supaya bisa dites JUnit.
 */
public final class EscPosStatus {

  private EscPosStatus() {}

  /**
   * Semua respons {@code DLE EOT n} (n = 1..4) punya pola bit tetap: bit 0 = 0, bit 1 = 1,
   * bit 4 = 1, bit 7 = 0. Byte lain yang lewat di socket yang sama (mis. XON {@code 0x11}/XOFF
   * {@code 0x13} dari flow control, sisa data, atau sampah) tidak boleh dibaca sebagai status.
   */
  public static boolean isValidRealtimeStatus(int value) {
    return (value & 0x93) == 0x12;
  }

  /**
   * Indeks byte pertama di {@code buffer[0..length)} yang merupakan respons status sah, atau
   * {@code -1} kalau tidak ada.
   */
  public static int indexOfRealtimeStatus(byte[] buffer, int length) {
    for (int i = 0; i < length; i++) {
      if (isValidRealtimeStatus(buffer[i] & 0xFF)) return i;
    }
    return -1;
  }
}

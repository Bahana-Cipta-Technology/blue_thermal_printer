package id.kakzaki.blue_thermal_printer.transport;

import id.kakzaki.blue_thermal_printer.PrinterCommands;

/**
 * Helper murni (tanpa dependency Android) bersama transport ESC/POS LAN dan USB -- dipisah supaya
 * bisa dites JUnit.
 */
public final class TransportSupport {

  private TransportSupport() {}

  /** Batas waktu menunggu satu byte respons {@code DLE EOT} (sama dengan jalur Bluetooth). */
  public static final long STATUS_QUERY_TIMEOUT_MILLIS = 1_500;

  /** Potongan maksimum satu {@code bulkTransfer} USB. */
  public static final int USB_CHUNK_BYTES = 16 * 1024;

  /** Kelas interface USB printer (USB Printer Class 1.1). */
  public static final int USB_CLASS_PRINTER = 7;

  /** Kelas interface vendor-specific -- dipakai banyak printer ESC/POS murah. */
  public static final int USB_CLASS_VENDOR_SPEC = 0xFF;

  /** Kelas interface CDC Data -- printer ESC/POS yang tampil sebagai "virtual COM port". */
  public static final int USB_CLASS_CDC_DATA = 0x0A;

  /**
   * Perintah {@code DLE EOT n} untuk {@code statusType} 1..4 (penomoran sama dengan
   * {@code BlueThermalPrinter.statusType*}), atau {@code null} bila tidak didukung.
   */
  public static byte[] statusQueryCommand(int statusType) {
    switch (statusType) {
      case 1:
        return PrinterCommands.TRANSMIT_DLE_PRINTER_STATUS;
      case 2:
        return PrinterCommands.TRANSMIT_DLE_OFFLINE_PRINTER_STATUS;
      case 3:
        return PrinterCommands.TRANSMIT_DLE_ERROR_STATUS;
      case 4:
        return PrinterCommands.TRANSMIT_DLE_ROLL_PAPER_SENSOR_STATUS;
      default:
        return null;
    }
  }

  /**
   * Prioritas interface USB sebagai jalur cetak ESC/POS (lebih kecil = lebih diutamakan), atau
   * {@code -1} bila kelas ini jelas bukan printer (mis. mass storage, HID, audio) -- supaya flashdisk
   * atau keyboard tidak muncul di daftar printer.
   */
  public static int usbInterfacePriority(int interfaceClass) {
    switch (interfaceClass) {
      case USB_CLASS_PRINTER:
        return 0;
      case USB_CLASS_VENDOR_SPEC:
        return 1;
      case USB_CLASS_CDC_DATA:
        return 2;
      default:
        return -1;
    }
  }
}

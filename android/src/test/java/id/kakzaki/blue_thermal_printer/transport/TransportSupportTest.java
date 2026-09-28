package id.kakzaki.blue_thermal_printer.transport;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class TransportSupportTest {

  @Test
  public void statusQueryCommandMapsTypesToDleEot() {
    assertArrayEquals(new byte[] {0x10, 0x04, 0x01}, TransportSupport.statusQueryCommand(1));
    assertArrayEquals(new byte[] {0x10, 0x04, 0x02}, TransportSupport.statusQueryCommand(2));
    assertArrayEquals(new byte[] {0x10, 0x04, 0x03}, TransportSupport.statusQueryCommand(3));
    assertArrayEquals(new byte[] {0x10, 0x04, 0x04}, TransportSupport.statusQueryCommand(4));
    assertNull(TransportSupport.statusQueryCommand(0));
    assertNull(TransportSupport.statusQueryCommand(5));
  }

  @Test
  public void printerClassIsPreferredOverVendorAndCdc() {
    int printer = TransportSupport.usbInterfacePriority(7);
    int vendor = TransportSupport.usbInterfacePriority(0xFF);
    int cdc = TransportSupport.usbInterfacePriority(0x0A);
    assertEquals(0, printer);
    assertTrue(printer < vendor);
    assertTrue(vendor < cdc);
  }

  @Test
  public void nonPrinterClassesAreRejected() {
    assertEquals(-1, TransportSupport.usbInterfacePriority(8)); // mass storage
    assertEquals(-1, TransportSupport.usbInterfacePriority(3)); // HID
    assertEquals(-1, TransportSupport.usbInterfacePriority(1)); // audio
    assertEquals(-1, TransportSupport.usbInterfacePriority(2)); // CDC control
  }
}

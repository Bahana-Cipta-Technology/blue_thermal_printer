package id.kakzaki.blue_thermal_printer;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class EscPosPrinterIdTest {

  @Test
  public void acceptsTypeIdsWithFixedBitsClear() {
    assertTrue(EscPosPrinterId.isValidIdResponse(0x00)); // tanpa cutter
    assertTrue(EscPosPrinterId.isValidIdResponse(0x02)); // autocutter
    assertTrue(EscPosPrinterId.isValidIdResponse(0x03)); // autocutter + multi-byte
    assertTrue(EscPosPrinterId.isValidIdResponse(0x6F));
  }

  @Test
  public void rejectsStatusFlowControlAndGarbageBytes() {
    assertFalse(EscPosPrinterId.isValidIdResponse(0x11)); // XON
    assertFalse(EscPosPrinterId.isValidIdResponse(0x13)); // XOFF
    assertFalse(EscPosPrinterId.isValidIdResponse(0x12)); // status DLE EOT normal
    assertFalse(EscPosPrinterId.isValidIdResponse(0x32)); // status DLE EOT kertas habis
    assertFalse(EscPosPrinterId.isValidIdResponse(0x82)); // bit 7 menyala
    assertFalse(EscPosPrinterId.isValidIdResponse(0xFF));
  }

  @Test
  public void neverAcceptsAValidRealtimeStatusByte() {
    for (int value = 0; value < 256; value++) {
      if (EscPosStatus.isValidRealtimeStatus(value)) {
        assertFalse(EscPosPrinterId.isValidIdResponse(value));
      }
    }
  }

  @Test
  public void findsFirstValidIdByteInChunk() {
    byte[] chunk = {0x11, 0x12, 0x02, 0x00};
    assertEquals(2, EscPosPrinterId.indexOfIdResponse(chunk, chunk.length));
    assertEquals(-1, EscPosPrinterId.indexOfIdResponse(chunk, 2));
  }

  @Test
  public void treatsBytesAsUnsigned() {
    byte[] chunk = {(byte) 0x82, 0x02};
    assertEquals(1, EscPosPrinterId.indexOfIdResponse(chunk, chunk.length));
  }

  @Test
  public void buildsQueryCommandForSupportedTypesOnly() {
    assertArrayEquals(new byte[] {0x1D, 0x49, 0x02}, EscPosPrinterId.queryCommand(2));
    assertNull(EscPosPrinterId.queryCommand(0));
    assertNull(EscPosPrinterId.queryCommand(4));
  }
}

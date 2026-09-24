package id.kakzaki.blue_thermal_printer;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class EscPosStatusTest {

  @Test
  public void acceptsResponsesWithFixedBitPattern() {
    // 0x12 = printer normal; 0x16 = cover terbuka; 0x32 = kertas habis; 0x52 = galat.
    assertTrue(EscPosStatus.isValidRealtimeStatus(0x12));
    assertTrue(EscPosStatus.isValidRealtimeStatus(0x16));
    assertTrue(EscPosStatus.isValidRealtimeStatus(0x32));
    assertTrue(EscPosStatus.isValidRealtimeStatus(0x52));
    assertTrue(EscPosStatus.isValidRealtimeStatus(0x7E));
  }

  @Test
  public void rejectsFlowControlAndGarbageBytes() {
    assertFalse(EscPosStatus.isValidRealtimeStatus(0x11)); // XON
    assertFalse(EscPosStatus.isValidRealtimeStatus(0x13)); // XOFF
    assertFalse(EscPosStatus.isValidRealtimeStatus(0x00));
    assertFalse(EscPosStatus.isValidRealtimeStatus(0xFF));
    assertFalse(EscPosStatus.isValidRealtimeStatus(0x92)); // bit 7 menyala
  }

  @Test
  public void findsFirstValidStatusByteInChunk() {
    byte[] chunk = {0x11, 0x13, 0x32, 0x12};
    assertEquals(2, EscPosStatus.indexOfRealtimeStatus(chunk, chunk.length));
    assertEquals(-1, EscPosStatus.indexOfRealtimeStatus(chunk, 2));
  }

  @Test
  public void treatsBytesAsUnsigned() {
    byte[] chunk = {(byte) 0x92, 0x12};
    assertEquals(1, EscPosStatus.indexOfRealtimeStatus(chunk, chunk.length));
  }
}

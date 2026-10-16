package id.kakzaki.blue_thermal_printer.vendor.ciontek;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;

import org.junit.Test;

public class CiontekResultCodesTest {

  @Test
  public void zeroMeansPrinted() {
    assertEquals(CiontekResultCodes.OUTCOME_PRINTED, CiontekResultCodes.startOutcome(0));
  }

  @Test
  public void documentedFailuresAreFailed() {
    int[] codes = {-1, -1014, -1015, -1021, -2, -1022, -3, -1023, -1007, -1009, -1012};
    for (int code : codes) {
      assertEquals("kode " + code, CiontekResultCodes.OUTCOME_FAILED,
          CiontekResultCodes.startOutcome(code));
    }
  }

  @Test
  public void timeoutsAndUndocumentedCodesAreUnknown() {
    int[] codes = {-1000, -1001, 1001, -1002, 1002, -1003, -1004, -1016, -1017, -1020, 8, 9,
        -1006, -1013, -4008, -5555, 42};
    for (int code : codes) {
      assertEquals("kode " + code, CiontekResultCodes.OUTCOME_UNKNOWN,
          CiontekResultCodes.startOutcome(code));
    }
  }

  @Test
  public void splitsIntoStripsNoTallerThanMax() {
    int[][] strips = CiontekResultCodes.strips(1000, 480);
    assertEquals(3, strips.length);
    assertArrayEquals(new int[] {0, 480}, strips[0]);
    assertArrayEquals(new int[] {480, 480}, strips[1]);
    assertArrayEquals(new int[] {960, 40}, strips[2]);
  }

  @Test
  public void exactMultipleHasNoEmptyTail() {
    int[][] strips = CiontekResultCodes.strips(960, 480);
    assertEquals(2, strips.length);
    assertArrayEquals(new int[] {480, 480}, strips[1]);
  }

  @Test
  public void emptyBitmapHasNoStrips() {
    assertEquals(0, CiontekResultCodes.strips(0, 480).length);
  }

  @Test(expected = IllegalArgumentException.class)
  public void rejectsNonPositiveStripHeight() {
    CiontekResultCodes.strips(100, 0);
  }
}

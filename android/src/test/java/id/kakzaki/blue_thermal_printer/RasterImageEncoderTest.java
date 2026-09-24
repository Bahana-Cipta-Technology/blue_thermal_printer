package id.kakzaki.blue_thermal_printer;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import java.util.Arrays;

import org.junit.Test;

public class RasterImageEncoderTest {

  private static final int WHITE = 0xFFFFFFFF;
  private static final int BLACK = 0xFF000000;
  private static final int TRANSPARENT = 0x00000000;

  private static int[] filled(int width, int height, int color) {
    int[] pixels = new int[width * height];
    Arrays.fill(pixels, color);
    return pixels;
  }

  /** Header GS v 0 pada offset tertentu: {xL, xH, yL, yH} sebagai int tak-bertanda. */
  private static int[] headerAt(byte[] out, int offset) {
    assertEquals(0x1D, out[offset] & 0xFF);
    assertEquals(0x76, out[offset + 1] & 0xFF);
    assertEquals(0x30, out[offset + 2] & 0xFF);
    assertEquals(0x00, out[offset + 3] & 0xFF);
    return new int[] {
        out[offset + 4] & 0xFF, out[offset + 5] & 0xFF, out[offset + 6] & 0xFF, out[offset + 7] & 0xFF
    };
  }

  @Test
  public void singleRowImageHasLittleEndianHeader() {
    byte[] out = RasterImageEncoder.encode(filled(8, 1, BLACK), 8, 1);
    assertArrayEquals(new int[] {1, 0, 1, 0}, headerAt(out, 0));
    assertEquals(9, out.length);
    assertEquals(0xFF, out[8] & 0xFF);
  }

  @Test
  public void heightAbove255IsSplitIntoValidBands() {
    // Implementasi lama menulis tinggi 300 sebagai "12c"+"00" -- header rusak.
    int width = 16;
    int height = 300;
    byte[] out = RasterImageEncoder.encode(filled(width, height, WHITE), width, height);
    int offset = 0;
    int totalRows = 0;
    while (offset < out.length) {
      int[] header = headerAt(out, offset);
      assertEquals(2, header[0] | (header[1] << 8));
      int rows = header[2] | (header[3] << 8);
      assertEquals(true, rows > 0 && rows <= RasterImageEncoder.MAX_BAND_HEIGHT);
      totalRows += rows;
      offset += 8 + rows * 2;
    }
    assertEquals(height, totalRows);
    assertEquals(out.length, offset);
  }

  @Test
  public void heightOf256ProducesExactlyTwoBands() {
    byte[] out = RasterImageEncoder.encode(filled(8, 256, WHITE), 8, 256);
    assertEquals(2 * (8 + 128), out.length);
    assertArrayEquals(new int[] {1, 0, 128, 0}, headerAt(out, 0));
    assertArrayEquals(new int[] {1, 0, 128, 0}, headerAt(out, 8 + 128));
  }

  @Test
  public void tallImageKeepsEveryRow() {
    byte[] out = RasterImageEncoder.encode(filled(384, 1000, WHITE), 384, 1000);
    int bands = (1000 + 127) / 128;
    assertEquals(bands * 8 + 1000 * 48, out.length);
  }

  @Test
  public void widthNotMultipleOfEightIsPaddedWithWhite() {
    // Lebar 10 -> 2 byte per baris; 6 bit terakhir byte kedua adalah padding putih.
    byte[] out = RasterImageEncoder.encode(filled(10, 1, BLACK), 10, 1);
    assertArrayEquals(new int[] {2, 0, 1, 0}, headerAt(out, 0));
    assertEquals(0xFF, out[8] & 0xFF);
    assertEquals(0xC0, out[9] & 0xFF);
  }

  @Test
  public void transparentPixelsPrintWhite() {
    byte[] out = RasterImageEncoder.encode(filled(8, 1, TRANSPARENT), 8, 1);
    assertEquals(0x00, out[8] & 0xFF);
  }

  @Test
  public void bitOrderIsMostSignificantBitFirst() {
    int[] pixels = filled(8, 1, WHITE);
    pixels[0] = BLACK;
    pixels[7] = BLACK;
    byte[] out = RasterImageEncoder.encode(pixels, 8, 1);
    assertEquals(0x81, out[8] & 0xFF);
  }

  @Test
  public void rejectsInvalidDimensions() {
    assertNull(RasterImageEncoder.encode(new int[0], 0, 1));
    assertNull(RasterImageEncoder.encode(new int[0], 1, 0));
    assertNull(RasterImageEncoder.encode(new int[3], 2, 2));
  }
}

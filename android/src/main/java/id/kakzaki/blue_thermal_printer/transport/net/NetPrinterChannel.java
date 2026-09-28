package id.kakzaki.blue_thermal_printer.transport.net;

import android.os.Handler;
import android.os.Looper;
import android.util.Log;

import androidx.annotation.NonNull;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

import id.kakzaki.blue_thermal_printer.EscPosStatus;
import id.kakzaki.blue_thermal_printer.transport.TransportSupport;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.MethodChannel.MethodCallHandler;
import io.flutter.plugin.common.MethodChannel.Result;

/**
 * Transport ESC/POS lewat TCP (port RAW, default 9100) -- channel "blue_thermal_printer/escpos_net",
 * terpisah dari channel Bluetooth lama dan channel vendor.
 *
 * <p>Model thread: semua operasi socket (connect, tulis, query status) serial di {@link #ioExecutor}
 * supaya byte query status tidak pernah menyela data struk. {@code disconnect} sengaja jalan di
 * {@link #controlExecutor} terpisah: menutup socket dari thread lain adalah satu-satunya cara
 * melepas tulis yang macet (dipanggil {@code PrintJobGate.onStuck} di Dart).
 */
public class NetPrinterChannel implements MethodCallHandler {

  public static final String CHANNEL_NAME = "blue_thermal_printer/escpos_net";

  private static final String TAG = "NetPrinterChannel";
  private static final int CONNECT_TIMEOUT_MILLIS = 5_000;

  private final MethodChannel channel;
  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  private final ExecutorService ioExecutor = Executors.newSingleThreadExecutor();
  private final ExecutorService controlExecutor = Executors.newSingleThreadExecutor();
  private final AtomicReference<Connection> connectionRef = new AtomicReference<>();

  public NetPrinterChannel(BinaryMessenger messenger) {
    channel = new MethodChannel(messenger, CHANNEL_NAME);
    channel.setMethodCallHandler(this);
  }

  @Override
  public void onMethodCall(@NonNull MethodCall call, @NonNull Result result) {
    switch (call.method) {
      case "isAvailable":
        result.success(true);
        break;

      case "connect": {
        String host = call.argument("host");
        Integer port = call.argument("port");
        if (host == null || port == null) {
          result.error("invalid_argument", "arguments 'host' and 'port' are required", null);
          break;
        }
        run(ioExecutor, result, () -> connect(host, port));
        break;
      }

      case "disconnect":
        run(controlExecutor, result, () -> {
          closeConnection(connectionRef.getAndSet(null));
          return null;
        });
        break;

      case "isConnected":
        result.success(activeConnection() != null);
        break;

      case "writeBytes": {
        byte[] bytes = call.argument("bytes");
        if (bytes == null) {
          result.error("invalid_argument", "argument 'bytes' not found", null);
          break;
        }
        run(ioExecutor, result, () -> write(bytes));
        break;
      }

      case "queryStatus": {
        Integer type = call.argument("type");
        byte[] command = type == null ? null : TransportSupport.statusQueryCommand(type);
        if (command == null) {
          result.error("invalid_argument", "unsupported status type: " + type, null);
          break;
        }
        run(ioExecutor, result, () -> queryStatus(command));
        break;
      }

      default:
        result.notImplemented();
    }
  }

  public void dispose() {
    channel.setMethodCallHandler(null);
    closeConnection(connectionRef.getAndSet(null));
    ioExecutor.shutdownNow();
    controlExecutor.shutdownNow();
  }

  // ---------------------------------------------------------------------------------------------
  // Operasi socket (selalu di ioExecutor)
  // ---------------------------------------------------------------------------------------------

  private boolean connect(String host, int port) {
    Connection existing = activeConnection();
    if (existing != null) {
      // Idempoten ke alamat yang sama (ensureConnected sebelum tiap cetak), seperti jalur BT.
      if (existing.host.equals(host) && existing.port == port) return true;
      closeConnection(connectionRef.getAndSet(null));
    }
    Socket socket = new Socket();
    try {
      socket.connect(new InetSocketAddress(host, port), CONNECT_TIMEOUT_MILLIS);
      socket.setTcpNoDelay(true);
      socket.setKeepAlive(true);
      Connection connection = new Connection(socket, host, port);
      // start() dulu baru dipublikasikan: activeConnection() menganggap reader yang belum hidup
      // sebagai koneksi mati.
      connection.reader.start();
      connectionRef.set(connection);
      return true;
    } catch (IOException | RuntimeException error) {
      Log.w(TAG, "connect " + host + ":" + port + " failed", error);
      closeQuietly(socket);
      return false;
    }
  }

  private boolean write(byte[] bytes) {
    Connection connection = activeConnection();
    if (connection == null) return false;
    try {
      connection.out.write(bytes);
      connection.out.flush();
      return true;
    } catch (IOException error) {
      Log.w(TAG, "write failed", error);
      connectionRef.compareAndSet(connection, null);
      closeConnection(connection);
      return false;
    }
  }

  /** Byte respons {@code DLE EOT} yang sah, atau {@code null} bila printer tidak menjawab. */
  private Integer queryStatus(byte[] command) throws InterruptedException {
    Connection connection = activeConnection();
    if (connection == null) return null;
    connection.statusMailbox.clear();
    connection.awaitingStatus = true;
    try {
      connection.out.write(command);
      connection.out.flush();
      Byte response = connection.statusMailbox.poll(
          TransportSupport.STATUS_QUERY_TIMEOUT_MILLIS, TimeUnit.MILLISECONDS);
      if (response == null) {
        Log.w(TAG, "queryStatus: no response -- printer may not support DLE EOT");
        return null;
      }
      return response & 0xFF;
    } catch (IOException error) {
      Log.w(TAG, "queryStatus write failed", error);
      connectionRef.compareAndSet(connection, null);
      closeConnection(connection);
      return null;
    } finally {
      connection.awaitingStatus = false;
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Koneksi
  // ---------------------------------------------------------------------------------------------

  /** Koneksi yang masih hidup, sekaligus membuang koneksi yang sudah mati. */
  private Connection activeConnection() {
    Connection connection = connectionRef.get();
    if (connection == null) return null;
    if (connection.isUsable()) return connection;
    connectionRef.compareAndSet(connection, null);
    closeConnection(connection);
    return null;
  }

  private static void closeConnection(Connection connection) {
    if (connection == null) return;
    connection.closed = true;
    closeQuietly(connection.socket);
  }

  private static void closeQuietly(Socket socket) {
    try {
      socket.close();
    } catch (IOException ignored) {
      // Sudah tertutup.
    }
  }

  /**
   * Satu socket TCP ke printer. {@link #reader} adalah satu-satunya pembaca InputStream: byte
   * status yang sah dialihkan ke {@link #statusMailbox} selama query ditunggu, sisanya dibuang
   * (tidak ada event channel "read" untuk LAN). Saat socket putus, reader menandai koneksi mati
   * supaya connect berikutnya membuka socket baru.
   */
  private final class Connection {
    final Socket socket;
    final String host;
    final int port;
    final InputStream in;
    final OutputStream out;
    final ArrayBlockingQueue<Byte> statusMailbox = new ArrayBlockingQueue<>(1);
    final Thread reader;
    volatile boolean awaitingStatus = false;
    volatile boolean closed = false;

    Connection(Socket socket, String host, int port) throws IOException {
      this.socket = socket;
      this.host = host;
      this.port = port;
      this.in = socket.getInputStream();
      this.out = socket.getOutputStream();
      this.reader = new Thread(this::readLoop, "escpos-net-reader");
      this.reader.setDaemon(true);
    }

    boolean isUsable() {
      return !closed && !socket.isClosed() && socket.isConnected() && reader.isAlive();
    }

    private void readLoop() {
      byte[] buffer = new byte[256];
      try {
        while (!closed) {
          int count = in.read(buffer);
          if (count < 0) break;
          if (count == 0 || !awaitingStatus) continue;
          int index = EscPosStatus.indexOfRealtimeStatus(buffer, count);
          if (index >= 0) {
            awaitingStatus = false;
            statusMailbox.offer(buffer[index]);
          }
        }
      } catch (IOException ignored) {
        // Socket putus/ditutup.
      } finally {
        closed = true;
        connectionRef.compareAndSet(this, null);
        closeQuietly(socket);
      }
    }
  }

  // ---------------------------------------------------------------------------------------------
  // Utilitas channel
  // ---------------------------------------------------------------------------------------------

  private interface Task {
    Object run() throws Exception;
  }

  /** Jalankan {@code task} di {@code executor}, lalu kirim hasilnya lewat main thread (syarat
   * {@link Result}). Operasi socket tidak boleh di main thread: sejak Flutter 3.29 Dart di Android
   * berjalan di main thread, jadi IO di sini akan membekukan UI. */
  private void run(ExecutorService executor, Result result, Task task) {
    try {
      executor.execute(() -> {
        Object value;
        try {
          value = task.run();
        } catch (Exception error) {
          Log.w(TAG, "task failed", error);
          mainHandler.post(() -> result.error("io_error", String.valueOf(error.getMessage()), null));
          return;
        }
        mainHandler.post(() -> result.success(value));
      });
    } catch (RejectedExecutionException error) {
      result.error("disposed", "printer channel disposed", null);
    }
  }
}

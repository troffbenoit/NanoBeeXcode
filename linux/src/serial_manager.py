import glob
import threading
import time
from typing import Callable, Optional

import serial

from protocol import ParsedResponse, parse_response


class SerialManager:
    """
    Linux serial manager for NanoBee.

    Responsibilities:
      - Discover Linux serial devices
      - Connect/disconnect
      - Send newline-terminated commands
      - Receive complete lines
      - Parse Nano responses
      - Maintain keepalive/watchdog
      - Provide callbacks for the GUI
    """

    DEFAULT_BAUD = 115200

    KEEPALIVE_INTERVAL = 10.0
    LINK_TIMEOUT = 25.0
    MAX_STRIKES = 3

    def __init__(self) -> None:
        self.serial_port: Optional[serial.Serial] = None
        self.port_path: str = ""
        self.baud_rate: int = self.DEFAULT_BAUD

        self.is_connected: bool = False
        self.is_link_alive: bool = False

        self.last_rx_time: float = 0.0
        self.missed_strikes: int = 0

        self._stop_event = threading.Event()
        self._read_thread: Optional[threading.Thread] = None
        self._keepalive_thread: Optional[threading.Thread] = None

        self.line_callback: Optional[Callable[[str], None]] = None
        self.response_callback: Optional[Callable[[ParsedResponse], None]] = None
        self.log_callback: Optional[Callable[[str], None]] = None
        self.connection_callback: Optional[Callable[[bool], None]] = None

    # ---------------------------------------------------------
    # Port discovery
    # ---------------------------------------------------------

    @staticmethod
    def available_ports() -> list[str]:
        candidates = []

        patterns = (
            "/dev/ttyUSB*",
            "/dev/ttyACM*",
        )

        for pattern in patterns:
            candidates.extend(glob.glob(pattern))

        return sorted(set(candidates))

    # ---------------------------------------------------------
    # Logging
    # ---------------------------------------------------------

    def _log(self, text: str) -> None:
        if self.log_callback is not None:
            self.log_callback(text)

    # ---------------------------------------------------------
    # Connection
    # ---------------------------------------------------------

    def connect(self, path: str, baud_rate: int = DEFAULT_BAUD) -> bool:
        if self.is_connected:
            self.disconnect()

        try:
            port = serial.Serial(
                port=path,
                baudrate=baud_rate,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=0.25,
                write_timeout=1.0,
                xonxoff=False,
                rtscts=False,
                dsrdtr=False,
            )
        except serial.SerialException as exc:
            self._log(f"[ERROR] Failed to open {path}: {exc}")
            return False

        self.serial_port = port
        self.port_path = path
        self.baud_rate = baud_rate

        self.is_connected = True
        self.is_link_alive = True

        self.last_rx_time = time.monotonic()
        self.missed_strikes = 0

        self._stop_event.clear()

        self._read_thread = threading.Thread(
            target=self._read_loop,
            name="NanoBeeSerialRX",
            daemon=True,
        )

        self._keepalive_thread = threading.Thread(
            target=self._keepalive_loop,
            name="NanoBeeKeepAlive",
            daemon=True,
        )

        self._read_thread.start()
        self._keepalive_thread.start()

        self._log(f"[INFO] Connected to {path} @ {baud_rate} baud.")

        if self.connection_callback is not None:
            self.connection_callback(True)

        return True

    def disconnect(self) -> None:
        self._stop_event.set()

        current_thread = threading.current_thread()

        read_thread = self._read_thread
        keepalive_thread = self._keepalive_thread

        if (
            read_thread is not None
            and read_thread.is_alive()
            and read_thread is not current_thread
        ):
            read_thread.join(timeout=1.0)

        if (
            keepalive_thread is not None
            and keepalive_thread.is_alive()
            and keepalive_thread is not current_thread
        ):
            keepalive_thread.join(timeout=1.0)

        self._read_thread = None
        self._keepalive_thread = None

        port = self.serial_port
        self.serial_port = None

        if port is not None:
            try:
                if port.is_open:
                    port.close()
            except serial.SerialException:
                pass

        was_connected = self.is_connected

        self.is_connected = False
        self.is_link_alive = False
        self.missed_strikes = 0

        if was_connected:
            self._log("[INFO] Disconnected.")

        if self.connection_callback is not None:
            self.connection_callback(False)
    # ---------------------------------------------------------
    # TX
    # ---------------------------------------------------------

    def send_command(self, command: str) -> bool:
        port = self.serial_port

        if port is None or not port.is_open:
            self._log("[ERROR] Cannot send: serial port is not open.")
            return False

        text = command.strip()

        if not text:
            self._log("[WARN] Ignoring empty command.")
            return False

        data = (text + "\n").encode("utf-8")

        try:
            port.write(data)
            port.flush()
        except (serial.SerialException, serial.SerialTimeoutException) as exc:
            self._log(f"[ERROR] Serial write failed: {exc}")
            return False

        self._log(f"[TX] {text}")
        return True

    # ---------------------------------------------------------
    # RX
    # ---------------------------------------------------------

    def _read_loop(self) -> None:
        while not self._stop_event.is_set():
            port = self.serial_port

            if port is None or not port.is_open:
                return

            try:
                raw = port.readline()
            except serial.SerialException as exc:
                self._log(f"[ERROR] Serial read failed: {exc}")
                self.disconnect()
                return

            if not raw:
                continue

            line = raw.decode("utf-8", errors="replace").strip()

            if not line:
                continue

            self.last_rx_time = time.monotonic()
            self.missed_strikes = 0
            self.is_link_alive = True

            self._log(f"[RX] {line}")

            if self.line_callback is not None:
                self.line_callback(line)

            response = parse_response(line)

            if self.response_callback is not None:
                self.response_callback(response)

    # ---------------------------------------------------------
    # Keepalive / watchdog
    # ---------------------------------------------------------

    def _keepalive_loop(self) -> None:
        while not self._stop_event.wait(self.KEEPALIVE_INTERVAL):
            if not self.is_connected:
                return

            self.send_command("PING")

            silence = time.monotonic() - self.last_rx_time

            if silence > self.LINK_TIMEOUT:
                self.missed_strikes += 1

                self._log(
                    f"[WARN] KeepAlive timeout strike "
                    f"{self.missed_strikes}/{self.MAX_STRIKES} "
                    f"(silence {silence:.2f}s)."
                )

                if self.missed_strikes >= self.MAX_STRIKES:
                    self._log(
                        "[ERROR] Link appears dead. "
                        "Disconnecting for safety."
                    )
                    self.disconnect()
                    return
            else:
                self.missed_strikes = 0


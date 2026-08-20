from PySide6.QtCore import QObject, Signal
from PySide6.QtWidgets import (
    QComboBox,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QPushButton,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

from serial_manager import SerialManager


class GuiSignals(QObject):
    log = Signal(str)
    connection_changed = Signal(bool)


class MainWindow(QMainWindow):
    def __init__(self) -> None:
        super().__init__()

        self.setWindowTitle("NanoBee Linux")
        self.resize(900, 600)

        self.serial_manager = SerialManager()
        self.signals = GuiSignals()

        self.serial_manager.log_callback = self.signals.log.emit
        self.serial_manager.connection_callback = (
            self.signals.connection_changed.emit
        )

        self.signals.log.connect(self.append_log)
        self.signals.connection_changed.connect(
            self.update_connection_state
        )

        self._build_ui()
        self.refresh_ports()

    def _build_ui(self) -> None:
        central = QWidget()
        self.setCentralWidget(central)

        root_layout = QVBoxLayout(central)

        title = QLabel("NanoBee")
        title.setStyleSheet("font-size: 24px; font-weight: bold;")
        root_layout.addWidget(title)

        connection_layout = QHBoxLayout()

        connection_layout.addWidget(QLabel("Port:"))

        self.port_combo = QComboBox()
        connection_layout.addWidget(self.port_combo)

        self.refresh_button = QPushButton("Refresh")
        self.refresh_button.clicked.connect(self.refresh_ports)
        connection_layout.addWidget(self.refresh_button)

        self.connect_button = QPushButton("Connect")
        self.connect_button.clicked.connect(self.toggle_connection)
        connection_layout.addWidget(self.connect_button)

        self.link_label = QLabel("Dead")
        connection_layout.addWidget(self.link_label)

        root_layout.addLayout(connection_layout)

        self.status_label = QLabel("Not connected.")
        root_layout.addWidget(self.status_label)

        self.log_box = QTextEdit()
        self.log_box.setReadOnly(True)
        root_layout.addWidget(self.log_box)

    def refresh_ports(self) -> None:
        ports = self.serial_manager.available_ports()

        current = self.port_combo.currentText()

        self.port_combo.clear()
        self.port_combo.addItems(ports)

        if current in ports:
            self.port_combo.setCurrentText(current)

        if not ports:
            self.append_log("[INFO] No serial ports found.")

    def toggle_connection(self) -> None:
        if self.serial_manager.is_connected:
            self.serial_manager.disconnect()
            return

        path = self.port_combo.currentText()

        if not path:
            self.status_label.setText("No serial port selected.")
            return

        self.status_label.setText(
            f"Connecting to {path} @ 115200 baud..."
        )

        if not self.serial_manager.connect(path, 115200):
            self.status_label.setText("Connection failed.")

    def update_connection_state(self, connected: bool) -> None:
        if connected:
            self.connect_button.setText("Disconnect")
            self.link_label.setText("Alive")
            self.status_label.setText(
                f"Connected to {self.serial_manager.port_path} "
                f"@ {self.serial_manager.baud_rate} baud."
            )
        else:
            self.connect_button.setText("Connect")
            self.link_label.setText("Dead")
            self.status_label.setText("Disconnected.")

    def append_log(self, text: str) -> None:
        self.log_box.append(text)

        scrollbar = self.log_box.verticalScrollBar()
        scrollbar.setValue(scrollbar.maximum())

    def closeEvent(self, event) -> None:
        self.serial_manager.disconnect()
        event.accept()


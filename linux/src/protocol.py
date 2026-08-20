from dataclasses import dataclass
from datetime import datetime
from typing import Optional


@dataclass
class VerifiedConfiguration:
    frequency_hz: float
    duty_cycle_percent: float
    amplitude: float
    timestamp: datetime


@dataclass
class VenomStatus:
    running: bool = False
    frequency_hz: Optional[float] = None
    on_ms: Optional[int] = None
    off_ms: Optional[int] = None


@dataclass
class ParsedResponse:
    kind: str
    raw: str

    mode: Optional[str] = None
    verified_config: Optional[VerifiedConfiguration] = None
    venom_status: Optional[VenomStatus] = None
    error_text: Optional[str] = None


def make_set_command(
    frequency_hz: float,
    duty_cycle_percent: float,
    amplitude: float,
) -> str:
    safe_frequency = max(1.0, frequency_hz)
    safe_duty = min(max(duty_cycle_percent, 0.0), 100.0)
    safe_amplitude = max(amplitude, 0.0)

    return (
        f"SET F={safe_frequency:.3f} "
        f"D={safe_duty:.3f} "
        f"A={safe_amplitude:.3f}"
    )


def make_dout_command(pin: int, value: bool) -> str:
    return f"DOUT {pin} {1 if value else 0}"


def make_vset_command(voltage: int, enabled: Optional[bool] = None) -> str:
    if voltage == 0:
        return "VSET OFF"

    if enabled is None:
        return f"VSET {voltage}"

    return f"VSET {voltage} {'ON' if enabled else 'OFF'}"


def parse_response(line: str) -> ParsedResponse:
    text = line.strip()

    if text.startswith("MODE "):
        parts = text.split(maxsplit=1)
        mode = parts[1] if len(parts) == 2 else "UNKNOWN"
        return ParsedResponse(
            kind="mode",
            raw=text,
            mode=mode,
        )

    if text == "OK STOP":
        return ParsedResponse(
            kind="stop",
            raw=text,
            venom_status=VenomStatus(running=False),
        )

    if text.startswith("OK ") and "VENOM" in text:
        if "VENOM OFF" in text:
            return ParsedResponse(
                kind="venom",
                raw=text,
                venom_status=VenomStatus(running=False),
            )

        if "VENOM ON" in text:
            status = VenomStatus(running=True)

            for token in text.split():
                if token.startswith("F="):
                    try:
                        status.frequency_hz = float(token[2:])
                    except ValueError:
                        pass

                elif token.startswith("T_ON="):
                    try:
                        status.on_ms = int(token[5:])
                    except ValueError:
                        pass

                elif token.startswith("T_OFF="):
                    try:
                        status.off_ms = int(token[6:])
                    except ValueError:
                        pass

            return ParsedResponse(
                kind="venom",
                raw=text,
                venom_status=status,
            )

    if (
        text.startswith("OK ")
        and "F=" in text
        and "D=" in text
        and "A=" in text
    ):
        freq = None
        duty = None
        amp = None

        for token in text.split():
            if token.startswith("F="):
                try:
                    freq = float(token[2:])
                except ValueError:
                    pass

            elif token.startswith("D="):
                try:
                    duty = float(token[2:])
                except ValueError:
                    pass

            elif token.startswith("A="):
                try:
                    amp = float(token[2:])
                except ValueError:
                    pass

        if freq is not None and duty is not None and amp is not None:
            return ParsedResponse(
                kind="verified_config",
                raw=text,
                verified_config=VerifiedConfiguration(
                    frequency_hz=freq,
                    duty_cycle_percent=duty,
                    amplitude=amp,
                    timestamp=datetime.now(),
                ),
            )

    if text.startswith("ERR"):
        return ParsedResponse(
            kind="error",
            raw=text,
            error_text=text,
        )

    if text.startswith("OK"):
        return ParsedResponse(
            kind="ok",
            raw=text,
        )

    return ParsedResponse(
        kind="other",
        raw=text,
    )


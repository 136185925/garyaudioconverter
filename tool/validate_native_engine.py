"""End-to-end smoke tests for all 16/24-bit conversion directions."""

import ctypes
import math
from pathlib import Path
import struct
import tempfile
import time
import wave


ROOT = Path(__file__).resolve().parents[1]
DLL = ROOT / "build/windows/x64/runner/Release/gac_audio_engine.dll"


def encode_sample(sample: int, bits: int) -> bytes:
    if bits == 16:
        return struct.pack("<h", sample)
    return (sample & 0xFFFFFF).to_bytes(3, "little", signed=False)


def decode_sample(data: bytes, bits: int) -> int:
    if bits == 16:
        return int.from_bytes(data, "little", signed=True)
    value = int.from_bytes(data, "little", signed=False)
    return value - 0x1000000 if value & 0x800000 else value


def make_source(destination: Path, sample_rate: int, bits: int) -> int:
    frames = sample_rate // 10
    peak = (1 << (bits - 1)) - 1
    with wave.open(str(destination), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(bits // 8)
        output.setframerate(sample_rate)
        samples = bytearray()
        for index in range(frames):
            sample = round(
                0.45 * peak * math.sin(2 * math.pi * 1000 * index / sample_rate)
            )
            encoded = encode_sample(sample, bits)
            samples.extend(encoded)
            samples.extend(encoded)
        output.writeframes(samples)
    return frames


def make_low_level_24bit_source(destination: Path) -> None:
    sample_rate = 48_000
    with wave.open(str(destination), "wb") as output:
        output.setnchannels(2)
        output.setsampwidth(3)
        output.setframerate(sample_rate)
        samples = bytearray()
        for index in range(4096):
            sample = round(64 * math.sin(2 * math.pi * 997 * index / sample_rate))
            encoded = encode_sample(sample, 24)
            samples.extend(encoded)
            samples.extend(encoded)
        output.writeframes(samples)


def main() -> None:
    engine = ctypes.WinDLL(str(DLL))
    engine.gac_convert_wav.argtypes = [
        ctypes.c_wchar_p,
        ctypes.c_wchar_p,
        ctypes.c_int32,
        ctypes.c_double,
        ctypes.c_int32,
        ctypes.c_int32,
        ctypes.c_int32,
    ]
    engine.gac_convert_wav.restype = ctypes.c_int32

    # rate, input bits, output bits, quality, total taps, NS5, TPDF, headroom
    cases = (
        (44_100, 16, 16, 0, 1024, 1, 1, 3.0),
        (48_000, 16, 24, 0, 768, 1, 0, -1.5),
        (44_100, 24, 16, 1, 2048, 0, 1, -1.5),
        (48_000, 24, 24, 2, 7680, 0, 0, -1.5),
    )
    with tempfile.TemporaryDirectory(prefix="gac-engine-") as temporary:
        for (
            source_rate,
            input_bits,
            output_bits,
            quality,
            taps,
            ns5,
            tpdf,
            headroom,
        ) in cases:
            source = Path(temporary) / f"source-{source_rate}-{input_bits}.wav"
            converted = Path(temporary) / (
                f"converted-{source_rate}-{input_bits}-{output_bits}.wav"
            )
            source_frames = make_source(source, source_rate, input_bits)
            started = time.perf_counter()
            result = engine.gac_convert_wav(
                str(source),
                str(converted),
                quality,
                headroom,
                output_bits,
                ns5,
                tpdf,
            )
            elapsed = time.perf_counter() - started
            assert result == 0, f"native conversion returned {result}"

            with wave.open(str(converted), "rb") as output:
                assert output.getnchannels() == 2
                assert output.getsampwidth() == output_bits // 8
                assert output.getframerate() == source_rate * 4
                expected_frames = (source_frames + taps // 4 - 1) * 4
                assert output.getnframes() == expected_frames
                raw = output.readframes(expected_frames)

            sample_bytes = output_bits // 8
            frame_bytes = sample_bytes * 2
            measurement_end = (source_frames * 4 - 4096) * frame_bytes
            left = [
                decode_sample(raw[offset : offset + sample_bytes], output_bits)
                for offset in range(
                    4096 * frame_bytes,
                    measurement_end,
                    frame_bytes,
                )
            ]
            full_scale = 1 << (output_bits - 1)
            peak = max(abs(sample) for sample in left) / full_scale
            rms = math.sqrt(sum(sample * sample for sample in left) / len(left)) / full_scale
            expected_peak = 0.45 * math.pow(10.0, headroom / 20.0)
            expected_rms = expected_peak / math.sqrt(2.0)
            assert abs(peak - expected_peak) < 0.02, peak
            assert abs(rms - expected_rms) < 0.02, rms
            print(
                f"PASS: {input_bits} -> {output_bits} bit, "
                f"{source_rate / 1000:g} -> {source_rate * 4 / 1000:g} kHz, "
                f"NS5={'on' if ns5 else 'off'}, "
                f"TPDF={'on' if tpdf else 'off'}, headroom={headroom:+.1f} dB, "
                f"peak={peak:.4f} FS, "
                f"rms={rms:.4f} FS, elapsed={elapsed:.3f}s"
            )

        low_level_source = Path(temporary) / "tpdf-low-level-24bit.wav"
        dithered = Path(temporary) / "tpdf-on-16bit.wav"
        rounded = Path(temporary) / "tpdf-off-16bit.wav"
        make_low_level_24bit_source(low_level_source)
        for destination, tpdf in ((dithered, 1), (rounded, 0)):
            result = engine.gac_convert_wav(
                str(low_level_source),
                str(destination),
                0,
                -1.5,
                16,
                0,
                tpdf,
            )
            assert result == 0, f"TPDF switch conversion returned {result}"
        with wave.open(str(dithered), "rb") as enabled_output:
            dithered_pcm = enabled_output.readframes(enabled_output.getnframes())
        with wave.open(str(rounded), "rb") as disabled_output:
            rounded_pcm = disabled_output.readframes(disabled_output.getnframes())
        assert dithered_pcm != rounded_pcm
        assert any(dithered_pcm)
        print("PASS: independent TPDF switch changes low-level 24 -> 16-bit PCM")


if __name__ == "__main__":
    main()

"""Numerically inspect the FIR prototypes used by the native engine."""

import numpy as np


QUALITY = {
    "Efficient": (1024, 768, 10.5),
    "Studio": (2048, 1536, 12.0),
    "Mastering": (10240, 7680, 14.5),
}


def minimum_phase(taps: int, beta: float, output_rate: int) -> np.ndarray:
    cutoff = 22_050 if output_rate == 176_400 else 24_000
    normalized = cutoff / output_rate
    index = np.arange(taps)
    center = (taps - 1) / 2
    linear = 2 * normalized * np.sinc(2 * normalized * (index - center))
    linear *= np.kaiser(taps, beta)
    linear /= linear.sum()
    fft_size = 1 << (taps * 32 - 1).bit_length()
    log_magnitude = np.log(np.maximum(np.abs(np.fft.fft(linear, fft_size)), 1e-14))
    cepstrum = np.fft.ifft(log_magnitude).real
    lifted = np.zeros(fft_size)
    lifted[0] = cepstrum[0]
    lifted[1 : fft_size // 2] = 2 * cepstrum[1 : fft_size // 2]
    lifted[fft_size // 2] = cepstrum[fft_size // 2]
    result = np.fft.ifft(np.exp(np.fft.fft(lifted))).real[:taps]
    return result / result.sum()


def main() -> None:
    for name, (taps_44, taps_48, beta) in QUALITY.items():
        for output_rate, taps, stop in (
            (176_400, taps_44, 24_100),
            (192_000, taps_48, 28_000),
        ):
            impulse = minimum_phase(taps, beta, output_rate)
            fft_size = 1 << 20
            response = np.fft.rfft(impulse, fft_size)
            frequency = np.fft.rfftfreq(fft_size, 1 / output_rate)
            db = 20 * np.log10(
                np.maximum(np.abs(response) / abs(response[0]), 1e-30)
            )
            passband = db[frequency <= 20_000]
            stopband = db[frequency >= stop]
            energy = np.cumsum(impulse * impulse) / np.sum(impulse * impulse)
            print(
                f"{name:9s} {output_rate / 1000:5.1f}k {taps:4d} taps  "
                f"PB {passband.min():+.6f}..{passband.max():+.6f} dB  "
                f"SB {stopband.max():.2f} dB  peak {np.argmax(abs(impulse)):4d}  "
                f"E99.9 {np.searchsorted(energy, 0.999):4d}"
            )


if __name__ == "__main__":
    main()

Open-source audio file converter，runs on Windows，converts 44.1/48khz to 176.4/192k, passband cutoff frequency 22.05/24 kHz，recommend the latest WLS MIN digital filter option，this is more advanced than the traditional kaiser-windowed Sinc truncation function

##WLS implementation includes:
- Continuous-frequency weighted least-squares design
- Raised-cosine smooth transition band
- High-weight stopband, optimizing overall image energy
- FFT-accelerated preconditioned conjugate gradient solver
- Homomorphic minimum-phase conversion, no linear-phase pre-echo
- Reuse of the existing double-precision 4-phase polyphase engine
- Weighted CLS/WLS, passband/stopband weights 1:100
- WLS output files use the WLSMIN identifier
# FIR MIN Audio Converter

A Windows desktop WAV sample-rate converter built with Flutter and a native
C++ DSP engine. It accepts uncompressed 16-bit or packed 24-bit PCM WAV files
at 44.1 or 48 kHz and writes selectable 16-bit or 24-bit 4× output at 176.4 or
192 kHz beside each source file by default, or to a selected custom folder.

## FIR MIN processing

The desktop implementation keeps the STM32 FIR MIN signal path but increases
the offline filter length substantially. Two independently selectable
minimum-phase prototype designers are available:

- **Kaiser MIN / Balanced** uses the original Kaiser-windowed sinc response
  for predictable peak sidelobe rejection.
- **WLS MIN / Natural** solves a continuous-frequency weighted least-squares
  problem. A lightly weighted raised-cosine transition preserves a smooth time
  response while a strongly weighted stopband minimizes total imaging energy.

Both prototypes are converted with the same homomorphic minimum-phase stage,
so WLS MIN remains causal and does not add linear-phase pre-ringing.

| Quality | 44.1 kHz family | 48 kHz family | Kaiser target |
| --- | ---: | ---: | ---: |
| Efficient | 1024 taps | 768 taps | ≥ 115 dB |
| Studio | 2048 taps | 1536 taps | ≥ 133 dB |
| Mastering | 10240 taps | 7680 taps | ≥ 168 dB |

The WLS normal equations have Toeplitz-plus-Hankel structure and are solved by
preconditioned conjugate gradient with FFT matrix products, allowing the 10K
Mastering design without a dense multi-gigabyte matrix. The selected prototype
is converted to minimum phase using real-cepstrum spectral factorization and
run as a four-phase polyphase interpolator. Coefficients, histories and
accumulators use double precision so the 24-bit output path is not limited by
the STM32 float runtime.
The final 16/24-bit quantizer exposes NS5 noise shaping and independent-channel
TPDF dither as separate switches. NS5 defaults to on while TPDF defaults to
off; all four combinations are supported: NS5 + TPDF, NS5 only, TPDF only, or
plain deterministic rounding. Turning TPDF off is intentionally allowed; when
reducing 24-bit material to 16-bit it can convert low-level information into
correlated quantization distortion. Saturation clears the noise-shaping
history.

Stereo and multichannel files are processed across independent native worker
threads. Flutter performs file selection and task orchestration while the C++
DLL performs FFT filter design and convolution away from the UI isolate.

## Output behavior

- 44.1 kHz input becomes 176.4 kHz.
- 48 kHz input becomes 192 kHz.
- 16→16, 16→24, 24→16 and 24→24-bit conversion are supported.
- Channel count is preserved (1–8 channels).
- The complete causal FIR tail is retained.
- Each output defaults to the folder containing its own input WAV, including
  when one queue contains files from different folders.
- Existing output names are never reused by the UI; `_2`, `_3`, and so on are
  appended automatically.
- `CLEAR LIST` removes the queue. `CLEAR FINISHED` keeps every completed item
  but resets its `COMPLETE` state to `QUEUED` for another conversion pass.
- Standard RIFF/WAV output is limited to 4 GB.

Kaiser output names use the form `song_FIRMIN_4x_176k4_24bit.wav`; WLS output
names use `song_WLSMIN_4x_176k4_24bit.wav`.

## Build

```powershell
flutter pub get
flutter build windows --release
```

The release bundle is generated under
`build/windows/x64/runner/Release/` and includes `gac_audio_engine.dll`.

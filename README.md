# FIR MIN Audio Converter

A Windows desktop WAV sample-rate converter built with Flutter and a native
C++ DSP engine. It accepts uncompressed 16-bit or packed 24-bit PCM WAV files
at 44.1 or 48 kHz and writes selectable 16-bit or 24-bit 4× output at 176.4 or
192 kHz beside each source file by default, or to a selected custom folder.

## FIR MIN processing

| Quality | 44.1 kHz family | 48 kHz family | Kaiser target |
| --- | ---: | ---: | ---: |
| Efficient | 1024 taps | 768 taps | ≥ 115 dB |
| Studio | 2048 taps | 1536 taps | ≥ 133 dB |
| Mastering | 10240 taps | 7680 taps | ≥ 168 dB |

The desktop implementation keeps the STM32 FIR MIN signal path but increases
the offline filter length substantially. Two independently selectable
minimum-phase prototype designers are available:

- **Kaiser MIN / Balanced** uses the original Kaiser-windowed sinc response
  for predictable peak sidelobe rejection.
- **WLS MIN / Natural** solves a continuous-frequency weighted least-squares
  problem. A lightly weighted raised-cosine transition preserves a smooth time
  response while a strongly weighted stopband minimizes total imaging energy.
- **WLS LINEAR / Constant phase** uses that identical WLS prototype directly,
  bypassing homomorphic conversion. Its symmetric impulse response has constant
  group delay and symmetric pre/post-ringing.

Kaiser MIN and WLS MIN are converted with the same homomorphic minimum-phase
stage, so they remain causal and do not add linear-phase pre-ringing. WLS
LINEAR deliberately skips this stage and retains the original WLS magnitude
and linear phase.

| Filter Type | Passband weight | Transition weight | Stopband weight | Transition zone half width | Phase Characteristics |
| --- | --- | --- | --- | --- | --- |
| WLS MIN | 1.0 | 0.1 | 100,000 | 11π/N | Minimum-phase |
| WLS LINEAR | 1.0 | 0.1 | 100,000 | 11π/N | Linear-phase |
| WLS LISTEN | 1.0 | 0.05 | 10,000 | 16π/N | Minimum-phase |

### WLS LISTEN

Wider, more flexible transition band
Relax extreme stopband specifications，in exchange for shorter effective post-ringing
Output files use the WLSLISTEN identifier
Measured compared with standard WLS MIN：
- 99.9% impulse energy convergence time shortened by about 22%～29%
- 99.99% energy tail also significantly shortened

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

Kaiser output names use the form `song_FIRMIN_4x_176k4_24bit.wav`; minimum-phase
WLS output names use `song_WLSMIN_4x_176k4_24bit.wav`; linear-phase WLS output
names use `song_WLSLINEAR_4x_176k4_24bit.wav`.

## Build

```powershell
flutter pub get
flutter build windows --release
```

The release bundle is generated under
`build/windows/x64/runner/Release/` and includes `gac_audio_engine.dll`.


## HOW TO USE
download Release.zip file and run on windows
 - Release: First gen
 - Release_v2: Add Linear WLS filter, which will not perform minimum-phase real cepstrum conversion, although I personally prefer minimum-phase, because this sounds the most natural (it does not contain pre-echo, but there will be a slight loss of phase) but I still added the Linear-phase option

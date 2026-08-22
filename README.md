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

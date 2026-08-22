import '../audio/wav_metadata.dart';

enum FirDesign {
  kaiser(
    title: 'Kaiser MIN',
    subtitle: 'Balanced',
    description: 'Windowed-sinc · predictable peak rejection',
    fileTag: 'FIRMIN',
    phaseDescription: 'homomorphic minimum phase',
  ),
  weightedLeastSquares(
    title: 'WLS MIN',
    subtitle: 'Natural',
    description: 'Weighted least squares · low total imaging energy',
    fileTag: 'WLSMIN',
    phaseDescription: 'homomorphic minimum phase',
  ),
  weightedLeastSquaresLinear(
    title: 'WLS LINEAR',
    subtitle: 'Constant phase',
    description: 'Weighted least squares · symmetric linear phase',
    fileTag: 'WLSLINEAR',
    phaseDescription: 'direct symmetric linear phase',
  );

  const FirDesign({
    required this.title,
    required this.subtitle,
    required this.description,
    required this.fileTag,
    required this.phaseDescription,
  });

  final String title;
  final String subtitle;
  final String description;
  final String fileTag;
  final String phaseDescription;

  bool get isLinearPhase => this == FirDesign.weightedLeastSquaresLinear;
}

enum FirQuality {
  efficient(
    title: 'Efficient',
    subtitle: 'Fastest',
    taps44k: 1024,
    taps48k: 768,
    stopband: '≥ 115 dB',
  ),
  studio(
    title: 'Studio',
    subtitle: 'Recommended',
    taps44k: 2048,
    taps48k: 1536,
    stopband: '≥ 133 dB',
  ),
  mastering(
    title: 'Mastering',
    subtitle: '10K reference',
    taps44k: 10240,
    taps48k: 7680,
    stopband: '≥ 168 dB',
  );

  const FirQuality({
    required this.title,
    required this.subtitle,
    required this.taps44k,
    required this.taps48k,
    required this.stopband,
  });

  final String title;
  final String subtitle;
  final int taps44k;
  final int taps48k;
  final String stopband;

  int tapsFor(int sourceRate) => sourceRate == 44100 ? taps44k : taps48k;
}

enum OutputBitDepth {
  pcm16(16, '16 BIT'),
  pcm24(24, '24 BIT');

  const OutputBitDepth(this.bits, this.label);

  final int bits;
  final String label;
}

enum ConversionStatus { queued, converting, completed, failed, cancelled }

class ConversionJob {
  ConversionJob({required this.inputPath, required this.metadata});

  final String inputPath;
  final WavMetadata metadata;
  String? outputPath;
  String? error;
  double progress = 0;
  ConversionStatus status = ConversionStatus.queued;

  void requeue() {
    outputPath = null;
    error = null;
    progress = 0;
    status = ConversionStatus.queued;
  }
}

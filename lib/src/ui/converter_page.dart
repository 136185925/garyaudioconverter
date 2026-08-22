import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;

import '../audio/native_converter.dart';
import '../audio/wav_metadata.dart';
import '../models/conversion_job.dart';

const _cyan = Color(0xff15998a);
const _amber = Color(0xffef6a5b);
const _green = Color(0xff2eaa78);
const _background = Color(0xfff5f8f6);
const _surface = Color(0xffffffff);
const _muted = Color(0xff6d7f7b);
const _ink = Color(0xff203330);
const _border = Color(0xffdce7e3);

class ConverterPage extends StatefulWidget {
  const ConverterPage({super.key});

  @override
  State<ConverterPage> createState() => _ConverterPageState();
}

class _ConverterPageState extends State<ConverterPage> {
  static const _wavType = XTypeGroup(
    label: '16/24-bit WAV audio',
    extensions: <String>['wav'],
  );

  final List<ConversionJob> _jobs = [];
  FirDesign _design = FirDesign.kaiser;
  FirQuality _quality = FirQuality.studio;
  OutputBitDepth _outputBitDepth = OutputBitDepth.pcm16;
  double _headroomDb = -0.3;
  bool _noiseShaping = true;
  bool _tpdfDither = false;
  String? _outputFolder;
  ConversionJob? _activeJob;
  Timer? _progressTimer;
  bool _running = false;
  bool _cancelling = false;

  @override
  void dispose() {
    _progressTimer?.cancel();
    super.dispose();
  }

  Future<void> _addFiles() async {
    final files = await openFiles(
      acceptedTypeGroups: const <XTypeGroup>[_wavType],
      confirmButtonText: 'Add WAV files',
    );
    if (!mounted || files.isEmpty) return;

    final errors = <String>[];
    final added = <ConversionJob>[];
    for (final file in files) {
      if (_jobs.any(
        (job) => job.inputPath.toLowerCase() == file.path.toLowerCase(),
      )) {
        continue;
      }
      try {
        final metadata = await WavMetadata.read(file.path);
        added.add(ConversionJob(inputPath: file.path, metadata: metadata));
      } on WavMetadataException catch (error) {
        errors.add('${path.basename(file.path)} — ${error.message}');
      } on FileSystemException catch (error) {
        errors.add('${path.basename(file.path)} — ${error.message}');
      }
    }
    if (!mounted) return;
    setState(() => _jobs.addAll(added));
    if (errors.isNotEmpty) {
      _showMessage(errors.first, error: true);
    }
  }

  Future<void> _chooseOutputFolder() async {
    final folder = await getDirectoryPath(
      initialDirectory:
          _outputFolder ??
          (_jobs.isEmpty ? null : path.dirname(_jobs.first.inputPath)),
      confirmButtonText: 'Use this folder',
      canCreateDirectories: true,
    );
    if (!mounted || folder == null) return;
    setState(() => _outputFolder = folder);
  }

  void _showMessage(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: error ? const Color(0xffb9474f) : _ink,
        content: Text(message, style: const TextStyle(color: Colors.white)),
      ),
    );
  }

  String _outputPathFor(ConversionJob job) {
    final rate = job.metadata.sampleRate == 44100 ? '176k4' : '192k';
    final stem = path.basenameWithoutExtension(job.inputPath);
    final bits = _outputBitDepth.bits;
    final outputFolder = _outputFolder ?? path.dirname(job.inputPath);
    var candidate = path.join(
      outputFolder,
      '${stem}_${_design.fileTag}_4x_${rate}_${bits}bit.wav',
    );
    var copy = 2;
    while (File(candidate).existsSync()) {
      candidate = path.join(
        outputFolder,
        '${stem}_${_design.fileTag}_4x_${rate}_${bits}bit_$copy.wav',
      );
      copy++;
    }
    return candidate;
  }

  Future<void> _startConversion() async {
    if (_running) return;
    final queued = _jobs
        .where((job) => job.status == ConversionStatus.queued)
        .toList();
    if (queued.isEmpty) {
      _showMessage('Add at least one compatible WAV file first.', error: true);
      return;
    }
    setState(() {
      _running = true;
      _cancelling = false;
    });
    var completedNow = 0;
    for (final job in queued) {
      if (_cancelling) break;
      final outputPath = _outputPathFor(job);
      setState(() {
        _activeJob = job;
        job
          ..status = ConversionStatus.converting
          ..progress = 0
          ..error = null
          ..outputPath = outputPath;
      });
      _progressTimer?.cancel();
      _progressTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
        if (!mounted || _activeJob != job) return;
        try {
          setState(() => job.progress = NativeAudioConverter.progress);
        } on Object {
          // The worker reports the actual load error when the call completes.
        }
      });

      try {
        final result = await NativeAudioConverter.convert(
          inputPath: job.inputPath,
          outputPath: outputPath,
          design: _design,
          quality: _quality,
          headroomDb: _headroomDb,
          outputBitDepth: _outputBitDepth,
          noiseShaping: _noiseShaping,
          tpdfDither: _tpdfDither,
        );
        if (!mounted) return;
        setState(() {
          if (result.succeeded) {
            job
              ..status = ConversionStatus.completed
              ..progress = 1;
            completedNow++;
          } else if (result.cancelled) {
            job.status = ConversionStatus.cancelled;
          } else {
            job
              ..status = ConversionStatus.failed
              ..error = result.message;
          }
        });
      } on Object catch (error) {
        if (!mounted) return;
        setState(() {
          job
            ..status = ConversionStatus.failed
            ..error = error.toString();
        });
      } finally {
        _progressTimer?.cancel();
        _progressTimer = null;
      }
    }

    if (!mounted) return;
    setState(() {
      _activeJob = null;
      _running = false;
      _cancelling = false;
    });
    if (completedNow > 0) {
      _showMessage(
        '$completedNow file${completedNow == 1 ? '' : 's'} converted successfully.',
      );
    }
  }

  void _cancelConversion() {
    if (!_running || _cancelling) return;
    setState(() => _cancelling = true);
    try {
      NativeAudioConverter.cancel();
    } on Object {
      // The active conversion will still finish or report its own error.
    }
  }

  void _removeJob(ConversionJob job) {
    if (_activeJob == job) return;
    setState(() => _jobs.remove(job));
  }

  void _clearList() {
    if (_running) return;
    setState(_jobs.clear);
  }

  void _requeueFinished() {
    if (_running) return;
    setState(() {
      for (final job in _jobs) {
        if (job.status == ConversionStatus.completed) job.requeue();
      }
    });
  }

  void _useSourceFolders() {
    if (_running) return;
    setState(() => _outputFolder = null);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ColoredBox(
        color: _background,
        child: Row(
          children: <Widget>[
            const SizedBox(width: 238, child: _Sidebar()),
            Container(width: 1, color: _border),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(30, 26, 30, 28),
                child: Column(
                  children: <Widget>[
                    _Header(onAddFiles: _running ? null : _addFiles),
                    const SizedBox(height: 22),
                    Expanded(
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          if (constraints.maxWidth < 870) {
                            return SingleChildScrollView(
                              child: Column(
                                children: <Widget>[
                                  SizedBox(height: 430, child: _leftColumn()),
                                  const SizedBox(height: 16),
                                  _rightColumn(compact: true),
                                ],
                              ),
                            );
                          }
                          return Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              Expanded(child: _leftColumn()),
                              const SizedBox(width: 16),
                              SizedBox(width: 348, child: _rightColumn()),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _leftColumn() {
    return Column(
      children: <Widget>[
        Expanded(
          child: _QueueCard(
            jobs: _jobs,
            onAdd: _running ? null : _addFiles,
            onRemove: _removeJob,
            onClearList: _running ? null : _clearList,
            onClearFinished: _running ? null : _requeueFinished,
          ),
        ),
        const SizedBox(height: 14),
        _OutputFolderCard(
          folder: _outputFolder,
          enabled: !_running,
          onChoose: _chooseOutputFolder,
          onUseSource: _useSourceFolders,
        ),
      ],
    );
  }

  Widget _rightColumn({bool compact = false}) {
    final settings = _SettingsCard(
      design: _design,
      quality: _quality,
      outputBitDepth: _outputBitDepth,
      headroomDb: _headroomDb,
      noiseShaping: _noiseShaping,
      tpdfDither: _tpdfDither,
      enabled: !_running,
      onDesignChanged: (design) => setState(() => _design = design),
      onQualityChanged: (quality) => setState(() => _quality = quality),
      onOutputBitDepthChanged: (value) =>
          setState(() => _outputBitDepth = value),
      onHeadroomChanged: (value) => setState(() => _headroomDb = value),
      onNoiseShapingChanged: (value) => setState(() => _noiseShaping = value),
      onTpdfDitherChanged: (value) => setState(() => _tpdfDither = value),
    );
    final run = _RunCard(
      jobs: _jobs,
      running: _running,
      cancelling: _cancelling,
      activeJob: _activeJob,
      outputBitDepth: _outputBitDepth,
      onStart: _startConversion,
      onCancel: _cancelConversion,
    );
    if (compact) {
      return Column(
        children: <Widget>[settings, const SizedBox(height: 16), run],
      );
    }
    return Column(
      children: <Widget>[
        Expanded(child: SingleChildScrollView(child: settings)),
        const SizedBox(height: 16),
        SizedBox(height: 188, child: run),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.onAddFiles});

  final VoidCallback? onAddFiles;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 72,
      child: Stack(
        children: <Widget>[
          const Positioned(
            right: 170,
            top: 1,
            width: 250,
            height: 70,
            child: CustomPaint(painter: _SignalPainter()),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    Text(
                      'FIR MIN Audio Converter',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.displaySmall,
                    ),
                    const SizedBox(height: 5),
                    const Text(
                      'Causal minimum-phase resampling, engineered for transparent 4× WAV conversion.',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _muted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              const _Pill(icon: Icons.memory_rounded, label: 'NATIVE C++'),
              const SizedBox(width: 10),
              FilledButton.icon(
                onPressed: onAddFiles,
                icon: const Icon(Icons.add_rounded, size: 19),
                label: const Text('ADD WAV FILES'),
                style: FilledButton.styleFrom(
                  backgroundColor: _cyan,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 18,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  const _Sidebar();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xfffbfcfa),
      padding: const EdgeInsets.fromLTRB(22, 28, 22, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: Image.asset(
                  'assets/branding/app_icon.png',
                  width: 54,
                  height: 54,
                ),
              ),
              const SizedBox(width: 12),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'GARY',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.7,
                    ),
                  ),
                  Text(
                    'AUDIO LAB',
                    style: TextStyle(
                      color: _muted,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.4,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 46),
          const Text(
            'WORKSPACE',
            style: TextStyle(
              color: Color(0xff8a9995),
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xffe4f3ef),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: const Color(0xffc7e4dd)),
            ),
            child: const Row(
              children: <Widget>[
                SizedBox(width: 14),
                Icon(Icons.graphic_eq_rounded, color: _cyan, size: 21),
                SizedBox(width: 13),
                Text(
                  'Converter',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ],
            ),
          ),
          const Spacer(),
          const _AlgorithmNote(),
          const SizedBox(height: 18),
          const Row(
            children: <Widget>[
              Icon(Icons.circle, color: _green, size: 8),
              SizedBox(width: 8),
              Text(
                'ENGINE READY',
                style: TextStyle(
                  color: _muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          const Text(
            'FIR MIN Engine 1.0',
            style: TextStyle(color: Color(0xff8a9995), fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _AlgorithmNote extends StatelessWidget {
  const _AlgorithmNote();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: const Color(0xfffff4ea),
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: const Color(0xffffd9c8)),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.bolt_rounded, color: _amber, size: 20),
          SizedBox(height: 10),
          Text(
            'NO PRE-ECHO',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
            ),
          ),
          SizedBox(height: 5),
          Text(
            'Energy is moved toward the start of the causal impulse response.',
            style: TextStyle(color: _muted, fontSize: 11, height: 1.35),
          ),
        ],
      ),
    );
  }
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({
    required this.jobs,
    required this.onAdd,
    required this.onRemove,
    required this.onClearList,
    required this.onClearFinished,
  });

  final List<ConversionJob> jobs;
  final VoidCallback? onAdd;
  final ValueChanged<ConversionJob> onRemove;
  final VoidCallback? onClearList;
  final VoidCallback? onClearFinished;

  @override
  Widget build(BuildContext context) {
    final hasCompleted = jobs.any(
      (job) => job.status == ConversionStatus.completed,
    );
    return _SurfaceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 14, 14),
            child: Row(
              children: <Widget>[
                const _SectionIcon(icon: Icons.library_music_rounded),
                const SizedBox(width: 12),
                Text(
                  'Input queue',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(width: 9),
                _CountBadge(count: jobs.length),
                const Spacer(),
                if (hasCompleted)
                  TextButton(
                    onPressed: onClearFinished,
                    child: const Text('CLEAR FINISHED'),
                  ),
                if (jobs.isNotEmpty)
                  TextButton(
                    onPressed: onClearList,
                    child: const Text('CLEAR LIST'),
                  ),
              ],
            ),
          ),
          const Divider(height: 1, color: _border),
          Expanded(
            child: jobs.isEmpty
                ? _EmptyQueue(onAdd: onAdd)
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: jobs.length,
                    separatorBuilder: (context, index) => Divider(
                      height: 1,
                      indent: 76,
                      endIndent: 18,
                      color: _border,
                    ),
                    itemBuilder: (context, index) => _JobRow(
                      job: jobs[index],
                      onRemove: () => onRemove(jobs[index]),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue({required this.onAdd});

  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 430),
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 28),
          decoration: BoxDecoration(
            color: const Color(0xfff8fbf9),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xffcfe5df)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 54,
                height: 54,
                decoration: BoxDecoration(
                  color: _cyan.withValues(alpha: 0.09),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.audio_file_rounded, color: _cyan),
              ),
              const SizedBox(height: 14),
              const Text(
                'Add your source WAV files',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              const Text(
                '16/24-bit PCM · 44.1 or 48 kHz · up to 8 channels',
                textAlign: TextAlign.center,
                style: TextStyle(color: _muted, fontSize: 12),
              ),
              const SizedBox(height: 17),
              OutlinedButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('SELECT FILES'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: _cyan,
                  side: BorderSide(color: _cyan.withValues(alpha: 0.35)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JobRow extends StatelessWidget {
  const _JobRow({required this.job, required this.onRemove});

  final ConversionJob job;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final (color, icon, label) = switch (job.status) {
      ConversionStatus.queued => (_muted, Icons.schedule_rounded, 'QUEUED'),
      ConversionStatus.converting => (
        _cyan,
        Icons.graphic_eq_rounded,
        'CONVERTING',
      ),
      ConversionStatus.completed => (
        _green,
        Icons.check_circle_rounded,
        'COMPLETE',
      ),
      ConversionStatus.failed => (
        const Color(0xffd84f5c),
        Icons.error_rounded,
        'FAILED',
      ),
      ConversionStatus.cancelled => (_amber, Icons.cancel_rounded, 'CANCELLED'),
    };
    return Tooltip(
      message: job.error ?? job.outputPath ?? job.inputPath,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 11, 10, 11),
        child: Row(
          children: <Widget>[
            Container(
              width: 43,
              height: 43,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(11),
              ),
              child: Icon(
                Icons.multiline_chart_rounded,
                color: color,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    path.basename(job.inputPath),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_formatRate(job.metadata.sampleRate)}  →  '
                    '${_formatRate(job.metadata.outputSampleRate)}    ·    '
                    '${job.metadata.bitsPerSample} BIT    ·    '
                    '${job.metadata.channels == 1 ? 'MONO' : '${job.metadata.channels} CH'}    ·    '
                    '${_formatDuration(job.metadata.duration)}',
                    style: const TextStyle(color: _muted, fontSize: 11),
                  ),
                  if (job.status == ConversionStatus.converting) ...<Widget>[
                    const SizedBox(height: 7),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: job.progress,
                        minHeight: 3,
                        color: _cyan,
                        backgroundColor: const Color(0xffdce8e4),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(icon, color: color, size: 15),
            const SizedBox(width: 6),
            SizedBox(
              width: 74,
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ),
            IconButton(
              onPressed: job.status == ConversionStatus.converting
                  ? null
                  : onRemove,
              tooltip: 'Remove',
              icon: const Icon(Icons.close_rounded, size: 18),
              color: _muted,
            ),
          ],
        ),
      ),
    );
  }
}

class _OutputFolderCard extends StatelessWidget {
  const _OutputFolderCard({
    required this.folder,
    required this.enabled,
    required this.onChoose,
    required this.onUseSource,
  });

  final String? folder;
  final bool enabled;
  final VoidCallback onChoose;
  final VoidCallback onUseSource;

  @override
  Widget build(BuildContext context) {
    return _SurfaceCard(
      padding: const EdgeInsets.symmetric(horizontal: 19, vertical: 16),
      child: Row(
        children: <Widget>[
          const _SectionIcon(icon: Icons.drive_folder_upload_rounded),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                const Text(
                  'Output folder',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 5),
                Text(
                  folder ?? 'Same folder as each input WAV',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: folder == null ? _green : _ink,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (folder != null)
            TextButton(
              onPressed: enabled ? onUseSource : null,
              child: const Text('USE SOURCE'),
            ),
          OutlinedButton(
            onPressed: enabled ? onChoose : null,
            child: Text(folder == null ? 'CUSTOM' : 'CHANGE'),
          ),
        ],
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.design,
    required this.quality,
    required this.outputBitDepth,
    required this.headroomDb,
    required this.noiseShaping,
    required this.tpdfDither,
    required this.enabled,
    required this.onDesignChanged,
    required this.onQualityChanged,
    required this.onOutputBitDepthChanged,
    required this.onHeadroomChanged,
    required this.onNoiseShapingChanged,
    required this.onTpdfDitherChanged,
  });

  final FirDesign design;
  final FirQuality quality;
  final OutputBitDepth outputBitDepth;
  final double headroomDb;
  final bool noiseShaping;
  final bool tpdfDither;
  final bool enabled;
  final ValueChanged<FirDesign> onDesignChanged;
  final ValueChanged<FirQuality> onQualityChanged;
  final ValueChanged<OutputBitDepth> onOutputBitDepthChanged;
  final ValueChanged<double> onHeadroomChanged;
  final ValueChanged<bool> onNoiseShapingChanged;
  final ValueChanged<bool> onTpdfDitherChanged;

  @override
  Widget build(BuildContext context) {
    final quantizerLabel = noiseShaping
        ? (tpdfDither ? 'NS5 + TPDF' : 'NS5')
        : (tpdfDither ? 'TPDF' : 'ROUND');
    return _SurfaceCard(
      padding: const EdgeInsets.all(15),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const _SectionIcon(icon: Icons.tune_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'FIR MIN filter',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    Text(
                      '${design.title} · homomorphic minimum phase',
                      style: const TextStyle(color: _muted, fontSize: 10),
                    ),
                  ],
                ),
              ),
              const _Pill(label: '4×', compact: true),
            ],
          ),
          const SizedBox(height: 15),
          const Text(
            'FILTER DESIGN',
            style: TextStyle(
              color: _muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              for (final option in FirDesign.values) ...<Widget>[
                Expanded(
                  child: _FilterDesignOption(
                    value: option,
                    selected: design == option,
                    enabled: enabled,
                    onTap: () => onDesignChanged(option),
                  ),
                ),
                if (option != FirDesign.values.last) const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 17),
          for (final option in FirQuality.values) ...<Widget>[
            _QualityOption(
              quality: option,
              design: design,
              selected: quality == option,
              enabled: enabled,
              onTap: () => onQualityChanged(option),
            ),
            if (option != FirQuality.values.last) const SizedBox(height: 7),
          ],
          const SizedBox(height: 17),
          const Text(
            'OUTPUT BIT DEPTH',
            style: TextStyle(
              color: _muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              for (final option in OutputBitDepth.values) ...<Widget>[
                Expanded(
                  child: _BitDepthOption(
                    value: option,
                    selected: outputBitDepth == option,
                    enabled: enabled,
                    onTap: () => onOutputBitDepthChanged(option),
                  ),
                ),
                if (option != OutputBitDepth.values.last)
                  const SizedBox(width: 8),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: const Color(0xfff4f8f6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
            child: SwitchListTile(
              value: noiseShaping,
              onChanged: enabled ? onNoiseShapingChanged : null,
              dense: true,
              contentPadding: const EdgeInsets.fromLTRB(12, 2, 7, 2),
              activeThumbColor: _cyan,
              title: const Text(
                'NS5 NOISE SHAPING',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
              ),
              subtitle: const Text(
                'Independent fifth-order error-feedback shaping',
                style: TextStyle(color: _muted, fontSize: 9),
              ),
            ),
          ),
          const SizedBox(height: 10),
          AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            decoration: BoxDecoration(
              color: tpdfDither
                  ? const Color(0xfff4f8f6)
                  : const Color(0xfffff4ea),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: tpdfDither ? _border : const Color(0xffffcdb8),
              ),
            ),
            child: SwitchListTile(
              value: tpdfDither,
              onChanged: enabled ? onTpdfDitherChanged : null,
              dense: true,
              contentPadding: const EdgeInsets.fromLTRB(12, 2, 7, 2),
              activeThumbColor: _cyan,
              title: const Text(
                'TPDF DITHER',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800),
              ),
              subtitle: Text(
                tpdfDither
                    ? 'Independent triangular dither before quantization'
                    : 'Deterministic rounding · 24→16 may distort low levels',
                style: TextStyle(
                  color: tpdfDither ? _muted : _amber,
                  fontSize: 9,
                ),
              ),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              const Text(
                'HEADROOM',
                style: TextStyle(
                  color: _muted,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              Text(
                '${headroomDb.toStringAsFixed(1)} dB',
                style: const TextStyle(
                  color: _amber,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          Slider(
            value: headroomDb,
            min: -6,
            max: 3,
            divisions: 90,
            onChanged: enabled ? onHeadroomChanged : null,
          ),
          const Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: <Widget>[
              Text('-6 dB', style: TextStyle(color: _muted, fontSize: 9)),
              Text('+3 dB', style: TextStyle(color: _muted, fontSize: 9)),
            ],
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
            decoration: BoxDecoration(
              color: const Color(0xfff2f7f5),
              borderRadius: BorderRadius.circular(11),
              border: Border.all(color: _border),
            ),
            child: Row(
              children: <Widget>[
                _FlowChip(label: 'PCM ${outputBitDepth.bits}'),
                const Expanded(child: _FlowLine()),
                _FlowChip(label: design.title, accent: true),
                const Expanded(child: _FlowLine()),
                _FlowChip(label: quantizerLabel),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterDesignOption extends StatelessWidget {
  const _FilterDesignOption({
    required this.value,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final FirDesign value;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 57,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xffe8f5f2) : const Color(0xfff7faf8),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? const Color(0xff77c6b8) : _border,
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                value.title,
                style: TextStyle(
                  color: selected ? _cyan : _ink,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                value.subtitle,
                style: const TextStyle(color: _muted, fontSize: 9),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BitDepthOption extends StatelessWidget {
  const _BitDepthOption({
    required this.value,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final OutputBitDepth value;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(10),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 39,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? const Color(0xffffeee9) : const Color(0xfff7faf8),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? const Color(0xffffb8aa) : _border,
            ),
          ),
          child: Text(
            value.label,
            style: TextStyle(
              color: selected ? _amber : _muted,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ),
      ),
    );
  }
}

class _QualityOption extends StatelessWidget {
  const _QualityOption({
    required this.quality,
    required this.design,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final FirQuality quality;
  final FirDesign design;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
          decoration: BoxDecoration(
            color: selected ? const Color(0xffe8f5f2) : const Color(0xfff7faf8),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? const Color(0xff77c6b8) : _border,
            ),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? _cyan : const Color(0xff9badA8),
                    width: 1.5,
                  ),
                ),
                padding: const EdgeInsets.all(3),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: selected ? _cyan : Colors.transparent,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Text(
                          quality.title,
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (quality == FirQuality.studio) ...<Widget>[
                          const SizedBox(width: 7),
                          const Text(
                            'RECOMMENDED',
                            style: TextStyle(
                              color: _cyan,
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      '${quality.taps44k} / ${quality.taps48k} taps  ·  '
                      '${design == FirDesign.kaiser ? quality.stopband : 'weighted energy'}',
                      style: const TextStyle(color: _muted, fontSize: 10),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RunCard extends StatelessWidget {
  const _RunCard({
    required this.jobs,
    required this.running,
    required this.cancelling,
    required this.activeJob,
    required this.outputBitDepth,
    required this.onStart,
    required this.onCancel,
  });

  final List<ConversionJob> jobs;
  final bool running;
  final bool cancelling;
  final ConversionJob? activeJob;
  final OutputBitDepth outputBitDepth;
  final VoidCallback onStart;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final queued = jobs
        .where((job) => job.status == ConversionStatus.queued)
        .length;
    final estimatedBytes = jobs.fold<int>(
      0,
      (total, job) =>
          total +
          (job.metadata.fileBytes * 4 * outputBitDepth.bits) ~/
              job.metadata.bitsPerSample,
    );
    return _SurfaceCard(
      padding: const EdgeInsets.all(19),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(Icons.speed_rounded, color: _amber, size: 20),
              const SizedBox(width: 9),
              const Text(
                'Conversion run',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(
                '$queued READY',
                style: const TextStyle(
                  color: _muted,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: _RunMetric(label: 'FILES', value: '${jobs.length}'),
              ),
              Expanded(
                child: _RunMetric(
                  label: 'EST. OUTPUT',
                  value: _formatBytes(estimatedBytes),
                ),
              ),
            ],
          ),
          if (running) ...<Widget>[
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    activeJob == null
                        ? 'Preparing native engine…'
                        : path.basename(activeJob!.inputPath),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: _muted, fontSize: 10),
                  ),
                ),
                Text(
                  '${((activeJob?.progress ?? 0) * 100).round()}%',
                  style: const TextStyle(color: _cyan, fontSize: 10),
                ),
              ],
            ),
          ],
          const SizedBox(height: 14),
          SizedBox(
            height: 48,
            child: FilledButton.icon(
              onPressed: running ? onCancel : onStart,
              icon: Icon(
                running ? Icons.stop_rounded : Icons.play_arrow_rounded,
              ),
              label: Text(
                running
                    ? (cancelling ? 'CANCELLING…' : 'CANCEL')
                    : 'START 4× CONVERSION',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: running ? const Color(0xffd95862) : _cyan,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RunMetric extends StatelessWidget {
  const _RunMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: const TextStyle(
            color: _muted,
            fontSize: 8,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          value,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ],
    );
  }
}

class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({required this.child, required this.padding});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _border),
      ),
      child: child,
    );
  }
}

class _SectionIcon extends StatelessWidget {
  const _SectionIcon({required this.icon});

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        color: const Color(0xffe5f3f0),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Icon(icon, color: _cyan, size: 18),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({this.icon, required this.label, this.compact = false});

  final IconData? icon;
  final String label;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 9 : 12,
        vertical: compact ? 6 : 9,
      ),
      decoration: BoxDecoration(
        color: const Color(0xffedf6f3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xffcfe4de)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 13, color: _cyan),
            const SizedBox(width: 6),
          ],
          Text(
            label,
            style: const TextStyle(
              color: _cyan,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: const Color(0xffe9efec),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count',
        style: const TextStyle(color: _muted, fontSize: 10),
      ),
    );
  }
}

class _FlowChip extends StatelessWidget {
  const _FlowChip({required this.label, this.accent = false});

  final String label;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        color: accent ? _cyan : const Color(0xff5f716d),
        fontSize: 8,
        fontWeight: FontWeight.w800,
        letterSpacing: 0.5,
      ),
    );
  }
}

class _FlowLine extends StatelessWidget {
  const _FlowLine();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: const Color(0xffa9d6cd),
    );
  }
}

class _SignalPainter extends CustomPainter {
  const _SignalPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()..moveTo(0, size.height * 0.58);
    for (var i = 0; i < 4; i++) {
      final start = i * size.width / 4;
      final end = (i + 1) * size.width / 4;
      path.cubicTo(
        start + size.width / 16,
        i.isEven ? size.height * 0.12 : size.height * 0.92,
        end - size.width / 16,
        i.isEven ? size.height * 0.92 : size.height * 0.12,
        end,
        size.height * 0.58,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0x3315998a)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

String _formatRate(int rate) {
  if (rate == 44100) return '44.1 kHz';
  if (rate == 176400) return '176.4 kHz';
  return '${rate ~/ 1000} kHz';
}

String _formatDuration(Duration duration) {
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  if (duration.inHours > 0) return '${duration.inHours}:$minutes:$seconds';
  return '$minutes:$seconds';
}

String _formatBytes(int bytes) {
  if (bytes <= 0) return '0 MB';
  final megabytes = bytes / (1024 * 1024);
  if (megabytes < 1024) return '${megabytes.toStringAsFixed(1)} MB';
  return '${(megabytes / 1024).toStringAsFixed(2)} GB';
}

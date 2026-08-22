import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:garyaudioconverter/src/audio/wav_metadata.dart';
import 'package:garyaudioconverter/src/app.dart';
import 'package:garyaudioconverter/src/models/conversion_job.dart';

void main() {
  testWidgets('converter workspace exposes the complete idle workflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1320, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const GaryAudioConverterApp());
    await tester.pumpAndSettle();

    final scaffold = tester.element(find.byType(Scaffold));
    expect(Theme.of(scaffold).brightness, Brightness.light);
    expect(find.text('FIR MIN Audio Converter'), findsOneWidget);
    expect(find.text('Input queue'), findsOneWidget);
    expect(find.text('Studio'), findsOneWidget);
    expect(find.text('Kaiser MIN'), findsWidgets);
    expect(find.text('WLS MIN'), findsOneWidget);
    expect(find.text('Natural'), findsOneWidget);
    expect(find.text('16 BIT'), findsOneWidget);
    expect(find.text('24 BIT'), findsOneWidget);
    expect(find.text('NS5 NOISE SHAPING'), findsOneWidget);
    expect(find.text('TPDF DITHER'), findsOneWidget);
    final quantizerSwitches = tester
        .widgetList<SwitchListTile>(find.byType(SwitchListTile))
        .toList();
    expect(quantizerSwitches, hasLength(2));
    expect(quantizerSwitches[0].value, isTrue);
    expect(quantizerSwitches[1].value, isFalse);
    final headroomSlider = tester.widget<Slider>(find.byType(Slider));
    expect(headroomSlider.min, -6);
    expect(headroomSlider.max, 3);
    expect(headroomSlider.value, -0.3);
    expect(headroomSlider.divisions, 90);
    expect(find.text('+3 dB'), findsOneWidget);
    expect(find.text('START 4× CONVERSION'), findsOneWidget);
    expect(find.text('Same folder as each input WAV'), findsOneWidget);
    expect(find.text('CUSTOM'), findsOneWidget);

    await tester.tap(find.text('WLS MIN'));
    await tester.pumpAndSettle();
    expect(find.text('WLS MIN · homomorphic minimum phase'), findsOneWidget);
    expect(find.textContaining('weighted energy'), findsNWidgets(3));
  });

  test('completed jobs can be reset to the conversion queue', () {
    final job =
        ConversionJob(
            inputPath: r'C:\Music\source.wav',
            metadata: const WavMetadata(
              channels: 2,
              sampleRate: 48000,
              bitsPerSample: 24,
              frames: 48000,
              fileBytes: 288000,
            ),
          )
          ..status = ConversionStatus.completed
          ..progress = 1
          ..outputPath = r'C:\Music\source_FIRMIN.wav'
          ..error = 'old status';

    job.requeue();

    expect(job.status, ConversionStatus.queued);
    expect(job.progress, 0);
    expect(job.outputPath, isNull);
    expect(job.error, isNull);
  });
}

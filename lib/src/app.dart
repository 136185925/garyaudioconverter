import 'package:flutter/material.dart';

import 'ui/converter_page.dart';

class GaryAudioConverterApp extends StatelessWidget {
  const GaryAudioConverterApp({super.key});

  @override
  Widget build(BuildContext context) {
    const background = Color(0xfff5f8f6);
    const surface = Color(0xffffffff);
    const teal = Color(0xff15998a);
    final scheme =
        ColorScheme.fromSeed(
          seedColor: teal,
          brightness: Brightness.light,
          surface: surface,
        ).copyWith(
          primary: teal,
          secondary: const Color(0xff348fe2),
          outline: const Color(0xffd7e3df),
          surfaceContainerHighest: const Color(0xffedf3f0),
        );

    return MaterialApp(
      title: 'FIR MIN Audio Converter',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: scheme,
        scaffoldBackgroundColor: background,
        fontFamily: 'Segoe UI',
        dividerColor: const Color(0xffe1e9e6),
        textTheme: const TextTheme(
          displaySmall: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.9,
          ),
          titleLarge: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.2,
          ),
          titleMedium: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          bodyMedium: TextStyle(fontSize: 13, height: 1.35),
          labelLarge: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: teal,
          inactiveTrackColor: Color(0xffdce8e4),
          thumbColor: teal,
          overlayColor: Color(0x2215998a),
          trackHeight: 4,
        ),
        tooltipTheme: const TooltipThemeData(
          decoration: BoxDecoration(
            color: Color(0xff24423e),
            borderRadius: BorderRadius.all(Radius.circular(8)),
          ),
          textStyle: TextStyle(color: Colors.white, fontSize: 12),
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: teal,
            foregroundColor: Colors.white,
            elevation: 0,
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xff147f73),
            side: const BorderSide(color: Color(0xffb9d8d1)),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(foregroundColor: teal),
        ),
      ),
      home: const ConverterPage(),
    );
  }
}

import 'package:flutter/material.dart';

class C {
  static const bg = Color(0xFF070B14);
  static const bg2 = Color(0xFF0B1222);
  static const surface = Color(0xFF0F172A);
  static const surface2 = Color(0xFF141F38);
  static const border = Color(0xFF1F2B4A);
  static const cyan = Color(0xFF38D7FF);
  static const blue = Color(0xFF3B82F6);
  static const violet = Color(0xFF8B5CF6);
  static const text = Color(0xFFE6EDF7);
  static const muted = Color(0xFF8A97B2);
  static const ok = Color(0xFF22C55E);
  static const warn = Color(0xFFF59E0B);
  static const bad = Color(0xFFEF4444);

  static const accent = LinearGradient(
    colors: [cyan, blue, violet],
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
  );
}

ThemeData buildTheme() {
  final scheme = ColorScheme.fromSeed(
    seedColor: C.cyan,
    brightness: Brightness.dark,
  ).copyWith(
    primary: C.cyan,
    secondary: C.blue,
    tertiary: C.violet,
    surface: C.surface,
    error: C.bad,
    onSurface: C.text,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: C.bg,
    canvasColor: C.surface,
    dividerColor: C.border,
    appBarTheme: const AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: C.text,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: C.bg2,
      hintStyle: const TextStyle(color: C.muted),
      labelStyle: const TextStyle(color: C.muted),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: C.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: C.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: C.cyan, width: 1.4),
      ),
    ),
    snackBarTheme: const SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: C.surface2,
      contentTextStyle: TextStyle(color: C.text),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: C.bg2,
      indicatorColor: C.cyan.withAlpha(40),
      height: 66,
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: C.cyan, linearTrackColor: C.border),
    bottomSheetTheme: const BottomSheetThemeData(backgroundColor: C.surface),
  );
}

import 'package:flutter/material.dart';

/// Adaptive color set — use UdTheme.of(context) to get the right variant.
class UdColors {
  final Color bg, surface, surfaceHigh, surfaceBorder;
  final Color textPrimary, textSecondary, textMuted;
  const UdColors({
    required this.bg,
    required this.surface,
    required this.surfaceHigh,
    required this.surfaceBorder,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
  });
}

class UdTheme {
  // ── Brand (same in both themes) ────────────────────────────────────────────
  static const Color navy      = Color(0xFF1C3D6B);
  static const Color green     = Color(0xFF3CC870);
  static const Color greenDark = Color(0xFF28A058);

  // ── Dark palette (kept as static consts for non-context code) ─────────────
  static const Color bg            = Color(0xFF0D1117);
  static const Color surface       = Color(0xFF161B25);
  static const Color surfaceHigh   = Color(0xFF1E2535);
  static const Color surfaceBorder = Color(0xFF252D40);
  static const Color textPrimary   = Color(0xFFF0F4FF);
  static const Color textSecondary = Color(0xFF8892A4);
  static const Color textMuted     = Color(0xFF4A5568);

  // ── Light palette ──────────────────────────────────────────────────────────
  static const Color lightBg            = Color(0xFFFFFFFF);
  static const Color lightSurface       = Color(0xFFF3F6FA);
  static const Color lightSurfaceHigh   = Color(0xFFE8EEF5);
  static const Color lightSurfaceBorder = Color(0xFFD0D9E8);
  static const Color lightTextPrimary   = Color(0xFF1A202C);
  static const Color lightTextSecondary = Color(0xFF5A6478);
  static const Color lightTextMuted     = Color(0xFFADB8C9);

  // ── Status ─────────────────────────────────────────────────────────────────
  static const Color online     = Color(0xFF3CC870);
  static const Color connecting = Color(0xFFFFB020);
  static const Color offline    = Color(0xFF556070);
  static const Color errorColor = Color(0xFFFF4D6A);

  // ── Geometry ───────────────────────────────────────────────────────────────
  static const double radSm = 8.0;
  static const double radMd = 12.0;
  static const double radLg = 16.0;
  static const double radXl = 24.0;

  // ── Shadows ────────────────────────────────────────────────────────────────
  static List<BoxShadow> get cardShadow => [
    BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 24, offset: const Offset(0, 8)),
  ];
  static List<BoxShadow> get glowGreen => [
    BoxShadow(color: green.withOpacity(0.25), blurRadius: 20, spreadRadius: 2),
  ];

  // ── Adaptive color lookup ──────────────────────────────────────────────────
  static const UdColors _dark = UdColors(
    bg: bg, surface: surface, surfaceHigh: surfaceHigh, surfaceBorder: surfaceBorder,
    textPrimary: textPrimary, textSecondary: textSecondary, textMuted: textMuted,
  );
  static const UdColors _light = UdColors(
    bg: lightBg, surface: lightSurface, surfaceHigh: lightSurfaceHigh,
    surfaceBorder: lightSurfaceBorder,
    textPrimary: lightTextPrimary, textSecondary: lightTextSecondary, textMuted: lightTextMuted,
  );

  static UdColors of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;

  // ── Dark ThemeData ─────────────────────────────────────────────────────────
  static ThemeData get dark => ThemeData(
    useMaterial3: false,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: bg,
    fontFamily: 'Roboto',
    colorScheme: const ColorScheme.dark(
      primary: navy,
      secondary: green,
      background: bg,
      surface: surface,
    ),
    cardColor: surface,
    dividerColor: surfaceBorder,
    hintColor: textMuted,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: green,
      selectionColor: green.withOpacity(0.25),
      selectionHandleColor: green,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceHigh,
      hintStyle: const TextStyle(color: textMuted, fontSize: 15),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radMd),
        borderSide: const BorderSide(color: surfaceBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radMd),
        borderSide: const BorderSide(color: surfaceBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radMd),
        borderSide: const BorderSide(color: green, width: 1.5),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: green,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radMd)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.3),
      ),
    ),
  );

  // ── Light ThemeData ────────────────────────────────────────────────────────
  static ThemeData get light => ThemeData(
    useMaterial3: false,
    brightness: Brightness.light,
    scaffoldBackgroundColor: lightBg,
    fontFamily: 'Roboto',
    colorScheme: const ColorScheme.light(
      primary: navy,
      secondary: green,
      background: lightBg,
      surface: lightSurface,
    ),
    cardColor: lightSurface,
    dividerColor: lightSurfaceBorder,
    hintColor: lightTextMuted,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: green,
      selectionColor: green.withOpacity(0.20),
      selectionHandleColor: green,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: lightSurfaceHigh,
      hintStyle: const TextStyle(color: lightTextMuted, fontSize: 15),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radMd),
        borderSide: const BorderSide(color: lightSurfaceBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radMd),
        borderSide: const BorderSide(color: lightSurfaceBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(radMd),
        borderSide: const BorderSide(color: green, width: 1.5),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: green,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radMd)),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600, letterSpacing: 0.3),
      ),
    ),
  );
}

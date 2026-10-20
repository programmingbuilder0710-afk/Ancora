import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

ThemeData doerTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF1F6F5C),
    brightness: brightness,
    primary: brightness == Brightness.light
        ? const Color(0xFF1F6F5C)
        : const Color(0xFF7FD1B5),
    surface: brightness == Brightness.light
        ? const Color(0xFFF7F5F0)
        : const Color(0xFF101513),
    onSurface: brightness == Brightness.light
        ? const Color(0xFF15201C)
        : const Color(0xFFE8ECE9),
    onSurfaceVariant: brightness == Brightness.light
        ? const Color(0xFF5B6661)
        : const Color(0xFFACB8B1),
    outlineVariant: brightness == Brightness.light
        ? const Color(0xFFE3DFD6)
        : const Color(0xFF34423B),
    surfaceContainerLow: brightness == Brightness.light
        ? const Color(0xFFFFFDFA)
        : const Color(0xFF18201C),
    tertiaryContainer: brightness == Brightness.light
        ? const Color(0xFFFFE4AE)
        : const Color(0xFF5B4000),
    onTertiaryContainer: brightness == Brightness.light
        ? const Color(0xFF281900)
        : const Color(0xFFFFE4AE),
    tertiary: brightness == Brightness.light
        ? const Color(0xFF805600)
        : const Color(0xFFF0C16D),
  );
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  TextStyle? title(TextStyle? style, [double spacing = -0.2]) =>
      style?.copyWith(fontWeight: FontWeight.w600, letterSpacing: spacing);
  final text = base.textTheme.copyWith(
    displayLarge: title(base.textTheme.displayLarge, -0.4),
    displayMedium: title(base.textTheme.displayMedium, -0.4),
    displaySmall: title(base.textTheme.displaySmall, -0.4),
    headlineLarge: title(base.textTheme.headlineLarge, -0.4),
    headlineMedium: title(base.textTheme.headlineMedium, -0.4),
    headlineSmall: title(base.textTheme.headlineSmall),
    titleLarge: title(base.textTheme.titleLarge),
    titleMedium: title(base.textTheme.titleMedium),
    titleSmall: title(base.textTheme.titleSmall),
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
  final border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: scheme.outlineVariant),
  );
  return base.copyWith(
    textTheme: GoogleFonts.interTextTheme(text),
    visualDensity: VisualDensity.standard,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerLow,
      border: border,
      enabledBorder: border,
      focusedBorder: border.copyWith(
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      contentPadding: const EdgeInsets.all(16),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: shape,
      ),
    ),
    chipTheme: base.chipTheme.copyWith(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: shape,
    ),
    listTileTheme: const ListTileThemeData(
      contentPadding: EdgeInsets.symmetric(horizontal: 16),
    ),
    dialogTheme: DialogThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: scheme.surfaceContainerLow,
      indicatorColor: scheme.secondaryContainer,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      linearTrackColor: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(8),
      linearMinHeight: 4,
    ),
  );
}

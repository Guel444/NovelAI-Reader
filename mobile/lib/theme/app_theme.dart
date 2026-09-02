import 'package:flutter/material.dart';

/// Paleta padrão do app (fundo escuro, accent roxo/azul). Cada livro
/// pode gerar sua própria variante tingida a partir da cor dominante
/// da capa (ver cover_theme.dart).
class AppPalette {
  static const accent = Color(0xFF7C8CFF);
  static const accentDark = Color(0xFF4A55B3);
  static const bg = Color(0xFF0D0F14);
  static const surface = Color(0xFF171922);
  static const text = Color(0xFFE8E8EA);
}

ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppPalette.bg,
    colorScheme: const ColorScheme.dark(
      primary: AppPalette.accent,
      secondary: AppPalette.accentDark,
      surface: AppPalette.surface,
      onSurface: AppPalette.text,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppPalette.surface,
      foregroundColor: AppPalette.text,
      elevation: 0,
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(color: AppPalette.text, fontSize: 16, height: 1.4),
      bodyMedium: TextStyle(color: AppPalette.text, fontSize: 15, height: 1.4),
      titleLarge: TextStyle(color: AppPalette.text, fontWeight: FontWeight.bold),
    ),
    floatingActionButtonTheme: const FloatingActionButtonThemeData(
      backgroundColor: AppPalette.accent,
      foregroundColor: Colors.white,
    ),
  );
}

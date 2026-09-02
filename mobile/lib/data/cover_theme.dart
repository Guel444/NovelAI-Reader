import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Calcula a cor média da capa do livro e mistura sutilmente com o
/// fundo escuro padrão. Nunca usa a cor da capa como cor de texto —
/// só tingimento sutil de fundo.
Future<Color> computeCoverTint(Uint8List coverBytes) async {
  try {
    final codec = await ui.instantiateImageCodec(coverBytes, targetWidth: 24, targetHeight: 24);
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final byteData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    if (byteData == null) return AppPalette.bg;

    final bytes = byteData.buffer.asUint8List();
    int rSum = 0, gSum = 0, bSum = 0, count = 0;
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      rSum += bytes[i];
      gSum += bytes[i + 1];
      bSum += bytes[i + 2];
      count++;
    }
    if (count == 0) return AppPalette.bg;

    final coverColor = Color.fromARGB(
      255,
      (rSum / count).round(),
      (gSum / count).round(),
      (bSum / count).round(),
    );

    // mistura só 22% da cor da capa no fundo escuro padrão — tingimento
    // sutil, nunca a ponto de comprometer o contraste do texto
    return Color.lerp(AppPalette.bg, coverColor, 0.22) ?? AppPalette.bg;
  } catch (_) {
    return AppPalette.bg;
  }
}

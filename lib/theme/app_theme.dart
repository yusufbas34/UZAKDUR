import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

class AppColors {
  static const bg = Color(0xFF0D0D0F);
  static const surface = Color(0xFF16161A);
  static const surfaceHigh = Color(0xFF1E1E24);
  static const border = Color(0xFF2A2A32);
  static const safe = Color(0xFF00C896);
  static const warning = Color(0xFFFFB020);
  static const danger = Color(0xFFFF3B30);
  static const dangerGlow = Color(0x30FF3B30);
  static const dangerDeep = Color(0xFF2D0A0A);
  static const roleA = Color(0xFFFF5F57);
  static const roleAGlow = Color(0x25FF5F57);
  static const roleB = Color(0xFF4FACFE);
  static const roleBGlow = Color(0x254FACFE);
  static const textPrimary = Color(0xFFF0F0F5);
  static const textSecondary = Color(0xFF9090A0);
  static const textMuted = Color(0xFF55555F);
  static const textDisabled = Color(0xFF3A3A44);
}

ThemeData buildAppTheme() => ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.bg,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.roleA,
        secondary: AppColors.safe,
        surface: AppColors.surface,
      ),
      splashFactory: NoSplash.splashFactory,
      highlightColor: Colors.transparent,
    );

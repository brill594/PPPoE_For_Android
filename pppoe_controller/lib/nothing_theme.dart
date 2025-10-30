// lib/nothing_theme.dart
import 'package:flutter/material.dart';

// 1. (可选) 定义你的字体名称 (与 pubspec.yaml 一致)
const String? kNothingFontFamily = 'VT323'; // 假设您已添加 'VT323'

// --- MODIFIED: 定义全局圆角 ---
// 2. 定义全局圆角
const double kNothingBorderRadius = 24.0; // 从 12.0 增大到 24.0

// 3. 定义 Nothing 风格的核心颜色
class NothingColors {
  static const Color black = Color(0xFF000000);
  static const Color white = Color(0xFFFFFFFF);
  static const Color grey = Color(0xFF8A8A8A); // 辅助灰, 用于 hint 和 disable
  static const Color redAccent = Color(0xFFFF0000); // 唯一的点缀色
}

// 4. 创建 Nothing 风格的主题
ThemeData getNothingTheme() {
  return ThemeData(
    // 基础设置
      brightness: Brightness.dark,
      fontFamily: kNothingFontFamily,

      // 全局背景色
      scaffoldBackgroundColor: NothingColors.black,

      // 核心配色方案
      colorScheme: ColorScheme(
        brightness: Brightness.dark,
        primary: NothingColors.white,
        onPrimary: NothingColors.black,
        secondary: NothingColors.grey,
        onSecondary: NothingColors.white,
        surface: NothingColors.black,
        onSurface: NothingColors.white,
        error: NothingColors.redAccent,
        onError: NothingColors.white,
      ),

      // 组件特定主题
      // ... (AppBar, Icon, Text, InputDecoration... 等保持不变) ...

      appBarTheme: AppBarTheme(
        backgroundColor: NothingColors.black,
        foregroundColor: NothingColors.white,
        elevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: kNothingFontFamily,
          fontSize: 22,
          fontWeight: FontWeight.bold,
          color: NothingColors.white,
        ),
      ),

      iconTheme: IconThemeData(
        color: NothingColors.white,
      ),

      textTheme: TextTheme(
        bodyLarge: TextStyle(color: NothingColors.white, fontFamily: kNothingFontFamily),
        bodyMedium: TextStyle(color: NothingColors.white, fontFamily: kNothingFontFamily),
        labelLarge: TextStyle(color: NothingColors.white, fontFamily: kNothingFontFamily),
        titleMedium: TextStyle(color: NothingColors.white),
        labelMedium: TextStyle(color: NothingColors.grey),
      ),

      textSelectionTheme: TextSelectionThemeData(
        cursorColor: NothingColors.redAccent,
        selectionColor: const Color(0x4DFFFFFF),
        selectionHandleColor: NothingColors.white,
      ),

      inputDecorationTheme: InputDecorationTheme(
        labelStyle: TextStyle(color: NothingColors.grey),
        floatingLabelStyle: TextStyle(color: NothingColors.white),
        hintStyle: TextStyle(color: NothingColors.grey),
        enabledBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: NothingColors.grey),
        ),
        focusedBorder: UnderlineInputBorder(
          borderSide: BorderSide(color: NothingColors.white, width: 2),
        ),
        border: UnderlineInputBorder(
          borderSide: BorderSide(color: NothingColors.grey),
        ),
      ),

      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(NothingColors.white),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const Color(0x80FFFFFF);
          }
          return const Color(0x808A8A8A);
        }),
      ),

      // --- 按钮 ---
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: NothingColors.white,
          foregroundColor: NothingColors.black,
          // --- MODIFIED: 使用更大的全局圆角 ---
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kNothingBorderRadius)),
          textStyle: TextStyle(fontFamily: kNothingFontFamily, fontWeight: FontWeight.bold),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: NothingColors.white,
          side: BorderSide(color: NothingColors.white),
          // --- MODIFIED: 使用更大的全局圆角 ---
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kNothingBorderRadius)),
          textStyle: TextStyle(fontFamily: kNothingFontFamily, fontWeight: FontWeight.bold),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: NothingColors.white,
          // --- MODIFIED: 使用更大的全局圆角 ---
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kNothingBorderRadius)),
          textStyle: TextStyle(fontFamily: kNothingFontFamily, fontWeight: FontWeight.bold),
        ),
      ),

      // --- SnackBar ---
      snackBarTheme: SnackBarThemeData(
        backgroundColor: const Color(0xE6424242),
        contentTextStyle: TextStyle(color: NothingColors.white, fontFamily: kNothingFontFamily),
        actionTextColor: NothingColors.white,
      )
  );
}
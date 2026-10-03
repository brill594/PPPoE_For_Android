import 'package:flutter/material.dart';
import 'motion.dart';

const String kNothingFontFamily = 'VT323';

const double kNothingBorderRadius = 24.0;

class NothingColors {
  static const Color black = Color(0xFF000000);
  static const Color white = Color(0xFFFFFFFF);
  static const Color grey = Color(0xFF8A8A8A); // 辅助灰, 用于 hint 和 disable
  static const Color redAccent = Color(0xFFFF0000); // 唯一的点缀色
}

ThemeData getNothingTheme() {
  return ThemeData(
    // 基础设置
      brightness: Brightness.dark,
      fontFamily: kNothingFontFamily,

      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: NothingPageTransitionsBuilder(),
        },
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(foregroundBuilder: buttonPressFeedback),
      ),

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
      appBarTheme: AppBarTheme(
        backgroundColor: NothingColors.black,
        foregroundColor: NothingColors.white,
        elevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: kNothingFontFamily,
          fontSize: 28,
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
          foregroundBuilder: buttonPressFeedback,
          backgroundColor: NothingColors.white,
          foregroundColor: NothingColors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kNothingBorderRadius)),
          textStyle: TextStyle(fontFamily: kNothingFontFamily, fontWeight: FontWeight.bold),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundBuilder: buttonPressFeedback,
          foregroundColor: NothingColors.white,
          side: BorderSide(color: NothingColors.white),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(kNothingBorderRadius)),
          textStyle: TextStyle(fontFamily: kNothingFontFamily, fontWeight: FontWeight.bold),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundBuilder: buttonPressFeedback,
          foregroundColor: NothingColors.white,
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
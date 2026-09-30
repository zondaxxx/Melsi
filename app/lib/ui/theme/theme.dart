import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'tokens.dart';

export 'motion.dart';
export 'tokens.dart';

ThemeData buildTheme(Brightness brightness) {
  final c = brightness == Brightness.dark ? MelsiColors.dark : MelsiColors.light;
  final t = MelsiType.of(c);
  final scheme = ColorScheme.fromSeed(
    seedColor: c.accent,
    brightness: brightness,
  ).copyWith(
    primary: c.accent,
    onPrimary: c.onAccent,
    secondary: c.accent,
    surface: c.surface,
    onSurface: c.label,
    error: c.danger,
    outline: c.separator,
    outlineVariant: c.separator,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.background,
    canvasColor: c.background,
    extensions: [c, t],
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: c.fill,
    dividerColor: c.separator,
    dividerTheme: DividerThemeData(color: c.separator, thickness: kHairline, space: kHairline),
    iconTheme: IconThemeData(color: c.label, size: 20),
    textTheme: TextTheme(
      displayLarge: t.monoDisplay,
      headlineLarge: t.title1,
      headlineMedium: t.title1,
      headlineSmall: t.title2,
      titleLarge: t.title3,
      titleMedium: t.headline,
      titleSmall: t.subhead.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: t.body,
      bodyMedium: t.callout,
      bodySmall: t.footnote,
      labelLarge: t.callout.copyWith(fontWeight: FontWeight.w600),
      labelMedium: t.caption,
      labelSmall: t.overline,
    ),
    cupertinoOverrideTheme: CupertinoThemeData(
      brightness: brightness,
      primaryColor: c.accent,
    ),
    // The knob is white in both themes; "on" is the accent.
    switchTheme: SwitchThemeData(
      thumbColor: const WidgetStatePropertyAll(Colors.white),
      trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.accent : c.offTrack),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: c.accent,
      selectionColor: c.accent.withValues(alpha: 0.25),
      selectionHandleColor: c.accent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.isDark ? c.surface : c.surface,
      isDense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.m - 1),
      hintStyle: t.body.copyWith(color: c.tertiaryLabel),
      labelStyle: t.callout.copyWith(color: c.secondaryLabel),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.m - 2),
        borderSide: BorderSide(color: c.separator, width: kHairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.m - 2),
        borderSide: BorderSide(color: c.separator, width: kHairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.m - 2),
        borderSide: BorderSide(color: c.accent, width: 1.5),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.isDark ? c.surfaceRaised : c.label,
      contentTextStyle: t.callout.copyWith(color: c.isDark ? c.label : c.background),
      shape: Radii.shape(Radii.m,
          side: BorderSide(color: c.isDark ? c.separator : Colors.transparent, width: kHairline)),
      elevation: 0,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surfaceRaised,
      modalBackgroundColor: c.surfaceRaised,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.l))),
      showDragHandle: false,
      elevation: 0,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surfaceRaised,
      shape: Radii.shape(Radii.l, side: BorderSide(color: c.separator, width: kHairline)),
      titleTextStyle: t.headline,
      contentTextStyle: t.callout,
      elevation: 0,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surfaceRaised,
      shape: Radii.shape(Radii.m, side: BorderSide(color: c.separator, width: kHairline)),
      textStyle: t.callout,
      elevation: c.isDark ? 0 : 6,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      surfaceTintColor: Colors.transparent,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: c.accent,
      linearTrackColor: c.fill,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: ShapeDecoration(
          color: c.isDark ? c.surfaceRaised : c.label,
          shape: Radii.shape(Radii.s,
              side: BorderSide(color: c.isDark ? c.separator : Colors.transparent, width: kHairline))),
      textStyle: t.caption.copyWith(color: c.isDark ? c.label : c.background),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.accent,
        shape: Radii.shape(Radii.s),
      ),
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {
      TargetPlatform.android: CupertinoPageTransitionsBuilder(),
      TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
      TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
    }),
  );
}

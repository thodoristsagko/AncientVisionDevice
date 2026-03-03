import 'package:flutter/material.dart';

/// AncientVision App Styles
/// Unified styling for consistent UI across all screens

class AppColors {
  // Primary colors
  static const Color primary = Color(0xFF0D3A39);      // Dark teal
  static const Color primaryDark = Color(0xFF1C2523); // Darker teal
  static const Color accent = Color(0xFFFFC107);      // Gold/Amber

  // Text colors
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0x8AFFFFFF); // white54
  static const Color textHint = Color(0x61FFFFFF);     // white38

  // Status colors
  static const Color success = Color(0xFF4CAF50);
  static const Color error = Color(0xFFE53935);
  static const Color warning = Color(0xFFFF9800);
  static const Color info = Color(0xFF2196F3);

  // Card/Surface colors
  static const Color cardBackground = Color(0x1AFFFFFF); // white10
  static const Color cardBorder = Color(0x1FFFFFFF);     // white12
  static const Color overlay = Color(0x0DFFFFFF);        // white5
}

class AppGradients {
  static const LinearGradient background = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [AppColors.primary, AppColors.primaryDark],
  );

  static LinearGradient accentFade = LinearGradient(
    colors: [
      AppColors.accent.withAlpha(40),
      AppColors.accent.withAlpha(20),
    ],
  );
}

class AppTextStyles {
  // Headers - larger sizes for better readability
  static const TextStyle h1 = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 28,
    fontWeight: FontWeight.bold,
    letterSpacing: -0.5,
  );

  static const TextStyle h2 = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 22,
    fontWeight: FontWeight.bold,
  );

  static const TextStyle h3 = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 18,
    fontWeight: FontWeight.bold,
  );

  static const TextStyle h4 = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 16,
    fontWeight: FontWeight.w600,
  );

  // Body text - increased for readability
  static const TextStyle bodyLarge = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 16,
    fontWeight: FontWeight.normal,
  );

  static const TextStyle body = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 14,
    fontWeight: FontWeight.normal,
  );

  static const TextStyle bodySmall = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 13,
    fontWeight: FontWeight.normal,
  );

  // Secondary text (for subtitles, hints) - increased
  static const TextStyle subtitle = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 14,
    fontWeight: FontWeight.normal,
  );

  static const TextStyle subtitleSmall = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 13,
    fontWeight: FontWeight.normal,
  );

  static const TextStyle caption = TextStyle(
    color: AppColors.textSecondary,
    fontSize: 12,
    fontWeight: FontWeight.normal,
  );

  // Accent text (gold)
  static const TextStyle accentText = TextStyle(
    color: AppColors.accent,
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle accentLarge = TextStyle(
    color: AppColors.accent,
    fontSize: 18,
    fontWeight: FontWeight.bold,
  );

  // Button text
  static const TextStyle button = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 14,
    fontWeight: FontWeight.w600,
  );

  static const TextStyle buttonSmall = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 13,
    fontWeight: FontWeight.w600,
  );

  // Label text
  static const TextStyle label = TextStyle(
    color: AppColors.textPrimary,
    fontSize: 13,
    fontWeight: FontWeight.w500,
    letterSpacing: 0.5,
  );
}

class AppDecorations {
  // Card decoration
  static BoxDecoration card = BoxDecoration(
    color: AppColors.cardBackground,
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: AppColors.cardBorder),
  );

  // Section card
  static BoxDecoration section = BoxDecoration(
    color: AppColors.overlay,
    borderRadius: BorderRadius.circular(12),
  );

  // Highlighted card (with accent)
  static BoxDecoration highlightCard = BoxDecoration(
    gradient: AppGradients.accentFade,
    borderRadius: BorderRadius.circular(12),
    border: Border.all(color: AppColors.accent.withAlpha(100)),
  );

  // Full screen background
  static const BoxDecoration screenBackground = BoxDecoration(
    gradient: AppGradients.background,
  );

  // Bottom sheet
  static const BoxDecoration bottomSheet = BoxDecoration(
    color: AppColors.primaryDark,
    borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
  );

  // Dialog
  static BoxDecoration dialog = BoxDecoration(
    color: AppColors.primaryDark,
    borderRadius: BorderRadius.circular(16),
  );

  // Icon container
  static BoxDecoration iconContainer(Color color) => BoxDecoration(
    color: color.withAlpha(30),
    borderRadius: BorderRadius.circular(10),
  );

  // Circular badge
  static BoxDecoration circleBadge(Color color) => BoxDecoration(
    color: color.withAlpha(30),
    shape: BoxShape.circle,
  );
}

class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;

  // Padding
  static const EdgeInsets screenPadding = EdgeInsets.all(16);
  static const EdgeInsets cardPadding = EdgeInsets.all(16);
  static const EdgeInsets sectionPadding = EdgeInsets.symmetric(horizontal: 16, vertical: 12);
}

class AppSizes {
  static const double iconSmall = 18;
  static const double iconMedium = 22;
  static const double iconLarge = 28;
  static const double iconXLarge = 40;

  static const double buttonHeight = 48;
  static const double buttonHeightSmall = 36;

  static const double borderRadius = 12;
  static const double borderRadiusLarge = 16;
  static const double borderRadiusSmall = 8;
}

/// Reusable widgets for consistent UI
class AppWidgets {
  /// Standard section header
  static Widget sectionHeader(String title, IconData icon) {
    return Row(
      children: [
        Icon(icon, color: AppColors.accent, size: AppSizes.iconMedium),
        const SizedBox(width: AppSpacing.sm),
        Text(title, style: AppTextStyles.h4),
      ],
    );
  }

  /// Standard card wrapper
  static Widget card({required Widget child, EdgeInsets? padding}) {
    return Container(
      padding: padding ?? AppSpacing.cardPadding,
      decoration: AppDecorations.card,
      child: child,
    );
  }

  /// Divider
  static Widget divider() {
    return const Divider(
      color: AppColors.cardBorder,
      height: 1,
    );
  }

  /// Loading indicator
  static Widget loading() {
    return const Center(
      child: CircularProgressIndicator(color: AppColors.accent),
    );
  }

  /// Empty state
  static Widget emptyState(IconData icon, String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 64, color: AppColors.textHint),
          const SizedBox(height: AppSpacing.lg),
          Text(message, style: AppTextStyles.subtitle),
        ],
      ),
    );
  }
}

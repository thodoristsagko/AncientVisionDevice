import 'package:flutter/material.dart';

class GlassBottomNavBar extends StatelessWidget {
  final int currentIndex;
  final ValueChanged<int> onItemSelected;
  final bool isMuted;
  final VoidCallback onToggleMute;

  const GlassBottomNavBar({
    super.key,
    required this.currentIndex,
    required this.onItemSelected,
    required this.isMuted,
    required this.onToggleMute,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2F2E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Row(
        children: [
          _NavItem(icon: Icons.home_rounded, label: 'Home', index: 0,
              isSelected: currentIndex == 0, onTap: onItemSelected),
          _NavItem(icon: Icons.article_rounded, label: 'Findings', index: 1,
              isSelected: currentIndex == 1, onTap: onItemSelected),
          _NavItem(icon: Icons.apps_rounded, label: 'Tools', index: 2,
              isSelected: currentIndex == 2, onTap: onItemSelected),
          _NavItem(icon: Icons.shield_rounded, label: 'Monitor', index: 3,
              isSelected: currentIndex == 3, onTap: onItemSelected),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onToggleMute,
            child: Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: isMuted ? Colors.red.withAlpha(60) : Colors.green.withAlpha(60),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
                color: isMuted ? Colors.red.shade300 : Colors.green.shade300,
                size: 18,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final int index;
  final bool isSelected;
  final ValueChanged<int> onTap;

  const _NavItem({
    required this.icon, required this.label, required this.index,
    required this.isSelected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = isSelected ? Colors.white : Colors.white54;
    return Expanded(
      child: InkWell(
        onTap: () => onTap(index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(color: color, fontSize: 10,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400)),
          ],
        ),
      ),
    );
  }
}

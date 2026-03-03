import 'package:flutter/material.dart';

/// Reconstruction stage information.
class ReconstructionStage {
  final String name;
  final IconData icon;
  final double startProgress;
  final double endProgress;

  const ReconstructionStage({
    required this.name,
    required this.icon,
    required this.startProgress,
    required this.endProgress,
  });
}

/// Multi-stage progress indicator for 3D reconstruction.
class ReconstructionProgressWidget extends StatelessWidget {
  final double progress;
  final String statusMessage;
  final bool isProcessing;

  static const List<ReconstructionStage> stages = [
    ReconstructionStage(name: 'Load', icon: Icons.photo_library, startProgress: 0.0, endProgress: 0.15),
    ReconstructionStage(name: 'Features', icon: Icons.scatter_plot, startProgress: 0.15, endProgress: 0.45),
    ReconstructionStage(name: 'Match', icon: Icons.compare, startProgress: 0.45, endProgress: 0.65),
    ReconstructionStage(name: 'Poses', icon: Icons.camera, startProgress: 0.65, endProgress: 0.75),
    ReconstructionStage(name: '3D Points', icon: Icons.view_in_ar, startProgress: 0.75, endProgress: 0.85),
    ReconstructionStage(name: 'Optimize', icon: Icons.auto_fix_high, startProgress: 0.85, endProgress: 0.95),
    ReconstructionStage(name: 'Done', icon: Icons.check_circle, startProgress: 0.95, endProgress: 1.0),
  ];

  const ReconstructionProgressWidget({
    super.key,
    required this.progress,
    required this.statusMessage,
    this.isProcessing = false,
  });

  int get _currentStageIndex {
    for (int i = stages.length - 1; i >= 0; i--) {
      if (progress >= stages[i].startProgress) return i;
    }
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    final currentStage = _currentStageIndex;

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2332),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withAlpha(30)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stage indicators
          Row(
            children: List.generate(stages.length, (i) {
              final isActive = i == currentStage;
              final isDone = i < currentStage;
              final color = isDone
                  ? const Color(0xFF4CAF50)
                  : isActive
                      ? const Color(0xFF2196F3)
                      : Colors.white.withAlpha(40);

              return Expanded(
                child: Column(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: color.withAlpha(isDone ? 60 : isActive ? 40 : 15),
                        shape: BoxShape.circle,
                        border: Border.all(color: color, width: isActive ? 2 : 1),
                      ),
                      child: Icon(
                        isDone ? Icons.check : stages[i].icon,
                        color: color,
                        size: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      stages[i].name,
                      style: TextStyle(
                        color: color,
                        fontSize: 9,
                        fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              );
            }),
          ),
          const SizedBox(height: 16),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              backgroundColor: Colors.white.withAlpha(20),
              valueColor: AlwaysStoppedAnimation(
                progress >= 1.0 ? const Color(0xFF4CAF50) : const Color(0xFF2196F3),
              ),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 8),

          // Status text
          Row(
            children: [
              if (isProcessing && progress < 1.0)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF2196F3)),
                ),
              if (isProcessing && progress < 1.0) const SizedBox(width: 8),
              Expanded(
                child: Text(
                  statusMessage,
                  style: TextStyle(color: Colors.white.withAlpha(180), fontSize: 12),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '${(progress * 100).toInt()}%',
                style: const TextStyle(color: Color(0xFF2196F3), fontSize: 13, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

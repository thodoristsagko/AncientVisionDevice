import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/finding_model.dart';

class FindingDetailCard extends StatelessWidget {
  final Finding finding;

  const FindingDetailCard({super.key, required this.finding});

  Widget _buildFindingImage(String imageUrl) {
    return Image.network(
      imageUrl,
      fit: BoxFit.cover,
      width: 80,
      height: 80,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;
        return const Center(
          child: CircularProgressIndicator(
            color: Color(0xFFFFC107),
            strokeWidth: 2,
          ),
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return const Icon(
          Icons.broken_image_outlined,
          color: Colors.white70,
          size: 36,
        );
      },
    );
  }

  Future<void> _open3DModel(BuildContext context) async {
    if (finding.model3dUrl != null) {
      final url = Uri.parse(finding.model3dUrl!);
      if (await canLaunchUrl(url)) {
        await launchUrl(url, mode: LaunchMode.externalApplication);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final typeColor = Finding.getTypeColor(finding.type);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(18),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Finding image with type color border
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(20),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: typeColor.withAlpha(153),
                        width: 2,
                      ),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: finding.imageUrl != null
                          ? _buildFindingImage(finding.imageUrl!)
                          : Icon(
                              Icons.image_outlined,
                              color: typeColor.withAlpha(128),
                              size: 36,
                            ),
                    ),
                  ),
                  const SizedBox(width: 16),

                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            // Type color indicator
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: typeColor,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                finding.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (finding.isSignificant)
                              const Icon(
                                Icons.star,
                                color: Color(0xFFFFC107),
                                size: 18,
                              ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${finding.type} • ${finding.site} • ${finding.date}',
                          style: TextStyle(
                            color: Colors.white.withAlpha(204),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (finding.description.isNotEmpty)
                          Text(
                            finding.description,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 12,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),

              // Action buttons row
              if (finding.model3dUrl != null || finding.photoGallery.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    children: [
                      // 3D Model button
                      if (finding.model3dUrl != null)
                        GestureDetector(
                          onTap: () => _open3DModel(context),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            decoration: BoxDecoration(
                              color: const Color(0xFF7C4DFF).withAlpha(51),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: const Color(0xFF7C4DFF).withAlpha(128),
                                width: 1,
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.view_in_ar_rounded, color: Color(0xFF7C4DFF), size: 16),
                                SizedBox(width: 6),
                                Text(
                                  'View 3D Model',
                                  style: TextStyle(
                                    color: Color(0xFF7C4DFF),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                      if (finding.model3dUrl != null && finding.photoGallery.isNotEmpty)
                        const SizedBox(width: 8),

                      // Photo gallery indicator
                      if (finding.photoGallery.isNotEmpty)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(26),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.photo_library_outlined, color: Colors.white.withAlpha(179), size: 16),
                              const SizedBox(width: 6),
                              Text(
                                '${finding.photoGallery.length} photos',
                                style: TextStyle(
                                  color: Colors.white.withAlpha(179),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
    );
  }
}

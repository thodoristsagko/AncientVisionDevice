import 'package:flutter/material.dart';
import '../models/finding_model.dart';

/// Full-screen details page for a finding
class FindingDetailsPage extends StatelessWidget {
  final Finding finding;

  const FindingDetailsPage({super.key, required this.finding});

  @override
  Widget build(BuildContext context) {
    final typeColor = Finding.getTypeColor(finding.type);

    return Scaffold(
      backgroundColor: const Color(0xFF0D3A39),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(finding.id, style: const TextStyle(color: Colors.white)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Top section: Description (left) and Photo (right)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Left: Name and Description
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Finding name with type color
                      Row(
                        children: [
                          Container(
                            width: 4,
                            height: 24,
                            decoration: BoxDecoration(
                              color: typeColor,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              finding.name,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Type badge
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: typeColor.withAlpha(50),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: typeColor, width: 1),
                        ),
                        child: Text(
                          finding.type,
                          style: TextStyle(
                            color: typeColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Description
                      const Text(
                        'Description',
                        style: TextStyle(
                          color: Colors.white70,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withAlpha(13),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          finding.description.isNotEmpty
                              ? finding.description
                              : 'No description available',
                          style: TextStyle(
                            color: finding.description.isNotEmpty
                                ? Colors.white
                                : Colors.white54,
                            fontSize: 14,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                // Right: Photo
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: finding.imageUrl != null && finding.imageUrl!.isNotEmpty
                            ? Image.network(
                                finding.imageUrl!,
                                height: 180,
                                width: double.infinity,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) => Container(
                                  height: 180,
                                  color: const Color(0xFF1C2523),
                                  child: const Center(
                                    child: Icon(Icons.broken_image, color: Colors.white38, size: 48),
                                  ),
                                ),
                              )
                            : Container(
                                height: 180,
                                color: const Color(0xFF1C2523),
                                child: const Center(
                                  child: Icon(Icons.image_not_supported, color: Colors.white38, size: 48),
                                ),
                              ),
                      ),
                      // Photo gallery thumbnails
                      if (finding.photoGallery.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        SizedBox(
                          height: 50,
                          child: ListView.builder(
                            scrollDirection: Axis.horizontal,
                            itemCount: finding.photoGallery.length,
                            itemBuilder: (context, index) {
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(8),
                                  child: Image.network(
                                    finding.photoGallery[index],
                                    width: 50,
                                    height: 50,
                                    fit: BoxFit.cover,
                                    errorBuilder: (context, error, stackTrace) => Container(
                                      width: 50,
                                      height: 50,
                                      color: const Color(0xFF1C2523),
                                      child: const Icon(Icons.broken_image, color: Colors.white38, size: 20),
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: 24),

            // Bottom section: Details cards
            // Location card
            _buildDetailCard(
              icon: Icons.location_on,
              title: 'Location',
              children: [
                _buildDetailRow('Site', finding.site),
                _buildDetailRow('Coordinates', '${finding.latitude.toStringAsFixed(6)}, ${finding.longitude.toStringAsFixed(6)}'),
              ],
            ),

            const SizedBox(height: 12),

            // Date & Source card
            _buildDetailCard(
              icon: Icons.info_outline,
              title: 'Information',
              children: [
                _buildDetailRow('Date Found', finding.date),
                _buildDetailRow('Source', finding.source.label),
                if (finding.model3dUrl != null)
                  _buildDetailRow('3D Model', 'Available'),
              ],
            ),

            // Coin details card (shown only for coins)
            if (finding.isCoin && _hasCoinData()) ...[
              const SizedBox(height: 12),
              _buildDetailCard(
                icon: Icons.paid,
                title: 'Coin Details',
                children: [
                  if (finding.denomination != null)
                    _buildDetailRow('Denomination', finding.denomination!),
                  if (finding.mint != null)
                    _buildDetailRow('Mint', finding.mint!),
                  if (finding.ruler != null)
                    _buildDetailRow('Ruler/Authority', finding.ruler!),
                  if (finding.obverseLegend != null)
                    _buildDetailRow('Obverse Legend', finding.obverseLegend!),
                  if (finding.reverseLegend != null)
                    _buildDetailRow('Reverse Legend', finding.reverseLegend!),
                  if (finding.dieAxis != null)
                    _buildDetailRow('Die Axis', '${finding.dieAxis} o\'clock'),
                  if (finding.obverseDescription != null)
                    _buildDetailRow('Obverse Desc.', finding.obverseDescription!),
                  if (finding.reverseDescription != null)
                    _buildDetailRow('Reverse Desc.', finding.reverseDescription!),
                ],
              ),
            ],

            // Fragment details card (shown only for fragments)
            if (finding.isFragment && _hasFragmentData()) ...[
              const SizedBox(height: 12),
              _buildDetailCard(
                icon: Icons.broken_image,
                title: 'Fragment Details',
                children: [
                  if (finding.vesselPart != null)
                    _buildDetailRow('Vessel Part', finding.vesselPart!),
                  if (finding.wareType != null)
                    _buildDetailRow('Ware Type', finding.wareType!),
                  if (finding.decorationStyle != null)
                    _buildDetailRow('Decoration', finding.decorationStyle!),
                  if (finding.rimDiameter != null)
                    _buildDetailRow('Rim Diameter', '${finding.rimDiameter} mm'),
                  if (finding.wallThickness != null)
                    _buildDetailRow('Wall Thickness', '${finding.wallThickness} mm'),
                  if (finding.fabricColorInt != null)
                    _buildDetailRow('Interior Color', finding.fabricColorInt!),
                  if (finding.fabricColorExt != null)
                    _buildDetailRow('Exterior Color', finding.fabricColorExt!),
                  if (finding.surfaceTreatment != null)
                    _buildDetailRow('Surface Treatment', finding.surfaceTreatment!),
                ],
              ),
            ],

            // Context details card (shown if context data exists)
            if (_hasContextData()) ...[
              const SizedBox(height: 12),
              _buildDetailCard(
                icon: Icons.layers,
                title: 'Stratigraphic Context',
                children: [
                  if (finding.locusNumber != null)
                    _buildDetailRow('Locus/Context', finding.locusNumber!),
                  if (finding.soilType != null)
                    _buildDetailRow('Soil Type', finding.soilType!),
                  if (finding.matrixDescription != null)
                    _buildDetailRow('Matrix', finding.matrixDescription!),
                  if (finding.harrisPosition != null)
                    _buildDetailRow('Harris Position', finding.harrisPosition!),
                  if (finding.associatedFeatures != null && finding.associatedFeatures!.isNotEmpty)
                    _buildDetailRow('Associated', finding.associatedFeatures!.join(', ')),
                ],
              ),
            ],

            const SizedBox(height: 12),

            // 3D Model button if available
            if (finding.model3dUrl != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: const Color(0xFF7C4DFF).withAlpha(30),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF7C4DFF), width: 1),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.view_in_ar, color: Color(0xFF7C4DFF), size: 32),
                    SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '3D Model Available',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Text(
                            'View the reconstructed 3D model',
                            style: TextStyle(color: Colors.white70, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    Icon(Icons.arrow_forward_ios, color: Color(0xFF7C4DFF), size: 20),
                  ],
                ),
              ),

            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailCard({
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withAlpha(13),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: const Color(0xFFFFC107), size: 20),
              const SizedBox(width: 8),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(color: Colors.white54, fontSize: 13),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  /// Check if finding has any coin-specific data
  bool _hasCoinData() {
    return finding.denomination != null ||
        finding.mint != null ||
        finding.ruler != null ||
        finding.obverseLegend != null ||
        finding.reverseLegend != null ||
        finding.dieAxis != null ||
        finding.obverseDescription != null ||
        finding.reverseDescription != null;
  }

  /// Check if finding has any fragment-specific data
  bool _hasFragmentData() {
    return finding.vesselPart != null ||
        finding.wareType != null ||
        finding.decorationStyle != null ||
        finding.rimDiameter != null ||
        finding.wallThickness != null ||
        finding.fabricColorInt != null ||
        finding.fabricColorExt != null ||
        finding.surfaceTreatment != null;
  }

  /// Check if finding has any context/stratigraphic data
  bool _hasContextData() {
    return finding.locusNumber != null ||
        finding.soilType != null ||
        finding.matrixDescription != null ||
        finding.harrisPosition != null ||
        (finding.associatedFeatures != null && finding.associatedFeatures!.isNotEmpty);
  }
}

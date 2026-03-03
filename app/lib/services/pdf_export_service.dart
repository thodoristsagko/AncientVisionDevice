import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';
import '../models/finding_model.dart';

class PdfExportService {
  /// Fetches all findings from Firestore, generates a PDF report, and shares it.
  Future<void> exportFindingsReport(BuildContext context) async {
    // 1. Fetch findings
    final snapshot = await FirebaseFirestore.instance
        .collection('findings')
        .orderBy('createdAt', descending: true)
        .get()
        .timeout(const Duration(seconds: 15));

    final findings = snapshot.docs.map((doc) {
      final data = doc.data();
      return Finding(
        id: doc.id,
        name: data['name'] ?? 'Unknown',
        type: data['type'] ?? '',
        site: data['site'] ?? '',
        date: data['date'] ?? '',
        description: data['description'] ?? '',
        latitude: (data['latitude'] ?? 0.0).toDouble(),
        longitude: (data['longitude'] ?? 0.0).toDouble(),
        imageUrl: data['imageUrl'],
        photoGallery: data['photoGallery'] != null
            ? List<String>.from(data['photoGallery'])
            : [],
        source: FindingSource.fromString(data['source']),
        denomination: data['denomination'],
        mint: data['mint'],
        ruler: data['ruler'],
        locusNumber: data['locusNumber'],
        isSignificant: data['isSignificant'] ?? false,
      );
    }).toList();

    // 2. Build PDF
    final pdf = pw.Document();
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text(
              'AncientVision — Findings Report',
              style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(
              'Generated: ${DateTime.now().toLocal().toString().substring(0, 16)}  |  Total: ${findings.length} findings',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
            ),
            pw.Divider(),
          ],
        ),
        build: (ctx) => findings.map((f) => _buildFindingBlock(f)).toList(),
      ),
    );

    // 3. Save to temp file
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/ancientvision_report.pdf');
    await file.writeAsBytes(await pdf.save());

    // 4. Share
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'AncientVision Findings Report',
    );
  }

  pw.Widget _buildFindingBlock(Finding f) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 12),
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        border: pw.Border.all(color: PdfColors.grey300),
        borderRadius: const pw.BorderRadius.all(pw.Radius.circular(4)),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(
                '${f.name}${f.isSignificant ? '  ★' : ''}',
                style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
              ),
              pw.Text(f.date, style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600)),
            ],
          ),
          pw.SizedBox(height: 4),
          pw.Text('Type: ${f.type}   Site: ${f.site}   Source: ${f.source.label}',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          if (f.latitude != 0 || f.longitude != 0)
            pw.Text(
              'Coords: ${f.latitude.toStringAsFixed(5)}, ${f.longitude.toStringAsFixed(5)}',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
          if (f.description.isNotEmpty) ...[
            pw.SizedBox(height: 4),
            pw.Text(f.description, style: const pw.TextStyle(fontSize: 10)),
          ],
          if (f.locusNumber != null)
            pw.Text('Locus: ${f.locusNumber}',
                style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
          if (f.denomination != null || f.mint != null || f.ruler != null)
            pw.Text(
              [
                if (f.denomination != null) 'Denom: ${f.denomination}',
                if (f.mint != null) 'Mint: ${f.mint}',
                if (f.ruler != null) 'Ruler: ${f.ruler}',
              ].join('   '),
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
            ),
        ],
      ),
    );
  }
}

import 'package:flutter_test/flutter_test.dart';
import 'package:ancient_vision/services/metadata_export_service.dart';

void main() {
  // ---------------------------------------------------------------------------
  // Dublin Core XML
  // ---------------------------------------------------------------------------
  group('Dublin Core export', () {
    test('produces valid XML with all required elements', () {
      final xml = MetadataExportService.exportDublinCore(
        id: 'AV-2026-001',
        title: 'Bronze coin fragment',
        description: 'Bronze fragment found at excavation site',
        date: DateTime(2026, 2, 10),
        creator: 'AncientVision App',
        latitude: 37.9838,
        longitude: 23.7275,
      );

      expect(xml, contains('<?xml version="1.0" encoding="UTF-8"?>'));
      expect(xml, contains('<dc:title>Bronze coin fragment</dc:title>'));
      expect(xml, contains('<dc:creator>AncientVision App</dc:creator>'));
      expect(xml, contains('<dc:subject>Archaeological finding</dc:subject>'));
      expect(xml, contains('<dc:description>Bronze fragment found at excavation site</dc:description>'));
      expect(xml, contains('<dc:date>2026-02-10</dc:date>'));
      expect(xml, contains('<dc:type>PhysicalObject</dc:type>'));
      expect(xml, contains('<dc:format>application/json</dc:format>'));
      expect(xml, contains('<dc:identifier>AV-2026-001</dc:identifier>'));
      expect(xml, contains('<dc:rights>CC BY-NC 4.0</dc:rights>'));
      // Coverage with GPS
      expect(xml, contains('<dc:coverage>'));
      expect(xml, contains('37.9838'));
      expect(xml, contains('23.7275'));
    });

    test('omits creator when null', () {
      final xml = MetadataExportService.exportDublinCore(
        id: 'AV-2026-002',
        title: 'Pottery shard',
        description: 'A small fragment',
        date: DateTime(2026, 3, 15),
      );

      expect(xml, isNot(contains('<dc:creator>')));
      expect(xml, isNot(contains('null')));
    });

    test('omits coverage when lat/lon are null', () {
      final xml = MetadataExportService.exportDublinCore(
        id: 'AV-2026-003',
        title: 'Stone tool',
        description: 'Obsidian blade',
        date: DateTime(2026, 1, 5),
      );

      expect(xml, isNot(contains('<dc:coverage>')));
      expect(xml, isNot(contains('null')));
    });

    test('includes additional Dublin Core fields', () {
      final xml = MetadataExportService.exportDublinCore(
        id: 'AV-2026-004',
        title: 'Amphora handle',
        description: 'Ceramic handle',
        date: DateTime(2026, 4, 1),
        additionalFields: {
          'publisher': 'National Museum',
          'language': 'en',
        },
      );

      expect(xml, contains('<dc:publisher>National Museum</dc:publisher>'));
      expect(xml, contains('<dc:language>en</dc:language>'));
    });
  });

  // ---------------------------------------------------------------------------
  // XML escaping
  // ---------------------------------------------------------------------------
  group('XML escaping', () {
    test('escapes ampersand, angle brackets, quotes in Dublin Core', () {
      final xml = MetadataExportService.exportDublinCore(
        id: 'AV-2026-005',
        title: 'Coin <"Bronze" & \'Gold\'>',
        description: 'Desc with & and <tag>',
        date: DateTime(2026, 5, 20),
      );

      expect(xml, contains('&amp;'));
      expect(xml, contains('&lt;'));
      expect(xml, contains('&gt;'));
      expect(xml, contains('&quot;'));
      expect(xml, contains('&apos;'));
      // Must not contain raw unescaped characters in element content
      // (other than the XML structure itself)
      expect(xml, isNot(contains('<"Bronze"')));
    });

    test('escapes special characters in CIDOC-CRM', () {
      final xml = MetadataExportService.exportCidocCRM(
        id: 'AV-2026-006',
        title: 'Item <special>&',
        description: 'A "special" item',
        objectType: 'Coin & Medal',
        dateFound: DateTime(2026, 6, 1),
      );

      expect(xml, contains('&amp;'));
      expect(xml, contains('&lt;'));
      expect(xml, contains('&gt;'));
      expect(xml, contains('&quot;'));
    });
  });

  // ---------------------------------------------------------------------------
  // CIDOC-CRM RDF/XML
  // ---------------------------------------------------------------------------
  group('CIDOC-CRM export', () {
    test('contains E22, E7, E53, E52 classes', () {
      final xml = MetadataExportService.exportCidocCRM(
        id: 'AV-2026-010',
        title: 'Bronze statuette',
        description: 'Small bronze figure',
        objectType: 'Statuette',
        dateFound: DateTime(2026, 7, 15),
        latitude: 37.9715,
        longitude: 23.7267,
      );

      expect(xml, contains('E22_Human-Made_Object'));
      expect(xml, contains('E7_Activity'));
      expect(xml, contains('E53_Place'));
      expect(xml, contains('E52_Time-Span'));
      expect(xml, contains('E55_Type'));
      expect(xml, contains('E12_Production'));
    });

    test('includes finder as E39 Actor', () {
      final xml = MetadataExportService.exportCidocCRM(
        id: 'AV-2026-011',
        title: 'Ring fragment',
        description: 'Gold ring',
        objectType: 'Ring',
        dateFound: DateTime(2026, 8, 1),
        finder: 'Dr. Maria Papadopoulos',
      );

      expect(xml, contains('E39_Actor'));
      expect(xml, contains('Dr. Maria Papadopoulos'));
      expect(xml, contains('P14_carried_out_by'));
    });

    test('includes material via P45 and condition via P44', () {
      final xml = MetadataExportService.exportCidocCRM(
        id: 'AV-2026-012',
        title: 'Marble column fragment',
        description: 'Doric column section',
        objectType: 'Architectural element',
        dateFound: DateTime(2026, 9, 1),
        material: 'Pentelic Marble',
        condition: 'Fragmented, surface erosion',
      );

      expect(xml, contains('E57_Material'));
      expect(xml, contains('Pentelic Marble'));
      expect(xml, contains('P45_consists_of'));
      expect(xml, contains('E3_Condition_State'));
      expect(xml, contains('Fragmented, surface erosion'));
      expect(xml, contains('P44_has_condition'));
    });

    test('includes period in E12 Production', () {
      final xml = MetadataExportService.exportCidocCRM(
        id: 'AV-2026-013',
        title: 'Attic black-figure lekythos',
        description: 'Oil flask with mythological scene',
        objectType: 'Vessel',
        dateFound: DateTime(2026, 10, 1),
        period: '5th century BCE',
      );

      expect(xml, contains('5th century BCE'));
      expect(xml, contains('E12_Production'));
    });

    test('omits optional fields when null', () {
      final xml = MetadataExportService.exportCidocCRM(
        id: 'AV-2026-014',
        title: 'Unknown fragment',
        description: 'Unidentified object',
        objectType: 'Unknown',
        dateFound: DateTime(2026, 11, 1),
      );

      expect(xml, isNot(contains('E39_Actor')));
      expect(xml, isNot(contains('E53_Place')));
      expect(xml, isNot(contains('E57_Material')));
      expect(xml, isNot(contains('E3_Condition_State')));
      expect(xml, isNot(contains('null')));
    });

    test('GPS coordinates formatted correctly', () {
      final xml = MetadataExportService.exportCidocCRM(
        id: 'AV-2026-015',
        title: 'Test',
        description: 'Test',
        objectType: 'Test',
        dateFound: DateTime(2026, 1, 1),
        latitude: -33.8688,
        longitude: 151.2093,
      );

      // Southern hemisphere → S, Eastern → E
      expect(xml, contains('33.8688'));
      expect(xml, contains('S'));
      expect(xml, contains('151.2093'));
      expect(xml, contains('E'));
    });

    test('includes additional properties as P3 notes', () {
      final xml = MetadataExportService.exportCidocCRM(
        id: 'AV-2026-016',
        title: 'Inscribed tablet',
        description: 'Stone tablet with inscription',
        objectType: 'Inscription',
        dateFound: DateTime(2026, 12, 1),
        additionalProperties: {
          'script': 'Linear B',
          'weight': '2.3 kg',
        },
      );

      expect(xml, contains('script: Linear B'));
      expect(xml, contains('weight: 2.3 kg'));
      expect(xml, contains('P3_has_note'));
    });
  });

  // ---------------------------------------------------------------------------
  // Vibration Monitoring Report
  // ---------------------------------------------------------------------------
  group('Vibration report export', () {
    test('includes all summary fields', () {
      final xml = MetadataExportService.exportVibrationReport(
        siteName: 'Parthenon East Wall',
        startTime: DateTime.utc(2026, 2, 10, 8, 0, 0),
        endTime: DateTime.utc(2026, 2, 10, 17, 0, 0),
        maxPPV: 4.2,
        meanPPV: 0.8,
        ariasIntensity: 0.003,
        cav: 0.02,
        damageIndex: 0.05,
        alertsTriggered: 2,
      );

      expect(xml, contains('<site>Parthenon East Wall</site>'));
      expect(xml, contains('<max-ppv unit="mm/s">4.2</max-ppv>'));
      expect(xml, contains('<mean-ppv unit="mm/s">0.8</mean-ppv>'));
      expect(xml, contains('<arias-intensity unit="m/s">0.003</arias-intensity>'));
      expect(xml, contains('<cav unit="g-s">0.02</cav>'));
      expect(xml, contains('<damage-index>0.05</damage-index>'));
      expect(xml, contains('<alerts-triggered>2</alerts-triggered>'));
      expect(xml, contains('<standard>DIN 4150-3:2016</standard>'));
      expect(xml, contains('<compliance>partial</compliance>'));
    });

    test('compliance is compliant when maxPPV <= 3.0', () {
      final xml = MetadataExportService.exportVibrationReport(
        siteName: 'Test Site',
        startTime: DateTime.utc(2026, 1, 1),
        endTime: DateTime.utc(2026, 1, 2),
        maxPPV: 2.5,
        meanPPV: 1.0,
      );

      expect(xml, contains('<compliance>compliant</compliance>'));
    });

    test('compliance is non-compliant when maxPPV > 8.0', () {
      final xml = MetadataExportService.exportVibrationReport(
        siteName: 'Test Site',
        startTime: DateTime.utc(2026, 1, 1),
        endTime: DateTime.utc(2026, 1, 2),
        maxPPV: 10.0,
        meanPPV: 5.0,
      );

      expect(xml, contains('<compliance>non-compliant</compliance>'));
    });

    test('includes events with attributes', () {
      final xml = MetadataExportService.exportVibrationReport(
        siteName: 'Acropolis North',
        startTime: DateTime.utc(2026, 2, 10, 8, 0, 0),
        endTime: DateTime.utc(2026, 2, 10, 17, 0, 0),
        maxPPV: 4.2,
        meanPPV: 0.8,
        events: [
          {
            'timestamp': DateTime.utc(2026, 2, 10, 10, 30, 0),
            'type': 'machinery',
            'ppv': 4.2,
            'freq': 25.0,
          },
          {
            'timestamp': '2026-02-10T14:15:00Z',
            'type': 'impact',
            'ppv': 3.1,
            'freq': 50.0,
          },
        ],
      );

      expect(xml, contains('<events>'));
      expect(xml, contains('type="machinery"'));
      expect(xml, contains('ppv="4.2"'));
      expect(xml, contains('freq="25.0"'));
      expect(xml, contains('type="impact"'));
      expect(xml, contains('ppv="3.1"'));
    });

    test('omits optional summary fields when null', () {
      final xml = MetadataExportService.exportVibrationReport(
        siteName: 'Minimal Site',
        startTime: DateTime.utc(2026, 1, 1),
        endTime: DateTime.utc(2026, 1, 2),
        maxPPV: 1.0,
        meanPPV: 0.5,
      );

      expect(xml, isNot(contains('<arias-intensity')));
      expect(xml, isNot(contains('<cav')));
      expect(xml, isNot(contains('<damage-index')));
      expect(xml, isNot(contains('<events>')));
      expect(xml, isNot(contains('null')));
    });

    test('escapes special characters in site name', () {
      final xml = MetadataExportService.exportVibrationReport(
        siteName: 'Site "A" & <B>',
        startTime: DateTime.utc(2026, 1, 1),
        endTime: DateTime.utc(2026, 1, 2),
        maxPPV: 1.0,
        meanPPV: 0.5,
      );

      expect(xml, contains('&amp;'));
      expect(xml, contains('&lt;'));
      expect(xml, contains('&gt;'));
      expect(xml, contains('&quot;'));
    });
  });

  // ---------------------------------------------------------------------------
  // Collection export
  // ---------------------------------------------------------------------------
  group('Collection export', () {
    test('wraps multiple findings in collection element', () {
      final xml = MetadataExportService.exportFindingsCollection([
        {
          'id': 'AV-2026-001',
          'title': 'Coin fragment',
          'description': 'Bronze coin',
          'date': DateTime(2026, 2, 10),
          'latitude': 37.9838,
          'longitude': 23.7275,
        },
        {
          'id': 'AV-2026-002',
          'title': 'Pottery shard',
          'description': 'Red-figure pottery',
          'date': '2026-03-15',
          'creator': 'Field Team A',
        },
      ]);

      expect(xml, contains('<collection'));
      expect(xml, contains('</collection>'));
      // Two records
      expect(
        RegExp(r'<record>').allMatches(xml).length,
        equals(2),
      );
      // First finding
      expect(xml, contains('<dc:identifier>AV-2026-001</dc:identifier>'));
      expect(xml, contains('<dc:title>Coin fragment</dc:title>'));
      expect(xml, contains('<dc:coverage>'));
      // Second finding
      expect(xml, contains('<dc:identifier>AV-2026-002</dc:identifier>'));
      expect(xml, contains('<dc:creator>Field Team A</dc:creator>'));
    });

    test('handles date as ISO string', () {
      final xml = MetadataExportService.exportFindingsCollection([
        {
          'id': 'AV-2026-050',
          'title': 'Test',
          'description': 'Test desc',
          'date': '2026-06-15',
        },
      ]);

      expect(xml, contains('<dc:date>2026-06-15</dc:date>'));
    });

    test('omits optional fields when null in collection entries', () {
      final xml = MetadataExportService.exportFindingsCollection([
        {
          'id': 'AV-2026-060',
          'title': 'Minimal record',
          'description': 'Only required fields',
          'date': DateTime(2026, 1, 1),
        },
      ]);

      expect(xml, isNot(contains('<dc:creator>')));
      expect(xml, isNot(contains('<dc:coverage>')));
      expect(xml, isNot(contains('null')));
    });
  });
}

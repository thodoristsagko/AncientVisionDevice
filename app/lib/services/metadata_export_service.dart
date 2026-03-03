/// Archaeological metadata export service supporting CIDOC-CRM (ISO 21127)
/// and Dublin Core standards for interoperability with world heritage databases.
///
/// Generates valid XML without external dependencies - only dart:convert
/// is used for XML character escaping.
library;

class MetadataExportService {
  // ---------------------------------------------------------------------------
  // XML helpers
  // ---------------------------------------------------------------------------

  /// Escape special XML characters: & < > " '
  static String _xmlEscape(String input) {
    return input
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }

  /// Format a [DateTime] as ISO-8601 date only (YYYY-MM-DD).
  static String _isoDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  /// Format a [DateTime] as full ISO-8601 with timezone (UTC).
  static String _isoDateTime(DateTime dt) {
    return dt.toUtc().toIso8601String();
  }

  /// Format GPS coordinates as a human-readable string.
  static String _formatCoordinates(double latitude, double longitude) {
    final latDir = latitude >= 0 ? 'N' : 'S';
    final lonDir = longitude >= 0 ? 'E' : 'W';
    final latAbs = latitude.abs().toStringAsFixed(4);
    final lonAbs = longitude.abs().toStringAsFixed(4);
    return '$latAbs\u00B0 $latDir, $lonAbs\u00B0 $lonDir';
  }

  /// Convert an [objectType] string such as "Coin Fragment" into a URI-safe
  /// slug like "coin_fragment".
  static String _slugify(String value) {
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  // ---------------------------------------------------------------------------
  // Dublin Core XML Export
  // ---------------------------------------------------------------------------

  /// Export a single archaeological finding as Dublin Core XML.
  ///
  /// All 15 Dublin Core elements are supported. Required fields are [id],
  /// [title], [description], and [date]. Optional fields are omitted from the
  /// output when `null` (they are never rendered as the literal string "null").
  ///
  /// Additional arbitrary DC fields can be supplied via [additionalFields],
  /// keyed by the element local-name (e.g. `{'publisher': 'Some Museum'}`).
  static String exportDublinCore({
    required String id,
    required String title,
    required String description,
    required DateTime date,
    String? creator,
    double? latitude,
    double? longitude,
    String type = 'PhysicalObject',
    String rights = 'CC BY-NC 4.0',
    Map<String, String>? additionalFields,
  }) {
    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln(
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">');
    buf.writeln('  <dc:title>${_xmlEscape(title)}</dc:title>');
    if (creator != null) {
      buf.writeln('  <dc:creator>${_xmlEscape(creator)}</dc:creator>');
    }
    buf.writeln('  <dc:subject>Archaeological finding</dc:subject>');
    buf.writeln(
        '  <dc:description>${_xmlEscape(description)}</dc:description>');
    buf.writeln('  <dc:date>${_isoDate(date)}</dc:date>');
    buf.writeln('  <dc:type>${_xmlEscape(type)}</dc:type>');
    buf.writeln('  <dc:format>application/json</dc:format>');
    buf.writeln('  <dc:identifier>${_xmlEscape(id)}</dc:identifier>');
    if (latitude != null && longitude != null) {
      buf.writeln(
          '  <dc:coverage>${_formatCoordinates(latitude, longitude)}</dc:coverage>');
    }
    buf.writeln('  <dc:rights>${_xmlEscape(rights)}</dc:rights>');

    // Additional Dublin Core fields
    if (additionalFields != null) {
      for (final entry in additionalFields.entries) {
        buf.writeln(
            '  <dc:${_xmlEscape(entry.key)}>${_xmlEscape(entry.value)}</dc:${_xmlEscape(entry.key)}>');
      }
    }

    buf.writeln('</metadata>');
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // CIDOC-CRM RDF/XML Export
  // ---------------------------------------------------------------------------

  /// Export a single archaeological finding as CIDOC-CRM RDF/XML (ISO 21127).
  ///
  /// The output uses the following CIDOC-CRM entity classes:
  /// - **E22 Human-Made Object** - the finding itself
  /// - **E55 Type** - classification of the object
  /// - **E12 Production** - the production/creation event of the object
  /// - **E7 Activity** - the finding/excavation event
  /// - **E53 Place** - the location where the finding was made
  /// - **E52 Time-Span** - when the finding was discovered
  /// - **E39 Actor** - who discovered the finding
  ///
  /// Optional fields ([finder], [latitude]/[longitude], [material], [period],
  /// [condition]) are omitted from the output when `null`.
  static String exportCidocCRM({
    required String id,
    required String title,
    required String description,
    required String objectType,
    required DateTime dateFound,
    String? finder,
    double? latitude,
    double? longitude,
    String? material,
    String? period,
    String? condition,
    Map<String, String>? additionalProperties,
  }) {
    const esc = _xmlEscape;
    final slug = _slugify(objectType);
    final dateStr = _isoDate(dateFound);

    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln('<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"');
    buf.writeln('         xmlns:crm="http://www.cidoc-crm.org/cidoc-crm/"');
    buf.writeln('         xmlns:rdfs="http://www.w3.org/2000/01/rdf-schema#">');

    // ---- E22 Human-Made Object ----
    buf.writeln();
    buf.writeln('  <!-- The physical object -->');
    buf.writeln(
        '  <crm:E22_Human-Made_Object rdf:about="urn:ancientvision:finding:${esc(id)}">');
    buf.writeln('    <rdfs:label>${esc(title)}</rdfs:label>');

    // P2 has type → E55 Type
    buf.writeln('    <crm:P2_has_type>');
    buf.writeln(
        '      <crm:E55_Type rdf:about="urn:ancientvision:type:${esc(slug)}">');
    buf.writeln('        <rdfs:label>${esc(objectType)}</rdfs:label>');
    buf.writeln('      </crm:E55_Type>');
    buf.writeln('    </crm:P2_has_type>');

    // P3 has note (description)
    buf.writeln(
        '    <crm:P3_has_note>${esc(description)}</crm:P3_has_note>');

    // Material via P45 consists of → E57 Material
    if (material != null) {
      buf.writeln('    <crm:P45_consists_of>');
      buf.writeln(
          '      <crm:E57_Material rdf:about="urn:ancientvision:material:${esc(_slugify(material))}">');
      buf.writeln('        <rdfs:label>${esc(material)}</rdfs:label>');
      buf.writeln('      </crm:E57_Material>');
      buf.writeln('    </crm:P45_consists_of>');
    }

    // Condition via P44 has condition → E3 Condition State
    if (condition != null) {
      buf.writeln('    <crm:P44_has_condition>');
      buf.writeln('      <crm:E3_Condition_State>');
      buf.writeln('        <rdfs:label>${esc(condition)}</rdfs:label>');
      buf.writeln('      </crm:E3_Condition_State>');
      buf.writeln('    </crm:P44_has_condition>');
    }

    // Period via P108i was produced by → E12 Production
    buf.writeln('    <crm:P108i_was_produced_by>');
    buf.writeln(
        '      <crm:E12_Production rdf:about="urn:ancientvision:production:${esc(id)}">');
    if (period != null) {
      buf.writeln('        <crm:P4_has_time-span>');
      buf.writeln('          <crm:E52_Time-Span>');
      buf.writeln(
          '            <rdfs:label>${esc(period)}</rdfs:label>');
      buf.writeln('          </crm:E52_Time-Span>');
      buf.writeln('        </crm:P4_has_time-span>');
    }
    buf.writeln('      </crm:E12_Production>');
    buf.writeln('    </crm:P108i_was_produced_by>');

    // Additional properties as P3 notes
    if (additionalProperties != null) {
      for (final entry in additionalProperties.entries) {
        buf.writeln(
            '    <crm:P3_has_note>${esc('${entry.key}: ${entry.value}')}</crm:P3_has_note>');
      }
    }

    buf.writeln('  </crm:E22_Human-Made_Object>');

    // ---- E7 Activity (finding event) ----
    buf.writeln();
    buf.writeln('  <!-- The finding event -->');
    buf.writeln(
        '  <crm:E7_Activity rdf:about="urn:ancientvision:finding-event:${esc(id)}">');
    buf.writeln(
        '    <rdfs:label>Archaeological excavation finding</rdfs:label>');

    // P4 has time-span → E52 Time-Span
    buf.writeln('    <crm:P4_has_time-span>');
    buf.writeln('      <crm:E52_Time-Span>');
    buf.writeln(
        '        <crm:P82_at_some_time_within>$dateStr</crm:P82_at_some_time_within>');
    buf.writeln('      </crm:E52_Time-Span>');
    buf.writeln('    </crm:P4_has_time-span>');

    // P7 took place at → E53 Place
    if (latitude != null && longitude != null) {
      buf.writeln('    <crm:P7_took_place_at>');
      buf.writeln('      <crm:E53_Place>');
      buf.writeln(
          '        <rdfs:label>${_formatCoordinates(latitude, longitude)}</rdfs:label>');
      buf.writeln('      </crm:E53_Place>');
      buf.writeln('    </crm:P7_took_place_at>');
    }

    // P14 carried out by → E39 Actor
    if (finder != null) {
      buf.writeln('    <crm:P14_carried_out_by>');
      buf.writeln(
          '      <crm:E39_Actor rdf:about="urn:ancientvision:actor:${esc(_slugify(finder))}">');
      buf.writeln('        <rdfs:label>${esc(finder)}</rdfs:label>');
      buf.writeln('      </crm:E39_Actor>');
      buf.writeln('    </crm:P14_carried_out_by>');
    }

    buf.writeln('  </crm:E7_Activity>');

    buf.writeln();
    buf.writeln('</rdf:RDF>');
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // Vibration Monitoring Report Export
  // ---------------------------------------------------------------------------

  /// Export a vibration monitoring report as structured XML.
  ///
  /// The report follows the DIN 4150-3 standard (configurable via [standard])
  /// and includes summary statistics plus individual events.
  static String exportVibrationReport({
    required String siteName,
    required DateTime startTime,
    required DateTime endTime,
    required double maxPPV,
    required double meanPPV,
    double? ariasIntensity,
    double? cav,
    double? damageIndex,
    int alertsTriggered = 0,
    String standard = 'DIN 4150-3:2016',
    List<Map<String, dynamic>>? events,
  }) {
    const esc = _xmlEscape;

    // Determine compliance based on DIN 4150-3 heritage limit (3 mm/s)
    String compliance;
    if (maxPPV <= 3.0) {
      compliance = 'compliant';
    } else if (maxPPV <= 8.0) {
      compliance = 'partial';
    } else {
      compliance = 'non-compliant';
    }

    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln('<vibration-monitoring-report>');
    buf.writeln('  <site>${esc(siteName)}</site>');
    buf.writeln('  <monitoring-period>');
    buf.writeln('    <start>${_isoDateTime(startTime)}</start>');
    buf.writeln('    <end>${_isoDateTime(endTime)}</end>');
    buf.writeln('  </monitoring-period>');
    buf.writeln('  <standard>${esc(standard)}</standard>');

    // Summary
    buf.writeln('  <summary>');
    buf.writeln(
        '    <max-ppv unit="mm/s">${maxPPV.toStringAsFixed(1)}</max-ppv>');
    buf.writeln(
        '    <mean-ppv unit="mm/s">${meanPPV.toStringAsFixed(1)}</mean-ppv>');
    if (ariasIntensity != null) {
      buf.writeln(
          '    <arias-intensity unit="m/s">${ariasIntensity.toStringAsFixed(3)}</arias-intensity>');
    }
    if (cav != null) {
      buf.writeln(
          '    <cav unit="g-s">${cav.toStringAsFixed(2)}</cav>');
    }
    if (damageIndex != null) {
      buf.writeln(
          '    <damage-index>${damageIndex.toStringAsFixed(2)}</damage-index>');
    }
    buf.writeln(
        '    <alerts-triggered>$alertsTriggered</alerts-triggered>');
    buf.writeln('    <compliance>$compliance</compliance>');
    buf.writeln('  </summary>');

    // Events
    if (events != null && events.isNotEmpty) {
      buf.writeln('  <events>');
      for (final event in events) {
        final timestamp = event['timestamp'];
        final type = event['type'] ?? 'unknown';
        final ppv = event['ppv'];
        final freq = event['freq'];

        buf.write('    <event');
        if (timestamp != null) {
          final ts = timestamp is DateTime
              ? _isoDateTime(timestamp)
              : timestamp.toString();
          buf.write(' timestamp="${esc(ts)}"');
        }
        buf.write(' type="${esc(type.toString())}"');
        if (ppv != null) {
          buf.write(' ppv="${(ppv as num).toStringAsFixed(1)}"');
        }
        if (freq != null) {
          buf.write(' freq="${(freq as num).toStringAsFixed(1)}"');
        }
        buf.writeln('/>');
      }
      buf.writeln('  </events>');
    }

    buf.writeln('</vibration-monitoring-report>');
    return buf.toString();
  }

  // ---------------------------------------------------------------------------
  // Collection Export
  // ---------------------------------------------------------------------------

  /// Export multiple findings as a Dublin Core collection.
  ///
  /// Each entry in [findings] must contain at least `id`, `title`,
  /// `description`, and `date` (either a [DateTime] or an ISO-8601 string).
  /// All other Dublin Core fields are optional.
  static String exportFindingsCollection(List<Map<String, dynamic>> findings) {
    final buf = StringBuffer();
    buf.writeln('<?xml version="1.0" encoding="UTF-8"?>');
    buf.writeln(
        '<collection xmlns:dc="http://purl.org/dc/elements/1.1/">');

    for (final finding in findings) {
      final id = finding['id'] as String;
      final title = finding['title'] as String;
      final description = finding['description'] as String;

      // Accept DateTime or String for date
      final rawDate = finding['date'];
      final DateTime date;
      if (rawDate is DateTime) {
        date = rawDate;
      } else {
        date = DateTime.parse(rawDate.toString());
      }

      final creator = finding['creator'] as String?;
      final latitude = finding['latitude'] as double?;
      final longitude = finding['longitude'] as double?;
      final type = (finding['type'] as String?) ?? 'PhysicalObject';
      final rights = (finding['rights'] as String?) ?? 'CC BY-NC 4.0';

      buf.writeln('  <record>');
      buf.writeln('    <dc:title>${_xmlEscape(title)}</dc:title>');
      if (creator != null) {
        buf.writeln(
            '    <dc:creator>${_xmlEscape(creator)}</dc:creator>');
      }
      buf.writeln(
          '    <dc:subject>Archaeological finding</dc:subject>');
      buf.writeln(
          '    <dc:description>${_xmlEscape(description)}</dc:description>');
      buf.writeln('    <dc:date>${_isoDate(date)}</dc:date>');
      buf.writeln('    <dc:type>${_xmlEscape(type)}</dc:type>');
      buf.writeln('    <dc:format>application/json</dc:format>');
      buf.writeln(
          '    <dc:identifier>${_xmlEscape(id)}</dc:identifier>');
      if (latitude != null && longitude != null) {
        buf.writeln(
            '    <dc:coverage>${_formatCoordinates(latitude, longitude)}</dc:coverage>');
      }
      buf.writeln('    <dc:rights>${_xmlEscape(rights)}</dc:rights>');
      buf.writeln('  </record>');
    }

    buf.writeln('</collection>');
    return buf.toString();
  }
}

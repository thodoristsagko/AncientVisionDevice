import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Tutorial step for guided tours
class TutorialStep {
  final String id;
  final String title;
  final String description;
  final IconData icon;
  final String? targetKey; // Key for highlighting UI element
  final String? imagePath;

  const TutorialStep({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    this.targetKey,
    this.imagePath,
  });
}

/// Help topic category
enum HelpCategory {
  gettingStarted('Getting Started', Icons.play_arrow),
  findings('Findings', Icons.search),
  fieldwork('Fieldwork', Icons.landscape),
  dataManagement('Data & Export', Icons.folder),
  settings('Settings', Icons.settings),
  troubleshooting('Troubleshooting', Icons.help_outline);

  final String label;
  final IconData icon;

  const HelpCategory(this.label, this.icon);
}

/// Help article/topic
class HelpArticle {
  final String id;
  final String title;
  final String content;
  final HelpCategory category;
  final List<String> keywords;
  final String? videoUrl;

  const HelpArticle({
    required this.id,
    required this.title,
    required this.content,
    required this.category,
    this.keywords = const [],
    this.videoUrl,
  });
}

/// FAQ item
class FAQItem {
  final String question;
  final String answer;
  final HelpCategory category;

  const FAQItem({
    required this.question,
    required this.answer,
    required this.category,
  });
}

/// Service for tutorials, help, and onboarding
class TutorialService {
  static final TutorialService _instance = TutorialService._internal();
  factory TutorialService() => _instance;
  TutorialService._internal();

  static const String _onboardingCompleteKey = 'onboarding_complete';
  static const String _viewedTutorialsKey = 'viewed_tutorials';
  static const String _viewedArticlesKey = 'viewed_articles';

  // ========== ONBOARDING TUTORIAL ==========
  static const List<TutorialStep> onboardingSteps = [
    TutorialStep(
      id: 'welcome',
      title: 'Welcome to AncientVision',
      description: 'Your complete archaeological field companion. Record findings, create 3D models, and manage your excavation data.',
      icon: Icons.waving_hand,
    ),
    TutorialStep(
      id: 'findings',
      title: 'Record Findings',
      description: 'Document artifacts with photos, location, and detailed metadata. All data is saved locally and synced to the cloud.',
      icon: Icons.add_a_photo,
      targetKey: 'findings_tab',
    ),
    TutorialStep(
      id: 'classification',
      title: 'Artifact Classification',
      description: 'Use our built-in archaeological database to classify artifacts by type, material, period, and condition.',
      icon: Icons.category,
    ),
    TutorialStep(
      id: 'export',
      title: 'Export & Share',
      description: 'Export your data as PDF reports, CSV, JSON, or GeoJSON. Share 3D models in OBJ or PLY format.',
      icon: Icons.share,
    ),
    TutorialStep(
      id: 'offline',
      title: 'Works Offline',
      description: 'All features work without internet. Data syncs automatically when you\'re back online.',
      icon: Icons.wifi_off,
    ),
  ];

  // ========== FEATURE TUTORIALS ==========
  static const Map<String, List<TutorialStep>> featureTutorials = {
    'findings': [
      TutorialStep(
        id: 'add_finding',
        title: 'Add a Finding',
        description: 'Tap the + button to create a new finding. You can add photos, location, and detailed information.',
        icon: Icons.add_circle,
      ),
      TutorialStep(
        id: 'classify',
        title: 'Classify Your Find',
        description: 'Select the artifact type, material, period, and condition from our archaeological database.',
        icon: Icons.category,
      ),
      TutorialStep(
        id: 'measure',
        title: 'Add Measurements',
        description: 'Record dimensions using our measurement tool. Choose your preferred units.',
        icon: Icons.straighten,
      ),
      TutorialStep(
        id: 'context',
        title: 'Add Context',
        description: 'Link findings to stratigraphic contexts for proper archaeological documentation.',
        icon: Icons.layers,
      ),
    ],
    'context_sheet': [
      TutorialStep(
        id: 'context_type',
        title: 'Choose Context Type',
        description: 'Select whether this is a deposit, cut, fill, structure, or surface.',
        icon: Icons.layers,
      ),
      TutorialStep(
        id: 'soil_desc',
        title: 'Describe the Soil',
        description: 'Record soil type, Munsell color, compaction, and inclusions.',
        icon: Icons.terrain,
      ),
      TutorialStep(
        id: 'relationships',
        title: 'Stratigraphic Relationships',
        description: 'Record what this context is above, below, cuts, or is cut by.',
        icon: Icons.account_tree,
      ),
      TutorialStep(
        id: 'samples',
        title: 'Record Samples',
        description: 'Note if soil, flotation, or carbon samples were taken.',
        icon: Icons.science,
      ),
    ],
    'sensors': [
      TutorialStep(
        id: 'sensor_setup',
        title: 'Setting Up Sensors',
        description: 'Connect M5 StickC Plus 2 sensors to monitor excavation environmental conditions in real-time.',
        icon: Icons.sensors,
      ),
      TutorialStep(
        id: 'sensor_connect',
        title: 'Connect via Bluetooth',
        description: 'Enable Bluetooth on your phone, then scan for nearby sensors. Select your device to connect.',
        icon: Icons.bluetooth,
      ),
      TutorialStep(
        id: 'sensor_data',
        title: 'View Real-Time Data',
        description: 'Monitor temperature, humidity, light, and pressure. Data updates automatically every few seconds.',
        icon: Icons.show_chart,
      ),
      TutorialStep(
        id: 'sensor_history',
        title: 'Historical Trends',
        description: 'View graphs of environmental data over time. Useful for tracking site conditions during excavation.',
        icon: Icons.history,
      ),
    ],
    'export': [
      TutorialStep(
        id: 'export_format',
        title: 'Choose Export Format',
        description: 'Select PDF for reports, CSV for spreadsheets, JSON for backup, or GeoJSON/KML for GIS.',
        icon: Icons.file_present,
      ),
      TutorialStep(
        id: 'export_select',
        title: 'Select Data',
        description: 'Choose which findings, contexts, or journal entries to include in your export.',
        icon: Icons.checklist,
      ),
      TutorialStep(
        id: 'export_share',
        title: 'Share or Save',
        description: 'Save to device, share via email, or upload to cloud storage. Your export is ready for use.',
        icon: Icons.share,
      ),
    ],
    'field_journal': [
      TutorialStep(
        id: 'journal_entry',
        title: 'Create an Entry',
        description: 'Tap the + button to create a new journal entry. Record your daily observations and thoughts.',
        icon: Icons.edit_note,
      ),
      TutorialStep(
        id: 'journal_tags',
        title: 'Add Tags',
        description: 'Use tags to categorize entries. This makes searching and filtering much easier later.',
        icon: Icons.label,
      ),
      TutorialStep(
        id: 'journal_search',
        title: 'Search Entries',
        description: 'Use the search bar to find entries by date, content, or tags. Filter by time period as needed.',
        icon: Icons.search,
      ),
    ],
    'coins': [
      TutorialStep(
        id: 'coin_intro',
        title: 'Documenting Coins',
        description: 'Ancient coins are valuable historical artifacts. Record them with precision using our specialized coin fields.',
        icon: Icons.paid,
      ),
      TutorialStep(
        id: 'coin_type',
        title: 'Select Coin Type',
        description: 'Choose "Coins & Currency" as the artifact type. This unlocks specialized numismatic fields.',
        icon: Icons.category,
      ),
      TutorialStep(
        id: 'coin_denomination',
        title: 'Record Denomination',
        description: 'Enter the coin denomination: Drachma, Obol, Denarius, As, Sestertius, Solidus, etc.',
        icon: Icons.monetization_on,
      ),
      TutorialStep(
        id: 'coin_mint',
        title: 'Mint & Authority',
        description: 'Record where the coin was minted and who issued it (ruler, city, or authority).',
        icon: Icons.account_balance,
      ),
      TutorialStep(
        id: 'coin_legends',
        title: 'Record Inscriptions',
        description: 'Document the obverse (front) and reverse (back) legends. Transcribe any visible text.',
        icon: Icons.text_fields,
      ),
      TutorialStep(
        id: 'coin_die_axis',
        title: 'Die Axis',
        description: 'Record the die axis as a clock position (1-12). Hold the coin with obverse up, flip it - where does the reverse point?',
        icon: Icons.access_time,
      ),
    ],
    'fragments': [
      TutorialStep(
        id: 'fragment_intro',
        title: 'Recording Pottery Fragments',
        description: 'Pottery sherds are the most common archaeological finds. Proper documentation reveals vessel types and cultural patterns.',
        icon: Icons.broken_image,
      ),
      TutorialStep(
        id: 'fragment_type',
        title: 'Select Fragment Type',
        description: 'Choose "Pottery Fragments" as the artifact type. This unlocks specialized ceramic analysis fields.',
        icon: Icons.category,
      ),
      TutorialStep(
        id: 'fragment_part',
        title: 'Identify Vessel Part',
        description: 'Determine which part of the vessel the sherd came from: rim, body, base, handle, spout, or foot.',
        icon: Icons.pie_chart,
      ),
      TutorialStep(
        id: 'fragment_ware',
        title: 'Classify Ware Type',
        description: 'Identify the ware: coarse ware, fine ware, cooking ware, storage ware, or tableware.',
        icon: Icons.layers,
      ),
      TutorialStep(
        id: 'fragment_decoration',
        title: 'Note Decoration',
        description: 'Record any decoration: plain, painted, incised, stamped, glazed, burnished, or slipped.',
        icon: Icons.brush,
      ),
      TutorialStep(
        id: 'fragment_measurements',
        title: 'Take Measurements',
        description: 'Measure wall thickness. For rim sherds, estimate the original rim diameter using a diameter chart.',
        icon: Icons.straighten,
      ),
    ],
  };

  // ========== HELP ARTICLES ==========
  static const List<HelpArticle> helpArticles = [
    HelpArticle(
      id: 'getting_started',
      title: 'Getting Started with AncientVision',
      content: '''
AncientVision is a comprehensive archaeological field app designed to help you document, classify, and analyze archaeological findings.

**Key Features:**
- Record findings with photos and GPS location
- Classify artifacts using our archaeological database
- Connect environmental sensors for site monitoring
- Generate professional PDF reports
- Export data in multiple formats
- Works offline with automatic sync

**Quick Start:**
1. Create an account or sign in
2. Start recording findings using the + button
3. Use the camera to capture photos
4. Add classification and measurements
5. Export or share your data
      ''',
      category: HelpCategory.gettingStarted,
      keywords: ['start', 'begin', 'first', 'new', 'account'],
    ),
    HelpArticle(
      id: 'sensor_monitoring',
      title: 'Environmental Sensor Monitoring',
      content: '''
AncientVision supports M5 StickC Plus 2 sensors for environmental monitoring at excavation sites.

**Supported Measurements:**
- Temperature (°C/°F)
- Humidity (%)
- Light levels (lux)
- Atmospheric pressure (hPa)

**Connecting a Sensor:**
1. Go to Home tab and scroll to "Environmental Sensors"
2. Tap "Scan for Devices"
3. Select your M5 StickC Plus 2 from the list
4. Wait for connection confirmation

**Data Recording:**
- Sensor data is recorded automatically
- Each sensor is linked to its excavation site
- Historical data is stored for analysis
- View trends in the sensor graph

**Why Monitor Environment?**
- Track excavation conditions over time
- Document preservation environment
- Correlate finds with environmental factors
- Professional site documentation
      ''',
      category: HelpCategory.fieldwork,
      keywords: ['sensor', 'm5', 'temperature', 'humidity', 'environmental', 'monitoring'],
    ),
    HelpArticle(
      id: 'field_journal',
      title: 'Using the Field Journal',
      content: '''
The Field Journal is your digital excavation diary for recording daily observations, thoughts, and notes.

**Creating Entries:**
1. Go to Tools > Field Work > Field Journal
2. Tap the + button to add a new entry
3. Write your observations
4. Add tags for easy searching
5. Save your entry

**Best Practices:**
- Record entries at the start and end of each day
- Note weather conditions and site access
- Document any unusual findings or events
- Record interpretations and hypotheses
- Note team members present

**Entry Types:**
- Daily summaries
- Feature descriptions
- Photo documentation notes
- Visitor logs
- Problem/solution records

**Searching:**
Use the search bar to find entries by date, content, or tags.
      ''',
      category: HelpCategory.fieldwork,
      keywords: ['journal', 'diary', 'notes', 'field', 'daily', 'log'],
    ),
    HelpArticle(
      id: 'quick_capture',
      title: 'Quick Capture for Rapid Documentation',
      content: '''
Quick Capture lets you rapidly photograph and document finds without filling out full forms.

**When to Use:**
- Initial discovery of artifacts
- Survey documentation
- Rapid site photography
- Bulk photography sessions

**Features:**
- Fast camera access
- Auto GPS tagging
- Auto timestamp
- Optional voice notes
- Batch processing later

**Tips:**
- Use grid overlay for consistent framing
- Tap to focus on the artifact
- Include scale bar in frame
- Capture from multiple angles
- Add brief voice description
      ''',
      category: HelpCategory.findings,
      keywords: ['quick', 'capture', 'photo', 'fast', 'camera', 'rapid'],
    ),
    HelpArticle(
      id: 'context_sheets',
      title: 'Recording Stratigraphic Contexts',
      content: '''
Context sheets are essential for proper archaeological documentation.

**Context Types:**
- **Deposit**: Natural or cultural accumulation
- **Cut**: Negative feature (pit, ditch, etc.)
- **Fill**: Material filling a cut
- **Structure**: Built feature (wall, floor)
- **Surface**: Activity or occupation surface

**Key Information:**
- Context number (unique identifier)
- Soil description (type, color, compaction)
- Stratigraphic relationships
- Dimensions and elevations
- Associated finds

**Munsell Colors:**
Use the built-in Munsell color chart to standardize soil color descriptions.

**Relationships:**
Record what each context is above, below, cuts, or is cut by to build the Harris Matrix.
      ''',
      category: HelpCategory.fieldwork,
      keywords: ['context', 'stratigraphy', 'soil', 'layer', 'harris'],
    ),
    HelpArticle(
      id: 'offline_mode',
      title: 'Working Offline',
      content: '''
AncientVision is designed to work fully offline in the field.

**What Works Offline:**
- Recording new findings
- Taking photos
- Classification and measurements
- Field journal entries
- Context sheets
- On-device 3D processing

**What Requires Internet:**
- Cloud 3D processing
- Syncing to Firebase
- Sharing exports

**Auto-Sync:**
When you reconnect to the internet, all your data syncs automatically. You can also trigger manual sync from the home screen.

**Data Safety:**
All data is saved locally first. Nothing is lost if you lose connection during fieldwork.
      ''',
      category: HelpCategory.dataManagement,
      keywords: ['offline', 'internet', 'sync', 'field', 'connection'],
    ),
    HelpArticle(
      id: 'export_options',
      title: 'Exporting Your Data',
      content: '''
Export your data in multiple formats for different purposes.

**Available Formats:**
- **PDF**: Professional reports with images
- **CSV**: Spreadsheet-compatible data
- **JSON**: Full data export for backup
- **GeoJSON**: For GIS applications
- **KML**: For Google Earth
- **OBJ/PLY**: 3D model formats

**Report Types:**
- Finding reports (individual artifacts)
- Site reports (complete excavation)
- Daily reports (day-by-day summary)
- Context sheets (stratigraphic forms)

**Sharing:**
Use the share button to send exports via email, cloud storage, or other apps.
      ''',
      category: HelpCategory.dataManagement,
      keywords: ['export', 'pdf', 'csv', 'report', 'share', 'backup'],
    ),
  ];

  // ========== FAQs ==========
  static const List<FAQItem> faqs = [
    // --- Safety / Vibration FAQs ---
    FAQItem(
      question: 'What does PPV mean?',
      answer: 'PPV stands for Peak Particle Velocity, measured in mm/s. It quantifies the maximum ground vibration speed at the sensor location. '
          'DIN 4150-3 sets a limit of 0.3 mm/s for heritage and masonry buildings. Values above this indicate elevated risk to sensitive structures.',
      category: HelpCategory.fieldwork,
    ),
    FAQItem(
      question: 'What is the anomaly score?',
      answer: 'The anomaly score is the reconstruction error produced by the on-device autoencoder ML model. '
              'A score above 1.0 is considered unusual and warrants monitoring. '
              'A score above 2.5 indicates a probable anomaly that may precede a soil failure event.',
      category: HelpCategory.fieldwork,
    ),
    FAQItem(
      question: 'Why is the device showing CAUTION?',
      answer: 'CAUTION is triggered when PPV is between 0.1 and 0.3 mm/s, or when the anomaly score is between 1.0 and 2.5. '
              'This means vibration levels are elevated but not yet critical. '
              'Continue monitoring and be prepared to evacuate if the level escalates to CRITICAL.',
      category: HelpCategory.fieldwork,
    ),
    FAQItem(
      question: 'How do I calibrate the sensor?',
      answer: 'Go to Settings → Calibrate. Place the M5StickC device on a flat, stable surface away from vibration sources. '
              'Keep it completely still for 30 seconds while calibration runs. '
              'The app establishes a noise baseline, which improves anomaly detection accuracy.',
      category: HelpCategory.fieldwork,
    ),
    FAQItem(
      question: 'What are soil creep and crack propagation patterns?',
      answer: 'These are pre-failure stress signatures detected by the ML precursor classifier:\n\n'
              '• Soil creep: slow, continuous micro-displacement of soil grains under gravity. Indicates gradual slope instability.\n'
              '• Crack propagation: rapid micro-fracturing events in the soil or rock mass. These short bursts of high-frequency energy can escalate to collapse.\n\n'
              'Both patterns are precursor indicators — they appear before a visible failure occurs.',
      category: HelpCategory.fieldwork,
    ),
    FAQItem(
      question: 'What action should I take on a CRITICAL alert?',
      answer: 'Immediately evacuate all personnel from the excavation area. '
              'Do not re-enter until the site supervisor or a geotechnical engineer has assessed the hazard. '
              'Note the PPV value, anomaly score, and time of the alert for the incident report.',
      category: HelpCategory.fieldwork,
    ),
    FAQItem(
      question: 'When should I evacuate?',
      answer: 'Evacuate immediately when the app shows a RED (CRITICAL) alert, which means PPV has exceeded 1.0 mm/s '
              'or the ML precursor classifier has detected imminent-failure signatures for 15 or more consecutive seconds.\n\n'
              'Also evacuate if you observe any of these physical signs regardless of app status:\n'
              '• Visible soil cracking near the excavation face\n'
              '• Audible cracking or settling sounds\n'
              '• Small debris or soil falling from exposed sections\n'
              '• Water seepage or sudden change in soil colour\n\n'
              'Never wait for a second alert. Alert the site supervisor and do not re-enter until a '
              'geotechnical professional confirms the area is safe.',
      category: HelpCategory.fieldwork,
    ),
    FAQItem(
      question: 'How long does calibration take?',
      answer: 'Calibration takes 30 seconds. During that time the device must remain completely motionless on a '
              'flat, stable surface away from vibration sources such as machinery, traffic, or foot traffic.\n\n'
              'The app will show a progress bar and confirm when calibration is complete. '
              'If the device moves during calibration, tap Recalibrate to restart.\n\n'
              'Tip: calibrate at the start of each monitoring session and after moving the device to a new location.',
      category: HelpCategory.fieldwork,
    ),
    // --- General FAQs ---
    FAQItem(
      question: 'Does the app work without internet?',
      answer: 'Yes! All core features work offline. Data syncs automatically when you reconnect. Cloud 3D processing is the only feature that requires internet.',
      category: HelpCategory.dataManagement,
    ),
    FAQItem(
      question: 'How do I backup my data?',
      answer: 'Go to Settings > Backup to create a full backup. You can also enable automatic backups. Backups are saved as ZIP files that can be restored later.',
      category: HelpCategory.dataManagement,
    ),
    FAQItem(
      question: 'How do I classify an unknown artifact?',
      answer: 'Select "Unknown/Unidentified" as the type. You can add notes and update the classification later when you have more information.',
      category: HelpCategory.findings,
    ),
    FAQItem(
      question: 'Can multiple team members use the app?',
      answer: 'Yes! Each team member can have their own account. Data is associated with the user who recorded it. Site directors can see all team data.',
      category: HelpCategory.gettingStarted,
    ),
    FAQItem(
      question: 'How accurate is the GPS location?',
      answer: 'GPS accuracy depends on your device and conditions. Typical accuracy is 3-5 meters outdoors. For precise positioning, consider using an external GPS receiver.',
      category: HelpCategory.fieldwork,
    ),
    FAQItem(
      question: 'How do I connect an M5 StickC Plus 2 sensor?',
      answer: 'Make sure Bluetooth is enabled on your phone. Go to the Home tab, scroll to Environmental Sensors, and tap "Scan for Devices". Select your sensor from the list to connect.',
      category: HelpCategory.fieldwork,
    ),
    FAQItem(
      question: 'Why is my sensor not showing up?',
      answer: 'Ensure the M5 StickC Plus 2 is powered on and running the AncientVision firmware. Make sure Bluetooth is enabled and you are within range (about 10 meters). Try restarting the sensor.',
      category: HelpCategory.troubleshooting,
    ),
    FAQItem(
      question: 'How do I export my data for GIS software?',
      answer: 'Go to Tools > Export and select GeoJSON or KML format. GeoJSON works with QGIS and ArcGIS. KML files can be opened in Google Earth for visualization.',
      category: HelpCategory.dataManagement,
    ),
    FAQItem(
      question: 'Can I use biometric authentication?',
      answer: 'Yes! Go to Settings > Privacy & Security and enable "Require Authentication". You can use fingerprint or face recognition depending on your device capabilities.',
      category: HelpCategory.settings,
    ),
    FAQItem(
      question: 'How do I change the measurement units?',
      answer: 'Go to Settings > Regional and select your preferred measurement system (Metric or Imperial). All measurements throughout the app will update accordingly.',
      category: HelpCategory.settings,
    ),
    FAQItem(
      question: 'What happens if I run out of storage?',
      answer: 'Go to Settings > Storage & Cache to see what is using space. You can clear cached images and temporary files. Consider enabling image compression to save space.',
      category: HelpCategory.troubleshooting,
    ),
    FAQItem(
      question: 'How do I add a scale bar to photos?',
      answer: 'Place a physical scale bar (ruler or scale stick) in frame when photographing. The app does not add digital scale bars, as physical scales are more accurate for archaeological documentation.',
      category: HelpCategory.findings,
    ),
  ];

  // ========== SERVICE METHODS ==========

  /// Check if onboarding is complete
  Future<bool> isOnboardingComplete() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_onboardingCompleteKey) ?? false;
  }

  /// Mark onboarding as complete
  Future<void> completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingCompleteKey, true);
  }

  /// Reset onboarding (show again)
  Future<void> resetOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_onboardingCompleteKey, false);
  }

  /// Check if a tutorial has been viewed
  Future<bool> isTutorialViewed(String tutorialId) async {
    final prefs = await SharedPreferences.getInstance();
    final viewed = prefs.getStringList(_viewedTutorialsKey) ?? [];
    return viewed.contains(tutorialId);
  }

  /// Mark a tutorial as viewed
  Future<void> markTutorialViewed(String tutorialId) async {
    final prefs = await SharedPreferences.getInstance();
    final viewed = prefs.getStringList(_viewedTutorialsKey) ?? [];
    if (!viewed.contains(tutorialId)) {
      viewed.add(tutorialId);
      await prefs.setStringList(_viewedTutorialsKey, viewed);
    }
  }

  /// Get unviewed feature tutorials
  Future<List<String>> getUnviewedTutorials() async {
    final prefs = await SharedPreferences.getInstance();
    final viewed = prefs.getStringList(_viewedTutorialsKey) ?? [];
    return featureTutorials.keys.where((t) => !viewed.contains(t)).toList();
  }

  /// Mark an article as read
  Future<void> markArticleRead(String articleId) async {
    final prefs = await SharedPreferences.getInstance();
    final read = prefs.getStringList(_viewedArticlesKey) ?? [];
    if (!read.contains(articleId)) {
      read.add(articleId);
      await prefs.setStringList(_viewedArticlesKey, read);
    }
  }

  /// Search help articles
  List<HelpArticle> searchArticles(String query) {
    final lowerQuery = query.toLowerCase();
    return helpArticles.where((article) {
      return article.title.toLowerCase().contains(lowerQuery) ||
          article.content.toLowerCase().contains(lowerQuery) ||
          article.keywords.any((k) => k.toLowerCase().contains(lowerQuery));
    }).toList();
  }

  /// Search FAQs
  List<FAQItem> searchFAQs(String query) {
    final lowerQuery = query.toLowerCase();
    return faqs.where((faq) {
      return faq.question.toLowerCase().contains(lowerQuery) ||
          faq.answer.toLowerCase().contains(lowerQuery);
    }).toList();
  }

  /// Get articles by category
  List<HelpArticle> getArticlesByCategory(HelpCategory category) {
    return helpArticles.where((a) => a.category == category).toList();
  }

  /// Get FAQs by category
  List<FAQItem> getFAQsByCategory(HelpCategory category) {
    return faqs.where((f) => f.category == category).toList();
  }

  /// Get tutorial steps for a feature
  List<TutorialStep>? getFeatureTutorial(String feature) {
    return featureTutorials[feature];
  }

  /// Reset all tutorial progress
  Future<void> resetAllProgress() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_onboardingCompleteKey);
    await prefs.remove(_viewedTutorialsKey);
    await prefs.remove(_viewedArticlesKey);
  }
}

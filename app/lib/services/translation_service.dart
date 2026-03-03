/// Simple two-language translation service (English / Greek).
///
/// Usage:
///   final t = TranslationService();
///   t.toggleLanguage();
///   Text(t.tr('safe_to_work'))
class TranslationService {
  static final TranslationService _instance = TranslationService._internal();
  factory TranslationService() => _instance;
  TranslationService._internal();

  bool _isGreek = false;
  bool get isGreek => _isGreek;
  String get languageCode => _isGreek ? 'el' : 'en';

  void toggleLanguage() => _isGreek = !_isGreek;
  void setGreek(bool value) => _isGreek = value;

  String tr(String key) {
    final map = _isGreek ? _el : _en;
    return map[key] ?? _en[key] ?? key;
  }

  /// Translate with parameter substitution: {0}, {1}, etc.
  String trArgs(String key, List<String> args) {
    var text = tr(key);
    for (int i = 0; i < args.length; i++) {
      text = text.replaceAll('{$i}', args[i]);
    }
    return text;
  }

  static const Map<String, String> _en = {
    // Main title
    'trench_safety': 'Trench Safety',

    // Connection
    'connected_to': 'Connected to M5StickC Plus 2',
    'scanning': 'Scanning for devices...',
    'sensor_not_connected': 'Sensor not connected',
    'sensor_active': 'Sensor active - last update: {0}',
    'scan': 'Scan',
    'reconnect': 'Reconnect',
    'disconnect': 'Disconnect',
    'partial_data': 'Partial data received — move closer to sensor',
    'muted': 'Muted',
    'sound': 'Sound',

    // Safety status
    'safe_to_work': 'Safe to Work',
    'safe_description': 'Vibration levels are within safe limits for archaeological structures.',
    'use_caution': 'Use Caution',
    'caution_description': 'Elevated vibration detected. Monitor conditions and reduce heavy equipment use if possible.',
    'stop_work': 'Stop Work - High Vibration',
    'stop_description': 'Vibration exceeds safe limits for heritage structures. Stop all nearby machinery and assess the site.',

    // PPV status
    'exceeds_limit': '{0} mm/s - EXCEEDS safe limit',
    'percent_of_limit': '{0} mm/s - {1}% of limit',
    'within_limits': '{0} mm/s - within safe limits',
    'no_data': 'No data yet',
    'safe': 'Safe',
    'perceptible': 'Perceptible',
    'heritage_limit': 'Heritage limit',
    'din_exceeded': 'DIN 4150-3 EXCEEDED',
    'critical_evacuate': 'CRITICAL - EVACUATE',

    // Alerts
    'unusual_vibration': 'Unusual vibration pattern detected',
    'vibration_increasing': 'Vibration increasing - may exceed limits in ~{0} minutes',
    'warning_detected': 'WARNING: {0} detected ({1}% confidence)',

    // Precursor patterns
    'soil_creep': 'Soil movement detected',
    'crack_propagation': 'Crack propagation detected',
    'imminent_failure': 'IMMINENT FAILURE WARNING',
    'precursor_label': 'Precursor: {0} ({1}% confidence)',

    // Calibration
    'learn_site': 'Learn This Site',
    'stop_learning': 'Stop Learning',
    'calibration_title': 'Learn This Site',
    'calibration_description': 'Place the sensor on stable ground and keep the area quiet for at least 5 minutes. This teaches the system what "normal" feels like here.',
    'site_name': 'Site Name',
    'cancel': 'Cancel',
    'start': 'Start',
    'not_enough_data': 'Not enough data yet. Keep recording for at least 5 minutes.',
    'site_learned': 'Site "{0}" learned successfully!',
    'high_variance_warning': ' Ground was shaking during learning — consider re-doing when quieter.',
    'learning_label': 'Learning: {0}',
    'calibration_ready': 'Ready! Tap the stop button to finish.',
    'calibration_progress': '{0} / 600 readings — keep area quiet',

    // Tabs
    'tab_status': 'STATUS',
    'tab_analysis': 'ANALYSIS',
    'tab_standards': 'STANDARDS',

    // Mode toggle
    'simple': 'Simple',
    'detail': 'Detail',

    // Moisture
    'soil_moisture': 'Soil Moisture',
    'too_dry': 'Too Dry',
    'too_wet': 'Too Wet!',
    'safe_range': 'Safe range',

    // Metrics
    'detailed_metrics': 'Detailed Metrics',
    'ppv_din': 'PPV (DIN 4150-3)',
    'test_alert': 'Test Alert',

    // Failure prediction
    'failure_prediction': 'Failure: ~{0}m {1}s',

    // Battery
    'battery_low': 'Sensor battery low ({0}%) — plug in a power bank!',
    'battery_critical': 'Sensor battery almost dead! Plug in now or monitoring will stop.',
  };

  static const Map<String, String> _el = {
    // Main title
    'trench_safety': 'Ασφάλεια Σκάμματος',

    // Connection
    'connected_to': 'Συνδεδεμένο με M5StickC Plus 2',
    'scanning': 'Αναζήτηση συσκευών...',
    'sensor_not_connected': 'Ο αισθητήρας δεν είναι συνδεδεμένος',
    'sensor_active': 'Αισθητήρας ενεργός - τελευταία ενημέρωση: {0}',
    'scan': 'Σάρωση',
    'reconnect': 'Επανασύνδεση',
    'disconnect': 'Αποσύνδεση',
    'partial_data': 'Ελλιπή δεδομένα — πλησιάστε τον αισθητήρα',
    'muted': 'Σίγαση',
    'sound': 'Ήχος',

    // Safety status
    'safe_to_work': 'Ασφαλές για Εργασία',
    'safe_description': 'Τα επίπεδα δόνησης είναι εντός ασφαλών ορίων για αρχαιολογικές κατασκευές.',
    'use_caution': 'Προσοχή',
    'caution_description': 'Ανιχνεύθηκε αυξημένη δόνηση. Παρακολουθήστε τις συνθήκες και μειώστε τη χρήση βαρέων μηχανημάτων.',
    'stop_work': 'Σταματήστε - Υψηλή Δόνηση',
    'stop_description': 'Η δόνηση υπερβαίνει τα ασφαλή όρια. Σταματήστε όλα τα μηχανήματα και απομακρυνθείτε.',

    // PPV status
    'exceeds_limit': '{0} mm/s - ΥΠΕΡΒΑΙΝΕΙ το ασφαλές όριο',
    'percent_of_limit': '{0} mm/s - {1}% του ορίου',
    'within_limits': '{0} mm/s - εντός ασφαλών ορίων',
    'no_data': 'Δεν υπάρχουν δεδομένα',
    'safe': 'Ασφαλές',
    'perceptible': 'Αισθητό',
    'heritage_limit': 'Όριο μνημείων',
    'din_exceeded': 'ΥΠΕΡΒΑΣΗ DIN 4150-3',
    'critical_evacuate': 'ΚΡΙΣΙΜΟ - ΕΚΚΕΝΩΣΤΕ',

    // Alerts
    'unusual_vibration': 'Ανιχνεύθηκε ασυνήθιστη δόνηση',
    'vibration_increasing': 'Η δόνηση αυξάνεται - πιθανή υπέρβαση ορίων σε ~{0} λεπτά',
    'warning_detected': 'ΠΡΟΕΙΔΟΠΟΙΗΣΗ: Ανιχνεύθηκε {0} ({1}% βεβαιότητα)',

    // Precursor patterns
    'soil_creep': 'Ανιχνεύθηκε μετακίνηση εδάφους',
    'crack_propagation': 'Ανιχνεύθηκε διάδοση ρωγμών',
    'imminent_failure': 'ΠΡΟΕΙΔΟΠΟΙΗΣΗ ΕΠΙΚΕΙΜΕΝΗΣ ΚΑΤΑΡΡΕΥΣΗΣ',
    'precursor_label': 'Πρόδρομο: {0} ({1}% βεβαιότητα)',

    // Calibration
    'learn_site': 'Μάθε τον Χώρο',
    'stop_learning': 'Σταμάτα τη Μάθηση',
    'calibration_title': 'Μάθε τον Χώρο',
    'calibration_description': 'Τοποθετήστε τον αισθητήρα σε σταθερό έδαφος και κρατήστε την περιοχή ήσυχη για τουλάχιστον 5 λεπτά. Έτσι το σύστημα μαθαίνει τι είναι «κανονικό» εδώ.',
    'site_name': 'Όνομα Χώρου',
    'cancel': 'Ακύρωση',
    'start': 'Έναρξη',
    'not_enough_data': 'Δεν υπάρχουν αρκετά δεδομένα. Συνεχίστε για τουλάχιστον 5 λεπτά.',
    'site_learned': 'Ο χώρος "{0}" καταγράφηκε επιτυχώς!',
    'high_variance_warning': ' Το έδαφος δονούνταν κατά τη μάθηση — δοκιμάστε ξανά σε πιο ήσυχη στιγμή.',
    'learning_label': 'Μαθαίνω: {0}',
    'calibration_ready': 'Έτοιμο! Πατήστε το κουμπί στοπ για ολοκλήρωση.',
    'calibration_progress': '{0} / 600 μετρήσεις — κρατήστε ησυχία',

    // Tabs
    'tab_status': 'ΚΑΤΑΣΤΑΣΗ',
    'tab_analysis': 'ΑΝΑΛΥΣΗ',
    'tab_standards': 'ΠΡΟΤΥΠΑ',

    // Mode toggle
    'simple': 'Απλό',
    'detail': 'Λεπτομ.',

    // Moisture
    'soil_moisture': 'Υγρασία Εδάφους',
    'too_dry': 'Πολύ Ξηρό',
    'too_wet': 'Πολύ Υγρό!',
    'safe_range': 'Ασφαλές εύρος',

    // Metrics
    'detailed_metrics': 'Λεπτομερείς Μετρήσεις',
    'ppv_din': 'PPV (DIN 4150-3)',
    'test_alert': 'Δοκιμαστικός Συναγερμός',

    // Failure prediction
    'failure_prediction': 'Κατάρρευση: ~{0}λ {1}δ',

    // Battery
    'battery_low': 'Χαμηλή μπαταρία αισθητήρα ({0}%) — συνδέστε power bank!',
    'battery_critical': 'Η μπαταρία του αισθητήρα τελειώνει! Συνδέστε τώρα ή η παρακολούθηση θα σταματήσει.',
  };
}

import 'package:flutter/material.dart';

/// Entry types for field journal
enum JournalEntryType {
  daily('Daily Log', Icons.today, Color(0xFF4682B4)),
  discovery('Discovery', Icons.star, Color(0xFFFFD700)),
  observation('Observation', Icons.visibility, Color(0xFF32CD32)),
  problem('Problem/Issue', Icons.warning, Color(0xFFFF8C00)),
  weather('Weather Note', Icons.wb_sunny, Color(0xFF87CEEB)),
  team('Team Note', Icons.group, Color(0xFF9370DB)),
  method('Method Note', Icons.science, Color(0xFF00CED1)),
  photo('Photo Note', Icons.camera_alt, Color(0xFFFF69B4)),
  voice('Voice Note', Icons.mic, Color(0xFFDC143C)),
  other('Other', Icons.note, Color(0xFF808080));

  final String label;
  final IconData icon;
  final Color color;

  const JournalEntryType(this.label, this.icon, this.color);
}

/// Mood/condition during work
enum WorkCondition {
  excellent('Excellent', Icons.sentiment_very_satisfied, Color(0xFF228B22)),
  good('Good', Icons.sentiment_satisfied, Color(0xFF32CD32)),
  normal('Normal', Icons.sentiment_neutral, Color(0xFFFFD700)),
  challenging('Challenging', Icons.sentiment_dissatisfied, Color(0xFFFF8C00)),
  difficult('Difficult', Icons.sentiment_very_dissatisfied, Color(0xFFDC143C));

  final String label;
  final IconData icon;
  final Color color;

  const WorkCondition(this.label, this.icon, this.color);
}

/// A single field journal entry
class JournalEntry {
  final String id;
  final String? siteId;
  final JournalEntryType type;
  final String title;
  final String content;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String? authorId;
  final String? authorName;
  final WorkCondition? workCondition;
  final List<String>? tags;
  final List<String>? imageUrls;
  final String? voiceNoteUrl;
  final double? voiceDuration; // seconds
  final String? transcription; // voice-to-text
  final String? weather;
  final double? temperature;
  final List<String>? linkedFindingIds;
  final Map<String, dynamic>? metadata;
  final bool isPinned;
  final bool isPrivate;

  JournalEntry({
    required this.id,
    this.siteId,
    required this.type,
    required this.title,
    required this.content,
    DateTime? createdAt,
    this.updatedAt,
    this.authorId,
    this.authorName,
    this.workCondition,
    this.tags,
    this.imageUrls,
    this.voiceNoteUrl,
    this.voiceDuration,
    this.transcription,
    this.weather,
    this.temperature,
    this.linkedFindingIds,
    this.metadata,
    this.isPinned = false,
    this.isPrivate = false,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Check if entry has voice note
  bool get hasVoiceNote => voiceNoteUrl != null && voiceNoteUrl!.isNotEmpty;

  /// Check if entry has images
  bool get hasImages => imageUrls != null && imageUrls!.isNotEmpty;

  /// Get formatted duration string
  String? get voiceDurationString {
    if (voiceDuration == null) return null;
    final minutes = (voiceDuration! / 60).floor();
    final seconds = (voiceDuration! % 60).floor();
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  /// Get day of week
  String get dayOfWeek {
    const days = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
    return days[createdAt.weekday - 1];
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'siteId': siteId,
        'type': type.name,
        'title': title,
        'content': content,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt?.toIso8601String(),
        'authorId': authorId,
        'authorName': authorName,
        'workCondition': workCondition?.name,
        'tags': tags,
        'imageUrls': imageUrls,
        'voiceNoteUrl': voiceNoteUrl,
        'voiceDuration': voiceDuration,
        'transcription': transcription,
        'weather': weather,
        'temperature': temperature,
        'linkedFindingIds': linkedFindingIds,
        'metadata': metadata,
        'isPinned': isPinned,
        'isPrivate': isPrivate,
      };

  factory JournalEntry.fromJson(Map<String, dynamic> json) => JournalEntry(
        id: json['id'],
        siteId: json['siteId'],
        type: JournalEntryType.values.firstWhere(
          (t) => t.name == json['type'],
          orElse: () => JournalEntryType.other,
        ),
        title: json['title'],
        content: json['content'],
        createdAt: DateTime.parse(json['createdAt']),
        updatedAt: json['updatedAt'] != null
            ? DateTime.parse(json['updatedAt'])
            : null,
        authorId: json['authorId'],
        authorName: json['authorName'],
        workCondition: json['workCondition'] != null
            ? WorkCondition.values.firstWhere(
                (c) => c.name == json['workCondition'],
                orElse: () => WorkCondition.normal,
              )
            : null,
        tags: json['tags'] != null ? List<String>.from(json['tags']) : null,
        imageUrls: json['imageUrls'] != null
            ? List<String>.from(json['imageUrls'])
            : null,
        voiceNoteUrl: json['voiceNoteUrl'],
        voiceDuration: json['voiceDuration']?.toDouble(),
        transcription: json['transcription'],
        weather: json['weather'],
        temperature: json['temperature']?.toDouble(),
        linkedFindingIds: json['linkedFindingIds'] != null
            ? List<String>.from(json['linkedFindingIds'])
            : null,
        metadata: json['metadata'],
        isPinned: json['isPinned'] ?? false,
        isPrivate: json['isPrivate'] ?? false,
      );

  JournalEntry copyWith({
    String? id,
    String? siteId,
    JournalEntryType? type,
    String? title,
    String? content,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? authorId,
    String? authorName,
    WorkCondition? workCondition,
    List<String>? tags,
    List<String>? imageUrls,
    String? voiceNoteUrl,
    double? voiceDuration,
    String? transcription,
    String? weather,
    double? temperature,
    List<String>? linkedFindingIds,
    Map<String, dynamic>? metadata,
    bool? isPinned,
    bool? isPrivate,
  }) =>
      JournalEntry(
        id: id ?? this.id,
        siteId: siteId ?? this.siteId,
        type: type ?? this.type,
        title: title ?? this.title,
        content: content ?? this.content,
        createdAt: createdAt ?? this.createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        authorId: authorId ?? this.authorId,
        authorName: authorName ?? this.authorName,
        workCondition: workCondition ?? this.workCondition,
        tags: tags ?? this.tags,
        imageUrls: imageUrls ?? this.imageUrls,
        voiceNoteUrl: voiceNoteUrl ?? this.voiceNoteUrl,
        voiceDuration: voiceDuration ?? this.voiceDuration,
        transcription: transcription ?? this.transcription,
        weather: weather ?? this.weather,
        temperature: temperature ?? this.temperature,
        linkedFindingIds: linkedFindingIds ?? this.linkedFindingIds,
        metadata: metadata ?? this.metadata,
        isPinned: isPinned ?? this.isPinned,
        isPrivate: isPrivate ?? this.isPrivate,
      );
}

/// Daily summary for field journal
class DailySummary {
  final DateTime date;
  final int entriesCount;
  final int findingsCount;
  final int photosCount;
  final int voiceNotesCount;
  final List<String> highlights;
  final WorkCondition? overallCondition;
  final String? weatherSummary;

  DailySummary({
    required this.date,
    this.entriesCount = 0,
    this.findingsCount = 0,
    this.photosCount = 0,
    this.voiceNotesCount = 0,
    this.highlights = const [],
    this.overallCondition,
    this.weatherSummary,
  });

  String get dateString {
    final months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'entriesCount': entriesCount,
        'findingsCount': findingsCount,
        'photosCount': photosCount,
        'voiceNotesCount': voiceNotesCount,
        'highlights': highlights,
        'overallCondition': overallCondition?.name,
        'weatherSummary': weatherSummary,
      };
}

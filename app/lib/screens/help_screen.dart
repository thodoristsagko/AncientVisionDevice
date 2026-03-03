import 'package:flutter/material.dart';
import '../services/tutorial_service.dart';
import '../utils/app_styles.dart';

/// Help and Tutorial Screen
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final _tutorialService = TutorialService();
  final _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('Help & Tutorials', style: AppTextStyles.h3),
        backgroundColor: Colors.transparent,
        foregroundColor: AppColors.textPrimary,
        elevation: 0,
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppColors.accent,
          labelStyle: AppTextStyles.body,
          unselectedLabelStyle: AppTextStyles.subtitle,
          tabs: const [
            Tab(text: 'Tutorials'),
            Tab(text: 'Help'),
            Tab(text: 'FAQ'),
          ],
        ),
      ),
      body: Container(
        decoration: AppDecorations.screenBackground,
        child: SafeArea(
          child: Column(
            children: [
              // Search bar
              Padding(
                padding: AppSpacing.screenPadding,
                child: TextField(
                  controller: _searchController,
                  style: AppTextStyles.body,
                  decoration: InputDecoration(
                    hintText: 'Search help topics...',
                    hintStyle: AppTextStyles.subtitle,
                    prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
                    filled: true,
                    fillColor: AppColors.cardBackground,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AppSizes.borderRadius),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: _searchQuery.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear, color: AppColors.textSecondary),
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _searchQuery = '');
                            },
                          )
                        : null,
                  ),
                  onChanged: (value) => setState(() => _searchQuery = value),
                ),
              ),

              // Tab content
              Expanded(
                child: TabBarView(
                  controller: _tabController,
                  children: [
                    _buildTutorialsTab(),
                    _buildHelpTab(),
                    _buildFAQTab(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTutorialsTab() {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        // Getting Started
        _buildTutorialCard(
          'Getting Started',
          'Learn the basics of AncientVision',
          Icons.play_circle_filled,
          Colors.green,
          () => _showTutorial(TutorialService.onboardingSteps),
        ),

        // Feature tutorials
        ...TutorialService.featureTutorials.entries.map((entry) {
          String title;
          String description;
          IconData icon;
          Color color;

          switch (entry.key) {
            case 'findings':
              title = 'Recording Findings';
              description = 'Document artifacts properly';
              icon = Icons.search;
              color = Colors.blue;
              break;
            case 'context_sheet':
              title = 'Context Sheets';
              description = 'Record stratigraphic data';
              icon = Icons.layers;
              color = Colors.orange;
              break;
            case 'sensors':
              title = 'Environmental Sensors';
              description = 'Connect & monitor M5 StickC';
              icon = Icons.sensors;
              color = Colors.teal;
              break;
            case 'export':
              title = 'Exporting Data';
              description = 'PDF, CSV, GeoJSON & more';
              icon = Icons.file_download;
              color = Colors.indigo;
              break;
            case 'field_journal':
              title = 'Field Journal';
              description = 'Daily excavation logging';
              icon = Icons.book;
              color = Colors.brown;
              break;
            case 'coins':
              title = 'Documenting Coins';
              description = 'Numismatic recording guide';
              icon = Icons.paid;
              color = const Color(0xFFB8860B);
              break;
            case 'fragments':
              title = 'Pottery Fragments';
              description = 'Sherd analysis & recording';
              icon = Icons.broken_image;
              color = const Color(0xFFCD853F);
              break;
            default:
              title = entry.key;
              description = 'Learn more about ${entry.key}';
              icon = Icons.school;
              color = Colors.grey;
          }

          return _buildTutorialCard(
            title,
            description,
            icon,
            color,
            () => _showTutorial(entry.value),
          );
        }),

        const SizedBox(height: 16),

        // Quick tips
        _buildSectionTitle('Quick Tips'),
        _buildQuickTips(),

        const SizedBox(height: 24),

        // About section
        _buildSectionTitle('About'),
        _buildAboutSection(),

        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildAboutSection() {
    return Container(
      padding: AppSpacing.cardPadding,
      decoration: AppDecorations.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: AppDecorations.iconContainer(AppColors.accent),
                child: const Icon(Icons.temple_buddhist, color: AppColors.accent, size: AppSizes.iconLarge),
              ),
              const SizedBox(width: AppSpacing.md),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('AncientVision', style: AppTextStyles.h3),
                    Text('Version 1.0.0', style: AppTextStyles.subtitleSmall),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'AncientVision is developed for the FIRST LEGO League 2025-2026 "Unearthed" season. '
            'Designed to help archaeologists and researchers document, analyze, and preserve '
            'archaeological findings in the field.',
            style: AppTextStyles.subtitle.copyWith(height: 1.5),
          ),
          const SizedBox(height: AppSpacing.lg),
          AppWidgets.divider(),
          const SizedBox(height: AppSpacing.md),
          Text('Created with passion by Team Thodoris', style: AppTextStyles.accentText.copyWith(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildHelpTab() {
    final articles = _searchQuery.isEmpty
        ? TutorialService.helpArticles
        : _tutorialService.searchArticles(_searchQuery);

    if (articles.isEmpty) {
      return _buildEmptySearch();
    }

    // Group by category
    final grouped = <HelpCategory, List<HelpArticle>>{};
    for (final article in articles) {
      grouped.putIfAbsent(article.category, () => []).add(article);
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: grouped.entries.map((entry) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildCategoryHeader(entry.key),
            ...entry.value.map((article) => _buildArticleCard(article)),
            const SizedBox(height: 16),
          ],
        );
      }).toList(),
    );
  }

  Widget _buildFAQTab() {
    final faqs = _searchQuery.isEmpty
        ? TutorialService.faqs
        : _tutorialService.searchFAQs(_searchQuery);

    if (faqs.isEmpty) {
      return _buildEmptySearch();
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: faqs.length,
      itemBuilder: (context, index) {
        final faq = faqs[index];
        return _buildFAQCard(faq);
      },
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(title, style: AppTextStyles.h3),
    );
  }

  Widget _buildTutorialCard(
    String title,
    String description,
    IconData icon,
    Color color,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.md),
        padding: AppSpacing.cardPadding,
        decoration: AppDecorations.card,
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: AppDecorations.iconContainer(color),
              child: Icon(icon, color: color, size: AppSizes.iconLarge),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppTextStyles.h4),
                  Text(description, style: AppTextStyles.subtitleSmall),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _buildQuickTips() {
    final tips = [
      ('Take 16+ photos', 'More photos = better 3D model', Icons.camera_alt),
      ('Good lighting', 'Even, diffused light works best', Icons.light_mode),
      ('Save often', 'Auto-save keeps your work safe', Icons.save),
      ('Use cloud', 'Cloud processing gives better results', Icons.cloud),
      ('Include scale', 'Physical scale bar in every photo', Icons.straighten),
      ('Log daily', 'Write journal entries every session', Icons.edit_note),
      ('GPS accuracy', 'Wait for high accuracy before saving', Icons.gps_fixed),
      ('Backup data', 'Regular backups prevent data loss', Icons.backup),
    ];

    return Wrap(
      spacing: AppSpacing.sm,
      runSpacing: AppSpacing.sm,
      children: tips.map((tip) => Container(
        width: (MediaQuery.of(context).size.width - 48) / 2,
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: AppDecorations.highlightCard,
        child: Row(
          children: [
            Icon(tip.$3, color: AppColors.accent, size: AppSizes.iconMedium),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(tip.$1, style: AppTextStyles.bodySmall.copyWith(fontWeight: FontWeight.bold)),
                  Text(tip.$2, style: AppTextStyles.caption),
                ],
              ),
            ),
          ],
        ),
      )).toList(),
    );
  }

  Widget _buildCategoryHeader(HelpCategory category) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      child: Row(
        children: [
          Icon(category.icon, color: AppColors.accent, size: AppSizes.iconMedium),
          const SizedBox(width: AppSpacing.sm),
          Text(category.label, style: AppTextStyles.h4),
        ],
      ),
    );
  }

  Widget _buildArticleCard(HelpArticle article) {
    return GestureDetector(
      onTap: () => _showArticle(article),
      child: Container(
        margin: const EdgeInsets.only(bottom: AppSpacing.sm),
        padding: AppSpacing.cardPadding,
        decoration: AppDecorations.section,
        child: Row(
          children: [
            Expanded(child: Text(article.title, style: AppTextStyles.body)),
            const Icon(Icons.chevron_right, color: AppColors.textSecondary, size: AppSizes.iconMedium),
          ],
        ),
      ),
    );
  }

  Widget _buildFAQCard(FAQItem faq) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      decoration: AppDecorations.card,
      child: ExpansionTile(
        title: Text(faq.question, style: AppTextStyles.body),
        iconColor: AppColors.textSecondary,
        collapsedIconColor: AppColors.textSecondary,
        children: [
          Padding(
            padding: AppSpacing.cardPadding,
            child: Text(faq.answer, style: AppTextStyles.subtitle.copyWith(height: 1.5)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptySearch() {
    return AppWidgets.emptyState(Icons.search_off, 'No results found\nTry a different search term');
  }

  void _showTutorial(List<TutorialStep> steps) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.primaryDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => _TutorialViewer(steps: steps),
    );
  }

  void _showArticle(HelpArticle article) {
    _tutorialService.markArticleRead(article.id);

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.primaryDark,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.7,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) => SingleChildScrollView(
          controller: scrollController,
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(article.category.icon, color: AppColors.accent),
                  const SizedBox(width: AppSpacing.sm),
                  Text(article.category.label, style: AppTextStyles.accentText),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text(article.title, style: AppTextStyles.h2),
              const SizedBox(height: AppSpacing.xl),
              Text(article.content, style: AppTextStyles.bodyLarge.copyWith(height: 1.6)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tutorial step viewer widget
class _TutorialViewer extends StatefulWidget {
  final List<TutorialStep> steps;

  const _TutorialViewer({required this.steps});

  @override
  State<_TutorialViewer> createState() => _TutorialViewerState();
}

class _TutorialViewerState extends State<_TutorialViewer> {
  int _currentStep = 0;
  final _pageController = PageController();

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.6,
      child: Column(
        children: [
          // Progress indicator
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              children: List.generate(
                widget.steps.length,
                (index) => Expanded(
                  child: Container(
                    height: 4,
                    margin: const EdgeInsets.symmetric(horizontal: 2),
                    decoration: BoxDecoration(
                      color: index <= _currentStep ? AppColors.accent : AppColors.cardBorder,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Content
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: widget.steps.length,
              onPageChanged: (index) => setState(() => _currentStep = index),
              itemBuilder: (context, index) {
                final step = widget.steps[index];
                return Padding(
                  padding: const EdgeInsets.all(AppSpacing.xxl),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 80,
                        height: 80,
                        decoration: AppDecorations.circleBadge(AppColors.accent),
                        child: Icon(step.icon, color: AppColors.accent, size: AppSizes.iconXLarge),
                      ),
                      const SizedBox(height: AppSpacing.xxl),
                      Text(step.title, style: AppTextStyles.h2, textAlign: TextAlign.center),
                      const SizedBox(height: AppSpacing.md),
                      Text(
                        step.description,
                        style: AppTextStyles.subtitle.copyWith(height: 1.5),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),

          // Navigation
          Padding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text('Skip', style: AppTextStyles.button.copyWith(color: AppColors.textSecondary)),
                ),
                Row(
                  children: [
                    if (_currentStep > 0)
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
                        onPressed: () {
                          _pageController.previousPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          );
                        },
                      ),
                    const SizedBox(width: AppSpacing.sm),
                    ElevatedButton(
                      onPressed: () {
                        if (_currentStep < widget.steps.length - 1) {
                          _pageController.nextPage(
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeInOut,
                          );
                        } else {
                          Navigator.pop(context);
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.accent,
                        foregroundColor: AppColors.primary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      child: Text(_currentStep < widget.steps.length - 1 ? 'Next' : 'Done'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

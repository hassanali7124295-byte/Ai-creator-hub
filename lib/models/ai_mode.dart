import 'package:flutter/material.dart';

/// Pak AI's selectable chat "modes" (Step 16). Each mode is nothing more
/// than an extra system instruction layered on top of [GeminiService]'s
/// base identity prompt before a message is sent — see
/// [GeminiService.sendMessage]'s `modeInstruction` parameter. There are no
/// separate screens, routes, models, or services behind this: picking a
/// mode just changes what gets prepended to the next request from the one
/// chat screen.
enum AiMode {
  general,
  coding,
  imagePrompt,
  videoPrompt,
  scriptWriter,
  studyAssistant,
  businessAdvisor,
  translator,
  promptOptimizer,
}

extension AiModeX on AiMode {
  /// A single display emoji, used on the app bar pill and the mode picker.
  String get emoji => switch (this) {
        AiMode.general => '🤖',
        AiMode.coding => '💻',
        AiMode.imagePrompt => '🖼',
        AiMode.videoPrompt => '🎬',
        AiMode.scriptWriter => '✍',
        AiMode.studyAssistant => '📚',
        AiMode.businessAdvisor => '📈',
        AiMode.translator => '🌍',
        AiMode.promptOptimizer => '🧠',
      };

  String get label => switch (this) {
        AiMode.general => 'General AI',
        AiMode.coding => 'Coding Expert',
        AiMode.imagePrompt => 'Image Prompt Expert',
        AiMode.videoPrompt => 'Video Prompt Expert',
        AiMode.scriptWriter => 'Script Writer',
        AiMode.studyAssistant => 'Study Assistant',
        AiMode.businessAdvisor => 'Business Advisor',
        AiMode.translator => 'Translator',
        AiMode.promptOptimizer => 'Prompt Optimizer',
      };

  /// One-line description shown under the label in the mode picker sheet.
  String get description => switch (this) {
        AiMode.general => 'Balanced, everyday help',
        AiMode.coding => 'Write, debug, and explain code',
        AiMode.imagePrompt => 'Craft detailed image-gen prompts',
        AiMode.videoPrompt => 'Craft detailed video-gen prompts',
        AiMode.scriptWriter => 'Scripts, dialogue, and scenes',
        AiMode.studyAssistant => 'Explains topics and quizzes you',
        AiMode.businessAdvisor => 'Strategy, growth, and pricing',
        AiMode.translator => 'Translate between languages',
        AiMode.promptOptimizer => 'Sharpens any AI prompt',
      };

  /// A small glyph for the picker sheet — the emoji carries the visual
  /// identity, this is a backup for platforms/fonts that render emoji
  /// inconsistently and gives each card an icon to lay out around.
  IconData get icon => switch (this) {
        AiMode.general => Icons.auto_awesome_rounded,
        AiMode.coding => Icons.code_rounded,
        AiMode.imagePrompt => Icons.image_outlined,
        AiMode.videoPrompt => Icons.movie_creation_outlined,
        AiMode.scriptWriter => Icons.edit_note_rounded,
        AiMode.studyAssistant => Icons.school_outlined,
        AiMode.businessAdvisor => Icons.trending_up_rounded,
        AiMode.translator => Icons.translate_rounded,
        AiMode.promptOptimizer => Icons.psychology_outlined,
      };

  /// Extra system instruction layered on top of [GeminiService]'s base
  /// identity prompt whenever this mode is active — see
  /// [GeminiService.sendMessage]. Empty for [AiMode.general]: the base
  /// identity already covers default, balanced behavior, so there's
  /// nothing to add.
  String get systemPrompt => switch (this) {
        AiMode.general => '',
        AiMode.coding =>
          'Current mode: Coding Expert. Answer as an expert software '
              'engineer — give correct, working code, explain your '
              'reasoning concisely, call out edge cases and trade-offs, '
              'and default to well-formatted code blocks with the right '
              'language tag.',
        AiMode.imagePrompt =>
          "Current mode: Image Prompt Expert. Turn the user's idea into a "
              'detailed, ready-to-use text-to-image prompt (subject, '
              'style, lighting, composition, camera/lens details, mood) '
              'suitable for tools like Midjourney, DALL·E, or Stable '
              'Diffusion. Offer 1-3 prompt variations when useful.',
        AiMode.videoPrompt =>
          "Current mode: Video Prompt Expert. Turn the user's idea into a "
              'detailed, ready-to-use text-to-video prompt (scene '
              'description, camera movement, pacing, lighting, mood, '
              'duration) suitable for tools like Sora, Runway, or Pika.',
        AiMode.scriptWriter =>
          'Current mode: Script Writer. Write clear, well-structured '
              'scripts (video, YouTube, ad, or dialogue as requested) with '
              'scene/shot breaks, natural dialogue, and a strong hook.',
        AiMode.studyAssistant =>
          'Current mode: Study Assistant. Explain concepts clearly and '
              'simply, break down complex topics step-by-step, and offer '
              'to quiz the user or summarize material when it would help.',
        AiMode.businessAdvisor =>
          'Current mode: Business Advisor. Give practical, structured '
              'business/startup/marketing advice — strategy, growth, '
              'pricing, positioning — grounded in common business '
              'frameworks, not generic platitudes.',
        AiMode.translator =>
          'Current mode: Translator. Translate accurately and naturally '
              "between languages, preserving tone and meaning; if the "
              "target language isn't specified, ask or infer it from "
              'context.',
        AiMode.promptOptimizer =>
          "Current mode: Prompt Optimizer. Rewrite and sharpen whatever "
              'prompt the user gives you — make it clearer, more '
              'specific, and better structured for getting a high-quality '
              'AI response — then briefly explain what you changed.',
      };
}

# Step 18.1 — Change Report

**File touched (only one):** `lib/screens/chat_screen.dart`

1. **Removed** the mode selector (`_ModePill`) from the `AppBar` actions.
2. **Moved** it to a new row placed directly above `_ChatInputBar` (between the attachment preview and the composer), left-aligned — matching ChatGPT's model-selector placement.
3. **Renamed** its label from the dynamic mode name (e.g. "General AI") to the static text **"Select Model"**. The active mode's emoji still shows next to it as a visual cue.
4. **Unchanged:** the `AiMode` enum, all 9 existing AI Modes, and `ai_mode_sheet.dart`. No paid models added.
5. Tap behavior unchanged: still calls `_pickMode()` → `showAiModeSheet()`, the same existing bottom sheet.
6. **Spacing/alignment:** new row uses 12px horizontal padding (matching the input bar's own side margin) with small top/bottom gaps (8 / 4) for clean rhythm above the composer.
7. **No other file, screen, widget, service, or the Gemini API integration was touched.**

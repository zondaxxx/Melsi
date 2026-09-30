// Strings owned by the palette feature. Keys start with palette.;
// Russian first, English mirrors every key.

import 'strings.dart';

const StringTable kPaletteStrings = StringTable(
  prefixes: ['palette.'],
  ru: <String, String>{
    'palette.title': 'Командная палитра',
    'palette.row': 'Командная палитра  ⌘K',
    'palette.hint': 'Сервер, действие или настройка…',
    'palette.empty': 'Ничего не найдено',
    // Shown only in the palette's own empty (no query) state — the one
    // place the shortcut is documented, since the shell and Settings are
    // frozen. {k} is ⌘K on macOS and Ctrl+K elsewhere.
    'palette.hintRow': '{k} — открыть палитру · ↑↓ — выбор · ↵ — выполнить · Esc — закрыть',
    'palette.on': 'вкл.',
    'palette.off': 'выкл.',
    'palette.reconnect': 'Переподключить',
    'palette.lang.ru': 'Русский',
    'palette.lang.en': 'English',
    // Group headers (rendered through [Overline], hence uppercase).
    'palette.g.servers': 'СЕРВЕРЫ',
    'palette.g.actions': 'ДЕЙСТВИЯ',
    'palette.g.settings': 'НАСТРОЙКИ',
    'palette.g.tabs': 'РАЗДЕЛЫ',
    'palette.g.tools': 'ИНСТРУМЕНТЫ',
    'palette.g.recent': 'НЕДАВНИЕ',
  },
  en: <String, String>{
    'palette.title': 'Command palette',
    'palette.row': 'Command palette  ⌘K',
    'palette.hint': 'Server, action or setting…',
    'palette.empty': 'Nothing found',
    'palette.hintRow': '{k} — open the palette · ↑↓ — move · ↵ — run · Esc — close',
    'palette.on': 'on',
    'palette.off': 'off',
    'palette.reconnect': 'Reconnect',
    'palette.lang.ru': 'Русский',
    'palette.lang.en': 'English',
    'palette.g.servers': 'SERVERS',
    'palette.g.actions': 'ACTIONS',
    'palette.g.settings': 'SETTINGS',
    'palette.g.tabs': 'SECTIONS',
    'palette.g.tools': 'TOOLS',
    'palette.g.recent': 'RECENT',
  },
);

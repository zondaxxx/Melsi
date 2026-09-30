// Strings owned by the favorites feature. Keys start with fav. / clip.;
// Russian first, English mirrors every key.

import 'strings.dart';

const StringTable kFavoritesStrings = StringTable(
  prefixes: ['fav.', 'clip.'],
  ru: <String, String>{
    // favourites
    'fav.title': 'Избранное',
    'fav.add': 'В избранное',
    'fav.remove': 'Убрать из избранного',
    'fav.recent': 'Недавние',
    'fav.best': 'Лучший по стране',
    'fav.toggleCmd': 'В избранное / убрать',
    'fav.pickCmd': 'Избранный сервер',
    // clipboard
    'clip.link': 'В буфере ссылка на сервер',
    'clip.sub': 'В буфере подписка ({host})',
    'clip.many': 'В буфере {n}',
    'clip.many.plural': 'сервер|сервера|серверов',
    'clip.add': 'Добавить',
    'clip.close': 'Скрыть',
    'clip.hint': 'Нашли ссылку в буфере — ',
    'clip.setting': 'Предлагать импорт из буфера',
    'clip.settingHint':
        'Текст не сохраняется, только его отпечаток. На iOS система показывает уведомление о вставке.',
  },
  en: <String, String>{
    // favourites
    'fav.title': 'Favourites',
    'fav.add': 'Add to favourites',
    'fav.remove': 'Remove from favourites',
    'fav.recent': 'Recent',
    'fav.best': 'Best per country',
    'fav.toggleCmd': 'Pin / unpin current server',
    'fav.pickCmd': 'Favourite server',
    // clipboard
    'clip.link': 'A server link is on the clipboard',
    'clip.sub': 'A subscription is on the clipboard ({host})',
    'clip.many': '{n} on the clipboard',
    'clip.many.plural': 'server|servers|servers',
    'clip.add': 'Add',
    'clip.close': 'Dismiss',
    'clip.hint': 'Found a link on the clipboard — ',
    'clip.setting': 'Offer clipboard imports',
    'clip.settingHint': 'Only a fingerprint is stored, never the text. iOS shows a paste notice.',
  },
);

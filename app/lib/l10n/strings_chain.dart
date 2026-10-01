// Strings owned by the chain feature. Keys start with chain.;
// Russian first, English mirrors every key.

import 'strings.dart';

const StringTable kChainStrings = StringTable(
  prefixes: ['chain.'],
  ru: <String, String>{
    'chain.title': 'Двойной VPN',
    'chain.enable': 'Через входной сервер',
    'chain.hint':
        'Трафик идёт через входной сервер, затем через выбранный. Медленнее, но провайдер не видит выходной узел.',
    'chain.entry': 'Входной сервер',
    'chain.none': 'не выбран',
    'chain.isExit': 'это выходной сервер',
    'chain.noEndpoint': 'WireGuard не может быть входом',
    'chain.footer':
        'Скорость примерно вдвое ниже. UDP-игры работают, только если оба сервера поддерживают UDP.',
    'chain.via': 'через {entry}',
    'chain.useAsEntry': 'Сделать входным',
    'chain.isEntry': 'входной сервер',
    'chain.toggleCmd': 'Двойной VPN вкл/выкл',
    'chain.needTwo': 'Нужны хотя бы два сервера',
    'chain.needTwoHint': 'Один будет входом, другой — выходом. Добавьте ещё сервер.',
  },
  en: <String, String>{
    'chain.title': 'Double VPN',
    'chain.enable': 'Via an entry server',
    'chain.hint':
        'Traffic goes through the entry server, then the selected one. Slower, but your ISP never sees the exit.',
    'chain.entry': 'Entry server',
    'chain.none': 'not set',
    'chain.isExit': 'this is the exit',
    'chain.noEndpoint': 'WireGuard cannot be an entry',
    'chain.footer':
        'Roughly half the speed. UDP games work only if both servers support UDP.',
    'chain.via': 'via {entry}',
    'chain.useAsEntry': 'Use as entry',
    'chain.isEntry': 'entry server',
    'chain.toggleCmd': 'Toggle double VPN',
    'chain.needTwo': 'At least two servers are needed',
    'chain.needTwoHint': 'One will be the entry, the other the exit. Add another server.',
  },
);

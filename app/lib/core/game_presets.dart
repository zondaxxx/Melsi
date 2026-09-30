// Built-in Game Mode presets.
//
// Conventions:
//  * [GamePreset.desktopProcesses]: exact process names as sing-box sees them
//    (`process_name` matches the executable file name; Windows keeps `.exe`).
//  * [GamePreset.domainSuffixes]: login / matchmaking / game-API domains
//    routed through the `game` selector. Most real-time game servers are
//    bare IPs, so process/package matching is the primary signal.
//  * [GamePreset.downloadDomainSuffixes]: launcher / CDN / patch domains sent
//    DIRECT when `GameSettings.directDownloads` is on. These are emitted
//    BEFORE the game domain rules, so e.g. `download.epicgames.com` goes direct
//    even though `epicgames.com` is a game domain.
//  * Fields we are not sure about are left empty on purpose.

import 'models.dart';

const _steamGame = ['steamserver.net'];
const _steamDownloads = [
  'steamcontent.com',
  'steampipe.akamaized.net',
  'steamcdn-a.akamaihd.net',
];
const _riotGame = ['riotgames.com', 'pvp.net'];
const _riotDownloads = ['riotcdn.net'];
const _epicDownloads = [
  'download.epicgames.com',
  'download2.epicgames.com',
  'download3.epicgames.com',
  'download4.epicgames.com',
  'fastly-download.epicgames.com',
  'epicgames-download1.akamaized.net',
];
const _blizzardDownloads = [
  'blzddist1-a.akamaihd.net',
  'level3.blizzard.com',
];
const _supercellDownloads = [
  'game-assets.clashofclans.com',
  'game-assets.clashroyaleapp.com',
  'game-assets.brawlstarsgame.com',
];

const List<GamePreset> kGamePresets = [
  // ------------------------------------------------------------- PC shooters
  GamePreset(
    id: 'cs2',
    name: 'Counter-Strike 2',
    desktopProcesses: ['cs2.exe', 'cs2'],
    domainSuffixes: _steamGame,
    downloadDomainSuffixes: _steamDownloads,
  ),
  GamePreset(
    id: 'valorant',
    name: 'VALORANT',
    desktopProcesses: [
      'VALORANT-Win64-Shipping.exe',
      'VALORANT.exe',
    ],
    domainSuffixes: _riotGame,
    downloadDomainSuffixes: _riotDownloads,
  ),
  GamePreset(
    id: 'fortnite',
    name: 'Fortnite',
    androidPackages: ['com.epicgames.fortnite'],
    desktopProcesses: [
      'FortniteClient-Win64-Shipping.exe',
      'FortniteClient-Win64-Shipping_EAC_EOS.exe',
      'FortniteLauncher.exe',
    ],
    domainSuffixes: ['epicgames.com', 'epicgames.dev', 'fortnite.com'],
    downloadDomainSuffixes: _epicDownloads,
  ),
  GamePreset(
    id: 'pubg',
    name: 'PUBG: Battlegrounds',
    desktopProcesses: ['TslGame.exe', 'TslGame_BE.exe'],
    domainSuffixes: ['pubg.com', ..._steamGame],
    downloadDomainSuffixes: _steamDownloads,
  ),
  GamePreset(
    id: 'apex',
    name: 'Apex Legends',
    desktopProcesses: ['r5apex.exe', 'r5apex_dx12.exe'],
    domainSuffixes: ['respawn.com', ..._steamGame],
    downloadDomainSuffixes: _steamDownloads,
  ),
  GamePreset(
    id: 'warzone',
    name: 'Call of Duty: Warzone',
    desktopProcesses: ['cod.exe', 'ModernWarfare.exe'],
    domainSuffixes: ['callofduty.com', 'activision.com', 'demonware.net'],
    downloadDomainSuffixes: [..._blizzardDownloads, ..._steamDownloads],
  ),
  GamePreset(
    id: 'overwatch2',
    name: 'Overwatch 2',
    desktopProcesses: ['Overwatch.exe'],
    domainSuffixes: ['battle.net', 'blizzard.com'],
    downloadDomainSuffixes: _blizzardDownloads,
  ),
  GamePreset(
    id: 'r6siege',
    name: 'Rainbow Six Siege',
    desktopProcesses: ['RainbowSix.exe', 'RainbowSix_Vulkan.exe'],
    domainSuffixes: ['ubi.com', 'ubisoft.com'],
    downloadDomainSuffixes: _steamDownloads,
  ),
  GamePreset(
    id: 'tarkov',
    name: 'Escape from Tarkov',
    desktopProcesses: ['EscapeFromTarkov.exe', 'BsgLauncher.exe'],
    domainSuffixes: ['escapefromtarkov.com', 'battlestategames.com'],
  ),
  GamePreset(
    id: 'rust',
    name: 'Rust',
    desktopProcesses: ['RustClient.exe'],
    domainSuffixes: ['facepunch.com', ..._steamGame],
    downloadDomainSuffixes: _steamDownloads,
  ),
  GamePreset(
    id: 'marvel_rivals',
    name: 'Marvel Rivals',
    desktopProcesses: ['Marvel-Win64-Shipping.exe'],
    domainSuffixes: ['marvelrivals.com', ..._steamGame],
    downloadDomainSuffixes: _steamDownloads,
  ),
  GamePreset(
    id: 'war_thunder',
    name: 'War Thunder',
    desktopProcesses: ['aces.exe'],
    domainSuffixes: ['gaijin.net', 'warthunder.com'],
  ),
  GamePreset(
    id: 'wot',
    name: 'World of Tanks / Мир танков',
    androidPackages: ['net.wargaming.wot.blitz'],
    desktopProcesses: ['WorldOfTanks.exe', 'wgc.exe', 'lgc.exe'],
    domainSuffixes: [
      'wargaming.net',
      'worldoftanks.eu',
      'worldoftanks.com',
      'lesta.ru',
      'tanki.su',
    ],
  ),

  // --------------------------------------------------------------- PC MOBA
  GamePreset(
    id: 'dota2',
    name: 'Dota 2',
    desktopProcesses: ['dota2.exe', 'dota2'],
    domainSuffixes: _steamGame,
    downloadDomainSuffixes: _steamDownloads,
  ),
  GamePreset(
    id: 'deadlock',
    name: 'Deadlock',
    desktopProcesses: ['deadlock.exe'],
    domainSuffixes: _steamGame,
    downloadDomainSuffixes: _steamDownloads,
  ),
  GamePreset(
    id: 'lol',
    name: 'League of Legends',
    desktopProcesses: [
      'League of Legends.exe',
      'LeagueClient.exe',
      'LeagueClientUx.exe',
      'League of Legends',
      'LeagueClient',
    ],
    domainSuffixes: [..._riotGame, 'leagueoflegends.com'],
    downloadDomainSuffixes: _riotDownloads,
  ),

  // ------------------------------------------------------------ sandbox etc.
  GamePreset(
    id: 'roblox',
    name: 'Roblox',
    androidPackages: ['com.roblox.client'],
    desktopProcesses: ['RobloxPlayerBeta.exe', 'RobloxPlayer'],
    domainSuffixes: ['roblox.com'],
    downloadDomainSuffixes: ['rbxcdn.com'],
  ),
  GamePreset(
    id: 'minecraft',
    name: 'Minecraft',
    androidPackages: ['com.mojang.minecraftpe'],
    // Java Edition runs inside the Java runtime (javaw.exe on Windows).
    desktopProcesses: [
      'Minecraft.Windows.exe',
      'MinecraftLauncher.exe',
      'javaw.exe',
    ],
    domainSuffixes: ['minecraft.net', 'mojang.com', 'minecraftservices.com'],
    downloadDomainSuffixes: [
      'libraries.minecraft.net',
      'resources.download.minecraft.net',
      'piston-data.mojang.com',
      'piston-meta.mojang.com',
      'launcher.mojang.com',
    ],
  ),
  GamePreset(
    id: 'genshin',
    name: 'Genshin Impact',
    androidPackages: ['com.miHoYo.GenshinImpact'],
    desktopProcesses: ['GenshinImpact.exe', 'YuanShen.exe'],
    domainSuffixes: ['yuanshen.com', 'hoyoverse.com', 'mihoyo.com'],
    downloadDomainSuffixes: [
      'autopatchhk.yuanshen.com',
      'autopatchcn.yuanshen.com',
    ],
  ),
  GamePreset(
    id: 'hsr',
    name: 'Honkai: Star Rail',
    androidPackages: ['com.HoYoverse.hkrpgoversea'],
    desktopProcesses: ['StarRail.exe'],
    domainSuffixes: ['starrails.com', 'hoyoverse.com', 'mihoyo.com'],
  ),

  // --------------------------------------------------------------- mobile
  GamePreset(
    id: 'pubg_mobile',
    name: 'PUBG Mobile',
    androidPackages: [
      'com.tencent.ig',
      'com.pubg.krmobile',
      'com.vng.pubgmobile',
      'com.rekoo.pubgm',
      'com.pubg.imobile',
    ],
    domainSuffixes: ['pubgmobile.com', 'igamecj.com'],
  ),
  GamePreset(
    id: 'codm',
    name: 'Call of Duty: Mobile',
    androidPackages: [
      'com.activision.callofduty.shooter',
      'com.garena.game.codm',
      'com.vng.codmvn',
    ],
    domainSuffixes: ['callofduty.com', 'activision.com'],
  ),
  GamePreset(
    id: 'standoff2',
    name: 'Standoff 2',
    androidPackages: ['com.axlebolt.standoff2'],
    domainSuffixes: ['axlebolt.com', 'standoff2.com'],
  ),
  GamePreset(
    id: 'mlbb',
    name: 'Mobile Legends: Bang Bang',
    androidPackages: ['com.mobile.legends'],
    domainSuffixes: ['mobilelegends.com', 'moonton.com'],
  ),
  GamePreset(
    id: 'wild_rift',
    name: 'League of Legends: Wild Rift',
    androidPackages: ['com.riotgames.league.wildrift'],
    domainSuffixes: _riotGame,
    downloadDomainSuffixes: _riotDownloads,
  ),
  GamePreset(
    id: 'brawl_stars',
    name: 'Brawl Stars',
    androidPackages: ['com.supercell.brawlstars'],
    domainSuffixes: ['brawlstarsgame.com', 'supercell.com'],
    downloadDomainSuffixes: _supercellDownloads,
  ),
  GamePreset(
    id: 'clash_royale',
    name: 'Clash Royale',
    androidPackages: ['com.supercell.clashroyale'],
    domainSuffixes: ['clashroyaleapp.com', 'supercell.com'],
    downloadDomainSuffixes: _supercellDownloads,
  ),
  GamePreset(
    id: 'clash_of_clans',
    name: 'Clash of Clans',
    androidPackages: ['com.supercell.clashofclans'],
    domainSuffixes: ['clashofclans.com', 'supercell.com'],
    downloadDomainSuffixes: _supercellDownloads,
  ),
  GamePreset(
    id: 'free_fire',
    name: 'Free Fire',
    androidPackages: ['com.dts.freefireth', 'com.dts.freefiremax'],
    domainSuffixes: ['garena.com', 'freefiremobile.com'],
  ),
  GamePreset(
    id: 'arena_breakout',
    name: 'Arena Breakout',
    androidPackages: ['com.proximabeta.mf.uamo'],
    domainSuffixes: ['arenabreakout.com', 'levelinfinite.com'],
  ),

  // -------------------------------------------------------------- launchers
  GamePreset(
    id: 'steam',
    name: 'Steam',
    desktopProcesses: ['steam.exe', 'steamwebhelper.exe', 'steam', 'steam_osx'],
    domainSuffixes: [
      'steampowered.com',
      'steamcommunity.com',
      'steamstatic.com',
      ..._steamGame,
    ],
    downloadDomainSuffixes: _steamDownloads,
  ),
  GamePreset(
    id: 'epic',
    name: 'Epic Games Launcher',
    desktopProcesses: ['EpicGamesLauncher.exe', 'EpicWebHelper.exe'],
    domainSuffixes: ['epicgames.com', 'epicgames.dev', 'unrealengine.com'],
    downloadDomainSuffixes: _epicDownloads,
  ),
  GamePreset(
    id: 'battlenet',
    name: 'Battle.net',
    desktopProcesses: ['Battle.net.exe'],
    domainSuffixes: ['battle.net', 'blizzard.com'],
    downloadDomainSuffixes: _blizzardDownloads,
  ),
];

GamePreset? gamePresetById(String id) {
  for (final p in kGamePresets) {
    if (p.id == id) return p;
  }
  return null;
}

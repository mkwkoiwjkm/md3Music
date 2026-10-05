import 'dart:convert';

import 'package:http/http.dart' as http;

import 'kugou_models.dart';

/// 外部音源补位（网易云公开接口）。
///
/// 定位：酷狗对部分版权曲只下发 128k（`privilege=5`，`fail_process` 为空，
/// 请求 flac/high 也被静默降级），此时同一首录音在网易云公开接口上仍有
/// 320k（exhigh）可播。本解析器只在**外部确实更好**时才替换播放地址：
///
///  · 歌名 + 歌手必须匹配（网易云返回串内含歌手名）；
///  · 时长与酷狗侧一致（±4s，避免串到 Live/伴奏/翻唱）；
///  · 外部估算码率必须严格高于当前地址的估算码率。
///
/// 三条同时成立才换源，任一不成立就保持酷狗原地址。估算码率统一用
/// `fileSize * 8 / duration`，与 Rust 侧 `quality_from_bitrate` 同口径，
/// 因此不同来源之间可以横向比较。
class ExternalSource {
  ExternalSource({
    http.Client? client,
    this.minSwapGainKbps = 32,
  }) : _client = client ?? http.Client();

  final http.Client _client;

  /// 换源所需的最小码率增益（kbps）。避免在 128↔128、320↔310 之间来回抖。
  final int minSwapGainKbps;

  static const String _searchEndpoint = 'https://music.163.com/api/search/get/web';
  static const String _playerEndpoint =
      'https://music.163.com/api/song/enhance/player/url';

  static const Map<String, String> _headers = {
    'User-Agent':
        'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 Chrome/121 Mobile',
    'Referer': 'https://music.163.com/',
  };

  /// 网易云 `level` 标签 → 本地音质代号。
  static String qualityOfLevel(String? level, int kbps) {
    switch (level) {
      case 'hires':
      case 'jymaster':
      case 'sky':
        return KugouQuality.hires;
      case 'lossless':
        return KugouQuality.lossless;
      case 'exhigh':
        return KugouQuality.high;
      case 'standard':
        return KugouQuality.standard;
    }
    // 未知标签时按实测码率反推（网易云 br 为 bps）。
    if (kbps > 900) return KugouQuality.lossless;
    if (kbps > 200) return KugouQuality.high;
    return KugouQuality.standard;
  }

  /// 估算某条播放地址的码率（kbps）。同一口径才能跨源比较。
  static int estimateKbps({required int fileSize, required int seconds}) {
    if (fileSize <= 0 || seconds <= 0) return 0;
    return (fileSize * 8 / seconds / 1000).round();
  }

  /// 请求网易云拿到该曲可播的最高档地址；无命中返回 null。
  ///
  /// [title]/[artist] 来自酷狗侧歌曲元数据，[kugouSeconds] 为酷狗侧时长。
  /// [currentKbps] 为当前酷狗地址的估算码率，用于"必须更好才换"的判定。
  Future<KugouPlayUrl?> resolveHigherQuality({
    required String title,
    required String artist,
    required int kugouSeconds,
    required int currentKbps,
  }) async {
    final cleanTitle = _stripDecorations(title);
    if (cleanTitle.isEmpty || artist.isEmpty) return null;

    final candidate = await _search(cleanTitle, artist, kugouSeconds);
    if (candidate == null) return null;

    final songId = candidate['id'];
    if (songId is! int) return null;

    final best = await _playerUrl(songId);
    if (best == null) return null;

    final neteaseKbps = best['kbps'] as int;
    if (neteaseKbps < currentKbps + minSwapGainKbps) return null;
    if (neteaseKbps <= 0) return null;

    return KugouPlayUrl(
      url: best['url'] as String,
      fileSize: best['size'] as int,
      bitRate: neteaseKbps * 1000,
      quality: qualityOfLevel(best['level'] as String?, neteaseKbps),
    );
  }

  /// 去掉会影响匹配的括号修饰（Live/伴奏/翻自 等）。
  String _stripDecorations(String title) {
    final buffer = StringBuffer();
    var depth = 0;
    for (final rune in title.runes) {
      final ch = String.fromCharCode(rune);
      if (ch == '(' || ch == '（' || ch == '[' || ch == '【') {
        depth++;
        continue;
      }
      if (ch == ')' || ch == '）' || ch == ']' || ch == '】') {
        if (depth > 0) depth--;
        continue;
      }
      if (depth == 0) buffer.write(ch);
    }
    return buffer.toString().trim();
  }

  Future<Map<String, dynamic>?> _search(
    String title,
    String artist,
    int kugouSeconds,
  ) async {
    try {
      final resp = await _client
          .post(
            Uri.parse(_searchEndpoint),
            headers: _headers,
            body: {
              's': '$title $artist',
              'type': '1',
              'offset': '0',
              'limit': '10',
            },
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode != 200) return null;

      final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
      if (decoded is! Map<String, dynamic>) return null;
      final result = decoded['result'];
      if (result is! Map<String, dynamic>) return null;
      final songs = result['songs'];
      if (songs is! List) return null;

      Map<String, dynamic>? fallback;
      for (final raw in songs) {
        if (raw is! Map<String, dynamic>) continue;
        final name = raw['name']?.toString() ?? '';
        if (!_titleMatches(title, name)) continue;

        final artists = raw['artists'];
        final names = <String>[];
        if (artists is List) {
          for (final a in artists) {
            if (a is Map<String, dynamic>) {
              final n = a['name']?.toString();
              if (n != null && n.isNotEmpty) names.add(n);
            }
          }
        }
        if (names.isEmpty || !_artistMatches(artist, names)) continue;

        final durationMs = raw['duration'];
        final seconds = durationMs is int ? durationMs ~/ 1000 : 0;
        // 时长必须对得上：酷狗与网易云同一录音的时长差通常在 2s 内。
        if (kugouSeconds > 0 && seconds > 0 && (seconds - kugouSeconds).abs() > 4) {
          continue;
        }
        if (seconds == kugouSeconds) return raw;
        fallback ??= raw;
      }
      return fallback;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, dynamic>?> _playerUrl(int songId) async {
    for (final bitrate in const [999000, 320000, 128000]) {
      try {
        final resp = await _client
            .post(
              Uri.parse(_playerEndpoint),
              headers: _headers,
              body: {
                'ids': jsonEncode([songId]),
                'br': '$bitrate',
              },
            )
            .timeout(const Duration(seconds: 12));
        if (resp.statusCode != 200) continue;

        final decoded = jsonDecode(utf8.decode(resp.bodyBytes));
        if (decoded is! Map<String, dynamic>) continue;
        final data = decoded['data'];
        if (data is! List || data.isEmpty) continue;
        final first = data.first;
        if (first is! Map<String, dynamic>) continue;

        final url = first['url']?.toString() ?? '';
        if (url.isEmpty) continue;

        final size = first['size'] is int ? first['size'] as int : 0;
        final br = first['br'] is int ? first['br'] as int : 0;
        return {
          'url': url,
          'size': size,
          'kbps': br > 0 ? br ~/ 1000 : 0,
          'level': first['level']?.toString(),
        };
      } catch (_) {
        // 试下一档
      }
    }
    return null;
  }

  bool _titleMatches(String a, String b) {
    final x = _normalize(a);
    final y = _normalize(b);
    if (x.isEmpty || y.isEmpty) return false;
    return x == y || x.contains(y) || y.contains(x);
  }

  bool _artistMatches(String kugouArtist, List<String> neteaseArtists) {
    // 酷狗多歌手用 、/&/, 分隔
    final wanted = kugouArtist
        .split(RegExp(r'[、,&/]'))
        .map(_normalize)
        .where((s) => s.isNotEmpty)
        .toSet();
    if (wanted.isEmpty) return false;
    for (final name in neteaseArtists) {
      final n = _normalize(name);
      if (wanted.contains(n)) return true;
      for (final w in wanted) {
        if (w.contains(n) || n.contains(w)) return true;
      }
    }
    return false;
  }

  String _normalize(String input) => input
      .toLowerCase()
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll(RegExp(r'[·・\-_—()（）\[\]【】]'), '');

  void dispose() => _client.close();
}

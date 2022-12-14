import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audio_tagger/audio_tagger.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_audio_query/flutter_audio_query.dart';
import 'package:http/http.dart';
import 'package:newpipeextractor_dart/utils/httpClient.dart';
import 'package:palette_generator/palette_generator.dart';
import 'package:songtube/internal/artwork_manager.dart';
import 'package:songtube/internal/cache_utils.dart';
import 'package:songtube/internal/global.dart';
import 'package:songtube/internal/models/colors_palette.dart';
import 'package:songtube/internal/models/download/download_info.dart';
import 'package:songtube/internal/models/song_item.dart';

class MediaUtils {

  static Future<void> fetchDeviceSongs(Function(SongItem) onUpdateTrigger) async {
    // New songs found on device
    List<SongInfo> userSongs = await FlutterAudioQuery()
      .getSongs(sortType: SongSortType.DISPLAY_NAME);
    // Cached Songs
    List<MediaItem> cachedSongs = fetchCachedSongsAsMediaItems();
    // Filter out non needed songs from this process
    // ignore: avoid_function_literals_in_foreach_calls
    cachedSongs.forEach((item) {
      if (userSongs.any((element) => element.filePath == item.id)) {
        userSongs.removeWhere((element) => element.filePath == item.id);
      }
    });
    // Build Thumbnails
    Stopwatch thumbnailsStopwatch = Stopwatch()..start();
    for (final song in userSongs) {
      await ArtworkManager.writeThumbnail(song.filePath!);
    }
    thumbnailsStopwatch.stop();
    if (kDebugMode) {
      print('Thumbnails spent a total of ${thumbnailsStopwatch.elapsed.inSeconds}s');
    }
    final List<SongItem> songs = [];
    for (final element in userSongs) {
      try {
        final song = await MediaUtils.convertToSongItem(element);
        songs.add(song);
        onUpdateTrigger(song);
      } catch (e) {
        if (kDebugMode) {
          print(e);
        }
      }
    }
    CacheUtils.cacheSongs = fetchCachedSongsAsSongItems()..addAll(songs);
  }

  static MediaItem fromMap(Map<String, dynamic> map) {
    return MediaItem(
      id: map['id'],
      title: map['title'],
      album: map['album'],
      artist: map['artist'],
      genre: map['genre'],
      duration: Duration(milliseconds: int.parse(map['duration'])),
      artUri: Uri.parse(map['artUri']),
      displayTitle: map['displayTitle'],
      displaySubtitle: map['displaySubtitle'],
      displayDescription: map['displayDescription'],
      extras: {
        'lastModified': map['lastModified'] == ''
          ? null : map['lastModified']
      }
    );
  }

  static Map<String, dynamic> toMap(MediaItem item) {
    return {
      'id': item.id,
      'title': item.title,
      'album': item.album,
      'artist': item.artist,
      'genre': item.genre,
      'duration': item.duration!.inMilliseconds.toString(),
      'artUri': item.artUri.toString(),
      'displayTitle': item.displayTitle,
      'displaySubtitle': item.displaySubtitle,
      'displayDescription': item.displayDescription,
      'lastModified': item.extras?['lastModified'] ?? ''
    };
  } 

  static List<MediaItem> fromMapList(List<dynamic> list) {
    return List<MediaItem>.generate(list.length, (index) {
      return fromMap(list[index]);
    });
  }

  static List<Map<String, dynamic>> toMapList(List<MediaItem> list) {
    return List<Map<String, dynamic>>.generate(list.length, (index) {
      return toMap(list[index]);
    });
  }

  // Convert any List<SongFile> to a List<MediaItem>
  static Future<SongItem> convertToSongItem(SongInfo element) async {
    int hours = 0;
    int minutes = 0;
    int? micros;
    List<String> parts = element.duration!.split(':');
    if (parts.length > 2) {
      hours = int.parse(parts[parts.length - 3]);
    }
    if (parts.length > 1) {
      minutes = int.parse(parts[parts.length - 2]);
    }
    micros = (double.parse(parts[parts.length - 1]) * 1000000).round();
    Duration duration = Duration(
      milliseconds: Duration(
        hours: hours, 
        minutes: minutes,
        microseconds: micros
      ).inMilliseconds
    );
    FileStat stats = await FileStat.stat(element.filePath!);
    PaletteGenerator palette;
    try {
      palette = await PaletteGenerator.fromImageProvider(FileImage(thumbnailFile(element.filePath!)));
    } catch (e) {
      await ArtworkManager.writeDefaultThumbnail(element.filePath!);
      palette = await PaletteGenerator.fromImageProvider(FileImage(thumbnailFile(element.filePath!)));
    }
    return SongItem(
      id: element.filePath!,
      modelId: element.id,
      title: element.title!,
      album: element.album,
      artist: element.artist,
      artworkPath: artworkFile(element.filePath!),
      thumbnailPath: thumbnailFile(element.filePath!),
      duration: duration,
      lastModified: stats.changed,
      palette: ColorsPalette(
        dominant: palette.dominantColor?.color,
        vibrant: palette.vibrantColor?.color,
      )
    );
  }

  static Future<SongItem> downloadToSongItem(DownloadInfo info, String path) async {
    Duration duration = Duration(
      seconds: info.duration
    );
    FileStat stats = await FileStat.stat(path);
    PaletteGenerator palette;
    await ArtworkManager.writeThumbnail(path);
    try {
      palette = await PaletteGenerator.fromImageProvider(FileImage(thumbnailFile(path)));
    } catch (e) {
      await ArtworkManager.writeDefaultThumbnail(path);
      palette = await PaletteGenerator.fromImageProvider(FileImage(thumbnailFile(path)));
    }
    return SongItem(
      id: path,
      modelId: info.tags.titleController.text,
      title: info.tags.titleController.text,
      album: info.tags.albumController.text,
      artist: info.tags.artistController.text,
      artworkPath: artworkFile(path),
      thumbnailPath: thumbnailFile(path),
      duration: duration,
      lastModified: stats.changed,
      palette: ColorsPalette(
        dominant: palette.dominantColor?.color,
        vibrant: palette.vibrantColor?.color,
      )
    );
  }

  static List<SongItem> fetchCachedSongsAsSongItems() {
    final songString = sharedPreferences.getString('deviceSongs');
    if (songString != null) {
      final List<dynamic> songsMap = jsonDecode(songString);
      final songs = List<SongItem>.generate(songsMap.length, (index) {
        return SongItem.fromMap(songsMap[index]);
      });
      return songs;
    } else {
      return [];
    }
  }

  static List<MediaItem> fetchCachedSongsAsMediaItems() {
    final items = fetchCachedSongsAsSongItems();
    return List<MediaItem>.generate(items.length, (index) => items[index].mediaItem);
  }

  static String removeToxicSymbols(String string) {
    return string
      .replaceAll('Container.', '')
      .replaceAll(r'\', '')
      .replaceAll('/', '')
      .replaceAll('*', '')
      .replaceAll('?', '')
      .replaceAll('"', '')
      .replaceAll('<', '')
      .replaceAll('>', '')
      .replaceAll('|', '');
  }

  static const _chars = 'AaBbCcDdEeFfGgHhIiJjKkLlMmNnOoPpQqRrSsTtUuVvWwXxYyZz1234567890';
  static const _letters = 'qwertyuiopasdfghjlcvbnm';
  static String getRandomString(int length) => String.fromCharCodes(Iterable.generate(
      length, (_) => _chars.codeUnitAt(Random().nextInt(_chars.length))));
  static String getRandomLetter() => String.fromCharCodes(Iterable.generate(
    1, (_) => _letters
    .codeUnitAt(Random().nextInt(_letters.length))
  ));

  static Future<int?> getContentSize(String url) async {
    try {
      var response = await head(Uri.parse(url), headers: const {}).timeout(const Duration(seconds: 3));
      final size = int.tryParse(response.headers['content-length']!);
      return size;
    } catch (_) {}
    return null;
  }

  

}
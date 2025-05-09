// lib/services/storage_service.dart

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/person_data.dart';

class StorageService {
  /// Load saved PersonData objects from SharedPreferences.
  Future<Map<String, PersonData>> loadKnownPersons() async {
    final prefs = await SharedPreferences.getInstance();
    final dataJson = prefs.getString('known_persons');
    if (dataJson == null) return {};
    final Map<String, dynamic> map = jsonDecode(dataJson);
    final result = <String, PersonData>{};
    map.forEach((name, jsonData) {
      result[name] = PersonData.fromJson(jsonData);
    });
    return result;
  }

  /// Save the current known persons map into SharedPreferences.
  Future<void> saveKnownPersons(Map<String, PersonData> persons) async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = persons.map((k, v) => MapEntry(k, v.toJson()));
    await prefs.setString('known_persons', jsonEncode(encoded));
  }

  /// Load thumbnail files for each person name (PNG) from app documents directory.
  Future<Map<String, Uint8List>> loadThumbnails(List<String> names) async {
    final dir = await getApplicationDocumentsDirectory();
    final result = <String, Uint8List>{};
    for (var name in names) {
      final file = File('${dir.path}/$name.png');
      if (await file.exists()) {
        result[name] = await file.readAsBytes();
      }
    }
    return result;
  }

  /// Save a thumbnail (PNG bytes) to a file named `$name.png`.
  Future<void> saveThumbnail(String name, Uint8List bytes) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$name.png');
    await file.writeAsBytes(bytes);
  }

  /// Delete the thumbnail file for a given name.
  Future<void> deleteThumbnail(String name) async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$name.png');
    if (await file.exists()) {
      await file.delete();
    }
  }
}

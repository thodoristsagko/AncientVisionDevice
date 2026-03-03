import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SiteService {
  static const _sitesKey = 'site_list';
  static const _activeKey = 'active_site';

  Future<List<String>> getSites() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_sitesKey);
    if (raw == null) return [];
    return List<String>.from(jsonDecode(raw));
  }

  Future<String> getActiveSite() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeKey) ?? '';
  }

  Future<void> addSite(String name) async {
    final sites = await getSites();
    if (sites.contains(name)) return;
    sites.add(name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sitesKey, jsonEncode(sites));
  }

  Future<void> setActiveSite(String name) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeKey, name);
  }

  Future<void> removeSite(String name) async {
    final sites = await getSites();
    sites.remove(name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_sitesKey, jsonEncode(sites));
    final active = await getActiveSite();
    if (active == name) await prefs.setString(_activeKey, '');
  }
}

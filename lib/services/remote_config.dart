import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// 远程配置服务 - 从 Supabase 获取最新 API 地址
/// iOS 过审后可随时更换接口地址，无需重新发版
class RemoteConfig {
  static RemoteConfig? _instance;
  static RemoteConfig get instance => _instance ??= RemoteConfig._();
  RemoteConfig._();

  // Supabase 配置（这个地址基本不会变）
  static const _supabaseUrl = 'https://qrwmylotazdvivhezajl.supabase.co';
  static const _supabaseAnonKey =
      'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InFyd215bG90YXpkdml2aGV6YWpsIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTEzNDg0MDQsImV4cCI6MjA2NjkyNDQwNH0.ogFTMnD_LMFb3L89RwHIL-xbSEwFMXIVlhkncpR6HBk';

  // 默认值（兜底）
  static const _defaultApiUrl = 'https://meet.f13f2f75.org';
  static const _legacyApiUrl = 'https://hui.up.railway.app';

  String _apiUrl = _defaultApiUrl;
  bool _loaded = false;
  String _source = 'default';

  String get apiUrl => _apiUrl;
  String get source => _source;
  String get sourceLabel {
    switch (_source) {
      case 'remote':
        return '数据库';
      case 'cache':
        return '本地缓存';
      default:
        return '内置默认';
    }
  }

  String? _tryNormalizeApiUrl(String value) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      return null;
    }

    late final String normalized;
    if (uri.scheme == 'ws') {
      normalized = uri.replace(scheme: 'http').toString();
    } else if (uri.scheme == 'wss') {
      normalized = uri.replace(scheme: 'https').toString();
    } else {
      normalized = uri.toString();
    }

    return normalized.endsWith('/') ? normalized.substring(0, normalized.length - 1) : normalized;
  }

  bool _isDeprecatedApiUrl(String? value) {
    if (value == null || value.isEmpty) {
      return false;
    }

    return value == _legacyApiUrl;
  }

  /// 初始化：优先从 Supabase 拉取最新配置，失败再用本地缓存，最后才用默认值
  Future<void> init({bool forceRefresh = false}) async {
    if (_loaded && !forceRefresh) return;

    final prefs = await SharedPreferences.getInstance();
    final rawCachedApiUrl = _tryNormalizeApiUrl(
      prefs.getString('remote_api_url') ?? '',
    );
    final cachedApiUrl = _isDeprecatedApiUrl(rawCachedApiUrl) ? null : rawCachedApiUrl;
    _apiUrl = _defaultApiUrl;
    _source = 'default';
    var remoteLoaded = false;

    try {
      final resp = await http.get(
        Uri.parse('$_supabaseUrl/rest/v1/app_config?select=key,value&order=key'),
        headers: {
          'apikey': _supabaseAnonKey,
          'Authorization': 'Bearer $_supabaseAnonKey',
        },
      ).timeout(const Duration(seconds: 5));

      if (resp.statusCode == 200) {
        final list = jsonDecode(resp.body) as List;
        String? remoteCurrent;

        for (final item in list) {
          final key = item['key'] as String;
          final value = item['value'] as String;
          if (key == 'api_url') remoteCurrent = value;
        }

        final normalizedRemote = _tryNormalizeApiUrl(remoteCurrent ?? '');
        if (normalizedRemote != null) {
          _apiUrl = normalizedRemote;
          _source = 'remote';
          remoteLoaded = true;
          await prefs.setString('remote_api_url', _apiUrl);
        }
      }
    } catch (_) {
      // 远程失败时，回退到本地缓存
    }

    if (!remoteLoaded) {
      _apiUrl = cachedApiUrl ?? _defaultApiUrl;
      _source = cachedApiUrl != null ? 'cache' : 'default';
    }

    _loaded = true;
  }

  Future<void> refresh() => init(forceRefresh: true);
}

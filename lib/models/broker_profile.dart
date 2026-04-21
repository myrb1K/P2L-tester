import 'dart:convert';

class BrokerProfile {
  String name;
  String broker;
  int port;
  String username;
  String password;
  bool useSsl;

  BrokerProfile({
    required this.name,
    required this.broker,
    this.port = 1883,
    this.username = '',
    this.password = '',
    this.useSsl = false,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'broker': broker,
        'port': port,
        'username': username,
        'password': password,
        'useSsl': useSsl,
      };

  factory BrokerProfile.fromJson(Map<String, dynamic> json) => BrokerProfile(
        name: json['name'] as String,
        broker: json['broker'] as String,
        port: json['port'] as int? ?? 1883,
        username: json['username'] as String? ?? '',
        password: json['password'] as String? ?? '',
        useSsl: json['useSsl'] as bool? ?? false,
      );

  static List<BrokerProfile> listFromJson(String jsonStr) {
    final list = jsonDecode(jsonStr) as List;
    return list.map((e) => BrokerProfile.fromJson(e as Map<String, dynamic>)).toList();
  }

  static String listToJson(List<BrokerProfile> profiles) {
    return jsonEncode(profiles.map((p) => p.toJson()).toList());
  }
}

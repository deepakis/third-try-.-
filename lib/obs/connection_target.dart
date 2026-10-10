/// Where the app looks for OBS, and the password it authenticates with.
///
/// OBS prints this as one line under a QR code in
/// **Tools → WebSocket Server Settings → Show Connect Info**, so the same string
/// is what an operator can read off the screen, what a phone camera can decode,
/// and what we can accept pasted into a field. obs-websocket 5.0.0 (Sept 2022)
/// settled on the URI form; anything older used the pipe form.
///
/// ```
/// obsws://192.168.1.20:4455/hunter2        obs-websocket 5.0.0 and later
/// obswebsocket|192.168.1.20:4455|hunter2   the pre-5.0.0 form
/// 192.168.1.20:4455                        what someone types by hand
/// 192.168.1.20                             port defaults to 4455
/// ```
class ConnectionTarget {
  const ConnectionTarget({
    required this.host,
    this.port = defaultPort,
    this.password = '',
  });

  /// obs-websocket's default port, and what OBS ships with.
  static const int defaultPort = 4455;

  final String host;
  final int port;
  final String password;

  /// The endpoint the client actually dials.
  Uri get uri => Uri(scheme: 'ws', host: host, port: port, path: '/');

  /// The line OBS shows (and encodes in its QR code).
  ///
  /// `obswss://` is the TLS form in the protocol, but OBS Studio's own server
  /// does not offer TLS, so we never emit it.
  String get pairingString => 'obsws://$host:$port/$password';

  /// Short form for buttons and status lines.
  String get label => '$host:$port';

  ConnectionTarget copyWith({String? host, int? port, String? password}) =>
      ConnectionTarget(
        host: host ?? this.host,
        port: port ?? this.port,
        password: password ?? this.password,
      );

  Map<String, dynamic> toJson() => {
    'host': host,
    'port': port,
    'password': password,
  };

  /// The stored form. Returns null for anything that isn't a usable endpoint, so
  /// a hand-edited or half-written file behaves like "nothing stored".
  static ConnectionTarget? fromJson(Object? json) {
    if (json is! Map) return null;
    final host = json['host'];
    if (host is! String || host.trim().isEmpty) return null;
    final port = json['port'];
    final password = json['password'];
    return ConnectionTarget(
      host: host.trim(),
      port: port is int && _portInRange(port) ? port : defaultPort,
      password: password is String ? password : '',
    );
  }

  /// Reads the line OBS shows, a QR payload, or something a human typed.
  ///
  /// Returns null when there is no usable host in it — a half-typed address, or
  /// prose pasted by mistake — and the caller says so rather than connecting to
  /// nonsense.
  static ConnectionTarget? parse(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    // Pasted out of a chat window, quotes and all.
    if (text.length >= 2 &&
        ((text.startsWith('"') && text.endsWith('"')) ||
            (text.startsWith("'") && text.endsWith("'")))) {
      text = text.substring(1, text.length - 1).trim();
    }
    if (text.isEmpty) return null;

    // The pre-5.0.0 QR payload: obswebsocket|host:port|password.
    if (text.toLowerCase().startsWith('$legacyScheme|')) {
      final parts = text.split('|');
      if (parts.length < 2) return null;
      final address = _splitHostPort(parts[1]);
      if (address == null) return null;
      return ConnectionTarget(
        host: address.$1,
        port: address.$2,
        password: parts.length > 2 ? parts[2] : '',
      );
    }

    final schemeLength = _schemeLength(text);
    if (schemeLength > 0) {
      final rest = text.substring(schemeLength);
      // Everything after the first slash is the password, taken verbatim: OBS
      // puts it in the URI path, and a password may hold a '/', '#' or '?' that
      // a real URI parser would read as a path separator or a fragment.
      final slash = rest.indexOf('/');
      final address = _splitHostPort(slash < 0 ? rest : rest.substring(0, slash));
      if (address == null) return null;
      return ConnectionTarget(
        host: address.$1,
        port: address.$2,
        password: slash < 0 ? '' : rest.substring(slash + 1),
      );
    }

    // Bare host, or host:port.
    final address = _splitHostPort(text);
    if (address == null) return null;
    return ConnectionTarget(host: address.$1, port: address.$2);
  }

  /// The pipe form's scheme word. Kept as a name so [parse] and the tests agree
  /// on the one string that means "this is the old format".
  static const String legacyScheme = 'obswebsocket';

  static const List<String> _schemes = [
    'obsws://',
    'obswss://',
    'ws://',
    'wss://',
  ];

  /// Length of the recognised scheme prefix, or 0 when there isn't one.
  static int _schemeLength(String text) {
    final lower = text.toLowerCase();
    for (final scheme in _schemes) {
      if (lower.startsWith(scheme)) return scheme.length;
    }
    return 0;
  }

  /// Splits `host`, `host:port` or `[::1]:port`, with the port defaulted.
  static (String, int)? _splitHostPort(String authority) {
    var text = authority.trim();
    while (text.startsWith('/')) {
      text = text.substring(1);
    }
    while (text.endsWith('/')) {
      text = text.substring(0, text.length - 1);
    }
    if (text.isEmpty) return null;

    // Bracketed IPv6: [fe80::1]:4455.
    if (text.startsWith('[')) {
      final close = text.indexOf(']');
      if (close <= 1) return null;
      final host = text.substring(1, close);
      final rest = text.substring(close + 1);
      if (rest.isEmpty) return (host, defaultPort);
      if (!rest.startsWith(':')) return null;
      final port = _port(rest.substring(1));
      return port == null ? null : (host, port);
    }

    final colon = text.lastIndexOf(':');
    if (colon < 0) {
      return _usableHost(text) ? (text, defaultPort) : null;
    }
    final host = text.substring(0, colon);
    final port = _port(text.substring(colon + 1));
    if (port == null || !_usableHost(host)) return null;
    return (host, port);
  }

  static int? _port(String text) {
    final port = int.tryParse(text.trim());
    return port != null && _portInRange(port) ? port : null;
  }

  static bool _portInRange(int port) => port > 0 && port <= 65535;

  /// A host is anything without whitespace in it — enough to reject a sentence
  /// pasted into the field, without pretending to validate DNS.
  static bool _usableHost(String host) {
    final trimmed = host.trim();
    return trimmed.isNotEmpty && !trimmed.contains(RegExp(r'\s'));
  }

  @override
  bool operator ==(Object other) =>
      other is ConnectionTarget &&
      other.host == host &&
      other.port == port &&
      other.password == password;

  @override
  int get hashCode => Object.hash(host, port, password);

  @override
  String toString() => pairingString;
}

import 'package:bcrypt/bcrypt.dart';
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:dotenv/dotenv.dart';
import 'package:mongo_dart/mongo_dart.dart';

import 'database.dart';

class AuthService {
  AuthService._();

  static final DotEnv _env = DotEnv(includePlatformEnvironment: true)..load();

  static String get _secret {
    final secret = _env['JWT_SECRET'];

    if (secret == null || secret.length < 32) {
      throw StateError(
        'JWT_SECRET must be at least 32 characters.',
      );
    }

    return secret;
  }

  static String get _issuer => _env['JWT_ISSUER'] ?? 'encatal-scheduler';

  static String hashPassword(String password) {
    return BCrypt.hashpw(
      password,
      BCrypt.gensalt(logRounds: 12),
    );
  }

  static bool verifyPassword(
    String password,
    String hash,
  ) {
    return BCrypt.checkpw(password, hash);
  }

  static String createToken(
    Map<String, dynamic> user,
  ) {
    final id = user['_id'] as ObjectId;

    final jwt = JWT(
      {
        'sub': id.oid,
        'role': user['role'],
      },
      issuer: _issuer,
      subject: id.oid,
    );

    return jwt.sign(
      SecretKey(_secret),
      expiresIn: const Duration(hours: 8),
    );
  }

  static Map<String, dynamic>? verifyToken(
    String token,
  ) {
    try {
      final jwt = JWT.verify(
        token,
        SecretKey(_secret),
        issuer: _issuer,
      );

      final payload = Map<String, dynamic>.from(jwt.payload as Map);

      if (payload['sub'] is! String) {
        return null;
      }

      return payload;
    } catch (_) {
      return null;
    }
  }

  static Future<Map<String, dynamic>?> authenticate({
    required String email,
    required String password,
  }) async {
    final users = await DatabaseService.collection('users');

    final user = await users.findOne(
      where.eq('email', email.trim().toLowerCase()),
    );

    if (user == null || user['active'] != true) {
      return null;
    }

    final hash = user['passwordHash'];

    if (hash is! String) return null;

    if (!verifyPassword(password, hash)) {
      return null;
    }

    return user;
  }

  static Future<Map<String, dynamic>?> userFromToken(
    String token,
  ) async {
    final payload = verifyToken(token);

    if (payload == null) return null;

    final id = payload['sub'];

    if (id is! String) return null;

    ObjectId objectId;

    try {
      objectId = ObjectId.fromHexString(id);
    } catch (_) {
      return null;
    }

    final users = await DatabaseService.collection('users');

    final user = await users.findOne(
      where.id(objectId),
    );

    if (user == null || user['active'] != true) {
      return null;
    }

    // Recheck the current database role.
    if (user['role'] != payload['role']) {
      return null;
    }

    return user;
  }

  static Map<String, dynamic> publicUser(
    Map<String, dynamic> user,
  ) {
    return {
      'id': (user['_id'] as ObjectId).oid,
      'name': user['name'],
      'email': user['email'],
      'role': user['role'],
    };
  }
}

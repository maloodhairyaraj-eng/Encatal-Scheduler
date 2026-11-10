import 'package:dotenv/dotenv.dart';
import 'package:mongo_dart/mongo_dart.dart';

class DatabaseService {
  DatabaseService._();

  static Db? _db;
  static Future<Db>? _connecting;

  static Future<Db> get database async {
    if (_db != null) return _db!;

    return _connecting ??= _connect();
  }

  static Future<Db> _connect() async {
    try {
      final env = DotEnv(includePlatformEnvironment: true)..load();

      final uri = env['MONGODB_URI'];
      final databaseName = env['MONGODB_DATABASE'] ?? 'encatal_scheduler';

      if (uri == null || uri.isEmpty) {
        throw StateError('MONGODB_URI is missing.');
      }

      final db = await Db.create(
        uri.endsWith('/') ? '$uri$databaseName' : '$uri/$databaseName',
      );

      await db.open();

      _db = db;
      print('Connected to MongoDB: $databaseName');

      return db;
    } catch (_) {
      _connecting = null;
      rethrow;
    }
  }

  static Future<DbCollection> collection(String name) async {
    final db = await database;
    return db.collection(name);
  }

  static Map<String, dynamic> toJson(
    Map<String, dynamic> document,
  ) {
    final result = Map<String, dynamic>.from(document);

    final id = result.remove('_id');

    if (id is ObjectId) {
      result['id'] = id.toHexString();
    }

    final createdAt = result['createdAt'];

    if (createdAt is DateTime) {
      result['createdAt'] = createdAt.toIso8601String();
    }

    return result;
  }
}

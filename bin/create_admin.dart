import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../lib/auth_service.dart';

Future<void> main() async {
  final env = DotEnv(includePlatformEnvironment: true)..load();

  final uri = env['MONGODB_URI'];
  final databaseName = env['MONGODB_DATABASE'] ?? 'encatal_scheduler';

  if (uri == null || uri.isEmpty) {
    stderr.writeln('MONGODB_URI is missing.');
    exitCode = 1;
    return;
  }

  stdout.write('Administrator name: ');
  final name = stdin.readLineSync()?.trim() ?? '';

  stdout.write('Administrator email: ');
  final email = stdin.readLineSync()?.trim().toLowerCase() ?? '';

  stdout.write('Administrator password: ');

  String password;
  final oldEchoMode = stdin.echoMode;

  try {
    stdin.echoMode = false;
    password = stdin.readLineSync() ?? '';
  } finally {
    stdin.echoMode = oldEchoMode;
    stdout.writeln();
  }

  if (name.isEmpty ||
      !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(email) ||
      password.length < 12) {
    stderr.writeln(
      'Enter a name, valid email, and a password '
      'containing at least 12 characters.',
    );
    exitCode = 1;
    return;
  }

  final db = await Db.create(
    uri.endsWith('/') ? '$uri$databaseName' : '$uri/$databaseName',
  );

  await db.open();

  try {
    final users = db.collection('users');

    // Initial setup only.
    final count = await users.count();

    if (count != 0) {
      stderr.writeln(
        'User accounts already exist. '
        'Initial administrator setup is disabled.',
      );
      exitCode = 1;
      return;
    }

    await users.createIndex(
      keys: {'email': 1},
      unique: true,
    );

    await users.insertOne({
      '_id': ObjectId(),
      'name': name,
      'email': email,
      'passwordHash': AuthService.hashPassword(password),
      'role': 'admin',
      'active': true,
      'createdAt': DateTime.now().toUtc(),
    });

    stdout.writeln(
      'Administrator created successfully.',
    );
  } finally {
    await db.close();
  }
}

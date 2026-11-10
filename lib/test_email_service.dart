import 'dart:io';

import 'package:dotenv/dotenv.dart';
import 'package:mailer/mailer.dart' as mailer;
import 'package:mailer/smtp_server.dart';

class TestEmailService {
  static final DotEnv _env = DotEnv(includePlatformEnvironment: true)..load();

  static String get testRecipient {
    final value = _env['TEST_DISPATCH_RECIPIENT']?.trim();

    if (value == null ||
        !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value)) {
      throw StateError('Test recipient is not configured');
    }

    return value;
  }

  static bool get enabled => _env['TEST_DISPATCH_ENABLED'] == 'true';

  static Future<void> send({
    required String subject,
    required String body,
    required List<int> attachmentBytes,
    required String filename,
  }) async {
    if (!enabled) {
      throw StateError('Test dispatch is disabled');
    }

    final host = _env['SMTP_HOST'];
    final username = _env['SMTP_USERNAME'];
    final password = _env['SMTP_PASSWORD'];
    final from = _env['SMTP_FROM'];

    if (host == null || username == null || password == null || from == null) {
      throw StateError('SMTP configuration is incomplete');
    }

    final port =
        int.tryParse(
          _env['SMTP_PORT'] ?? '587',
        ) ??
        587;

    final smtp = SmtpServer(
      host,
      port: port,
      username: username,
      password: password,
      ssl: _env['SMTP_USE_SSL'] == 'true',
      allowInsecure: false,
    );

    // Use a temporary attachment file for the SMTP library.
    final directory = await Directory.systemTemp.createTemp('encatal_');

    try {
      final file = File('${directory.path}/schedule.xlsx');
      await file.writeAsBytes(attachmentBytes, flush: true);

      final message = mailer.Message()
        ..from = mailer.Address(from, 'Encatal Scheduler TEST')
        ..recipients.add(testRecipient)
        ..subject = subject
        ..text = body
        ..attachments.add(
          mailer.FileAttachment(file)..fileName = filename,
        );

      await mailer.send(message, smtp);
    } finally {
      await directory.delete(recursive: true);
    }
  }
}

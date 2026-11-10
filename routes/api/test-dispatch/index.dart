import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../../../lib/auth_service.dart';
import '../../../lib/database.dart';
import '../../../lib/test_email_service.dart';
import '../../../lib/token_excel_service.dart';

Response fail(int status, String message) {
  return Response.json(
    statusCode: status,
    body: {
      'error': message,
    },
  );
}

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method == HttpMethod.get) {
    return _history(context);
  }

  if (context.request.method == HttpMethod.post) {
    return _dispatch(context);
  }

  return fail(405, 'Method not allowed');
}

Future<Map<String, dynamic>?> currentAdmin(
  RequestContext context,
) async {
  final authorization = context.request.headers['authorization'];

  if (authorization == null || !authorization.startsWith('Bearer ')) {
    return null;
  }

  final token = authorization.substring(7).trim();
  final user = await AuthService.userFromToken(token);

  if (user == null || user['role'] != 'admin') {
    return null;
  }

  return user;
}

Future<Response> _dispatch(RequestContext context) async {
  final admin = await currentAdmin(context);

  if (admin == null) {
    return fail(403, 'Administrator access required');
  }

  if (!TestEmailService.enabled) {
    return fail(403, 'Test dispatch is disabled');
  }

  Map<String, dynamic> body;

  try {
    body = Map<String, dynamic>.from(
      jsonDecode(await context.request.body()) as Map,
    );
  } catch (_) {
    return fail(400, 'Invalid request body');
  }

  final scheduleId = body['scheduleId'];
  final requestKey = body['requestKey'];

  if (scheduleId is! String ||
      requestKey is! String ||
      !RegExp(r'^[a-zA-Z0-9_-]{16,100}$').hasMatch(requestKey)) {
    return fail(400, 'Invalid schedule or request key');
  }

  final jobs = await DatabaseService.collection('dispatch_jobs');

  // This unique index should be created once during setup,
  // not on every request. See the setup instructions below.

  final existing = await jobs.findOne(
    where.eq('requestKey', requestKey),
  );

  if (existing != null) {
    return fail(409, 'Dispatch request already exists');
  }

  GeneratedScheduleExcel attachment;

  try {
    attachment = await TokenExcelService.generate(
      scheduleId: scheduleId,
    );
  } catch (_) {
    return fail(400, 'Unable to generate schedule attachment');
  }

  final recipient = TestEmailService.testRecipient;

  final schedules = await DatabaseService.collection('schedules');

  final schedule = await schedules.findOne(
    where.id(TokenExcelService.parseId(scheduleId)),
  );

  if (schedule == null || schedule['status'] != 'draft') {
    return fail(409, 'Expected a development draft');
  }

  final subject =
      '[TEST] Day Ahead Schedule - ${attachment.worksheetName} '
      '- ${schedule['scheduleDate']}';

  final message =
      'ENCATAL TEST DISPATCH - NOT AN OFFICIAL SUBMISSION\n\n'
      'Please find attached a test-generated day-ahead '
      'schedule for ${attachment.worksheetName}.\n\n'
      'This message is for internal verification only.\n\n'
      'Encatal Smart Scheduler';

  final now = DateTime.now().toUtc();
  final jobId = ObjectId();

  try {
    await jobs.insertOne({
      '_id': jobId,
      'requestKey': requestKey,
      'scheduleId': scheduleId,
      'scheduleRevision': attachment.revision,
      'mode': 'test',
      'recipient': recipient,
      'subject': subject,
      'body': message,
      'filename': attachment.filename,
      'attachmentBase64': base64Encode(attachment.bytes),
      'status': 'sending',
      'createdBy': (admin['_id'] as ObjectId).oid,
      'createdAt': now,
      'updatedAt': now,
    });
  } catch (_) {
    return fail(409, 'Unable to reserve dispatch request');
  }

  try {
    await TestEmailService.send(
      subject: subject,
      body: message,
      attachmentBytes: attachment.bytes,
      filename: attachment.filename,
    );

    await jobs.updateOne(
      where.id(jobId),
      modify.set('status', 'accepted').set('updatedAt', DateTime.now().toUtc()),
    );

    return Response.json(
      body: {
        'jobId': jobId.oid,
        'status': 'accepted',
        'recipient': recipient,
        'filename': attachment.filename,
        'message': 'SMTP server accepted the test email',
      },
    );
  } catch (_) {
    // A timeout or connection failure may have occurred
    // after the SMTP server accepted the message.
    // Do not retry automatically.
    await jobs.updateOne(
      where.id(jobId),
      modify
          .set('status', 'outcome_unknown')
          .set('updatedAt', DateTime.now().toUtc()),
    );

    return fail(
      502,
      'SMTP outcome unknown. Check the test mailbox '
      'and dispatch history before retrying.',
    );
  }
}

Future<Response> _history(RequestContext context) async {
  final admin = await currentAdmin(context);

  if (admin == null) {
    return fail(403, 'Administrator access required');
  }

  final jobs = await DatabaseService.collection('dispatch_jobs');

  final documents = await jobs.find(where.eq('mode', 'test')).toList();

  documents.sort((a, b) {
    final first = a['createdAt'] as DateTime;
    final second = b['createdAt'] as DateTime;
    return second.compareTo(first);
  });

  return Response.json(
    body: {
      'jobs': documents.take(50).map((job) {
        return {
          'id': (job['_id'] as ObjectId).oid,
          'scheduleId': job['scheduleId'],
          'status': job['status'],
          'recipient': job['recipient'],
          'filename': job['filename'],
          'createdAt': (job['createdAt'] as DateTime).toIso8601String(),
        };
      }).toList(),
    },
  );
}

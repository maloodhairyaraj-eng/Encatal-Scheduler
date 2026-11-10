import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../../../lib/database.dart';

Response fail(int code, String message) {
  return Response.json(
    statusCode: code,
    body: {'error': message},
  );
}

ObjectId? parseId(String? value) {
  if (value == null) return null;

  try {
    return ObjectId.fromHexString(value);
  } catch (_) {
    return null;
  }
}

bool validEmail(String email) {
  return RegExp(
    r'^[^\s@]+@[^\s@]+\.[^\s@]+$',
  ).hasMatch(email);
}

List<String>? parseEmails(dynamic value) {
  if (value is! List) return null;

  final emails = <String>[];

  for (final item in value) {
    if (item is! String) return null;

    final email = item.trim().toLowerCase();

    if (!validEmail(email)) return null;

    if (!emails.contains(email)) {
      emails.add(email);
    }
  }

  return emails;
}

Future<Response> onRequest(RequestContext context) async {
  switch (context.request.method) {
    case HttpMethod.get:
      return getProfile(context);

    case HttpMethod.put:
      return saveProfile(context);

    default:
      return fail(405, 'Method not allowed');
  }
}

Future<Response> getProfile(RequestContext context) async {
  try {
    final unitId = context.request.uri.queryParameters['unitId'];

    if (parseId(unitId) == null) {
      return fail(400, 'Invalid unit ID');
    }

    final collection = await DatabaseService.collection('email_profiles');

    final profile = await collection.findOne(
      where.eq('unitId', unitId),
    );

    if (profile == null) {
      return Response.json(
        body: {
          'profile': {
            'unitId': unitId,
            'to': <String>[],
            'cc': <String>[],
            'configured': false,
          },
        },
      );
    }

    return Response.json(
      body: {
        'profile': {
          'unitId': unitId,
          'to': profile['to'],
          'cc': profile['cc'],
          'configured': true,
        },
      },
    );
  } catch (error) {
    print('Email profile GET error: $error');
    return fail(500, 'Unable to load email profile');
  }
}

Future<Response> saveProfile(RequestContext context) async {
  try {
    final body = jsonDecode(
      await context.request.body(),
    );

    if (body is! Map<String, dynamic>) {
      return fail(400, 'Invalid request body');
    }

    final unitId = body['unitId'] as String?;
    final to = parseEmails(body['to']);
    final cc = parseEmails(body['cc']);

    if (parseId(unitId) == null || to == null || cc == null || to.isEmpty) {
      return fail(400, 'Invalid recipients or unit');
    }

    if (to.length > 20 || cc.length > 20) {
      return fail(400, 'Too many recipients');
    }

    final units = await DatabaseService.collection('scheduling_units');

    final unit = await units.findOne(
      where.id(parseId(unitId)!),
    );

    if (unit == null || unit['active'] != true) {
      return fail(404, 'Active scheduling unit not found');
    }

    final collection = await DatabaseService.collection('email_profiles');

    final existing = await collection.findOne(
      where.eq('unitId', unitId),
    );

    final now = DateTime.now().toUtc();

    if (existing == null) {
      await collection.insertOne({
        '_id': ObjectId(),
        'unitId': unitId,
        'to': to,
        'cc': cc,
        'createdAt': now,
        'updatedAt': now,
      });
    } else {
      await collection.updateOne(
        where.id(existing['_id'] as ObjectId),
        modify.set('to', to).set('cc', cc).set('updatedAt', now),
      );
    }

    return Response.json(
      body: {
        'message': 'Email profile saved',
        'profile': {
          'unitId': unitId,
          'to': to,
          'cc': cc,
          'configured': true,
        },
      },
    );
  } on FormatException {
    return fail(400, 'Invalid JSON');
  } catch (error) {
    print('Email profile save error: $error');
    return fail(500, 'Unable to save email profile');
  }
}

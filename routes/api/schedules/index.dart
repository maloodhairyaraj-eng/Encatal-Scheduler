import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../../../lib/database.dart';

Future<Response> onRequest(RequestContext context) async {
  switch (context.request.method) {
    case HttpMethod.get:
      return _listSchedules(context);
    case HttpMethod.post:
      return _createSchedule(context);
    case HttpMethod.put:
      return _saveSchedule(context);
    default:
      return Response.json(
        statusCode: 405,
        body: {'error': 'Method not allowed'},
      );
  }
}

Response failure(int code, String message) {
  return Response.json(
    statusCode: code,
    body: {'error': message},
  );
}

String? validDate(dynamic value) {
  if (value is! String || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }

  final parsed = DateTime.tryParse(value);
  if (parsed == null || parsed.toIso8601String().substring(0, 10) != value) {
    return null;
  }
  return value;
}

ObjectId? parseId(dynamic value) {
  if (value is! String) return null;
  try {
    return ObjectId.fromHexString(value);
  } catch (_) {
    return null;
  }
}

List<Map<String, dynamic>> blankBlocks() {
  return List.generate(
    96,
    (i) => {
      'block': i + 1,
      'quantumMw': 0.0,
    },
  );
}

List<Map<String, dynamic>>? validateBlocks(dynamic input) {
  if (input is! List || input.length != 96) return null;

  final result = <Map<String, dynamic>>[];

  for (var i = 0; i < 96; i++) {
    final item = input[i];
    if (item is! Map || item['block'] != i + 1 || item['quantumMw'] is! num) {
      return null;
    }

    final value = (item['quantumMw'] as num).toDouble();

    if (!value.isFinite || value < 0) return null;

    result.add({
      'block': i + 1,
      'quantumMw': value,
    });
  }

  return result;
}

Map<String, dynamic> scheduleJson(
  Map<String, dynamic> document,
) {
  final result = DatabaseService.toJson(document);

  for (final field in ['createdAt', 'updatedAt']) {
    if (result[field] is DateTime) {
      result[field] = (result[field] as DateTime).toIso8601String();
    }
  }

  return result;
}

Future<Response> _listSchedules(
  RequestContext context,
) async {
  try {
    final unitId = context.request.uri.queryParameters['unitId'];

    final collection = await DatabaseService.collection('schedules');

    final documents = unitId == null
        ? await collection.find().toList()
        : await collection.find(where.eq('unitId', unitId)).toList();

    documents.sort(
      (a, b) =>
          (b['scheduleDate'] as String).compareTo(a['scheduleDate'] as String),
    );

    return Response.json(
      body: {
        'schedules': documents.map(scheduleJson).toList(),
      },
    );
  } catch (error) {
    print('List schedules error: $error');
    return failure(500, 'Unable to load schedules');
  }
}

Future<Response> _createSchedule(
  RequestContext context,
) async {
  try {
    final body = jsonDecode(await context.request.body());

    if (body is! Map<String, dynamic>) {
      return failure(400, 'Invalid request body');
    }

    final companyId = body['companyId'];
    final unitId = body['unitId'];
    final date = validDate(body['scheduleDate']);

    final companyObjectId = parseId(companyId);
    final unitObjectId = parseId(unitId);

    if (companyObjectId == null || unitObjectId == null || date == null) {
      return failure(400, 'Invalid company, unit or date');
    }

    final companies = await DatabaseService.collection('companies');
    final units = await DatabaseService.collection('scheduling_units');

    final company = await companies.findOne(
      where.id(companyObjectId),
    );

    final unit = await units.findOne(
      where.id(unitObjectId),
    );

    if (company == null ||
        company['active'] != true ||
        unit == null ||
        unit['active'] != true ||
        unit['companyId'] != companyId) {
      return failure(400, 'Company or unit is not active');
    }

    final collection = await DatabaseService.collection('schedules');

    final existing = await collection.findOne(
      where.eq('unitId', unitId).eq('scheduleDate', date),
    );

    if (existing != null) {
      return failure(
        409,
        'A schedule already exists for this unit and date',
      );
    }

    List<Map<String, dynamic>> blocks = blankBlocks();
    String? sourceScheduleId;

    if (body['sourceScheduleId'] != null) {
      final sourceId = parseId(body['sourceScheduleId']);

      if (sourceId == null) {
        return failure(400, 'Invalid source schedule ID');
      }

      final source = await collection.findOne(
        where.id(sourceId),
      );

      if (source == null || source['unitId'] != unitId) {
        return failure(
          400,
          'Source schedule must belong to the same unit',
        );
      }

      if ((source['scheduleDate'] as String).compareTo(date) >= 0) {
        return failure(
          400,
          'Source schedule must be from an earlier date',
        );
      }

      final copied = validateBlocks(source['blocks']);

      if (copied == null) {
        return failure(400, 'Source schedule is invalid');
      }

      blocks = copied;
      sourceScheduleId = sourceId.toHexString();
    }

    final now = DateTime.now().toUtc();

    final schedule = <String, dynamic>{
      '_id': ObjectId(),
      'companyId': companyId,
      'unitId': unitId,
      'scheduleDate': date,
      'status': 'draft',
      'revision': 0,
      'sourceScheduleId': sourceScheduleId,
      'blocks': blocks,
      'createdAt': now,
      'updatedAt': now,
    };

    await collection.insertOne(schedule);

    return Response.json(
      statusCode: 201,
      body: {'schedule': scheduleJson(schedule)},
    );
  } on FormatException {
    return failure(400, 'Invalid JSON');
  } catch (error) {
    print('Create schedule error: $error');
    return failure(500, 'Unable to create schedule');
  }
}

Future<Response> _saveSchedule(
  RequestContext context,
) async {
  try {
    final body = jsonDecode(await context.request.body());

    if (body is! Map<String, dynamic>) {
      return failure(400, 'Invalid request body');
    }

    final id = parseId(body['id']);
    final blocks = validateBlocks(body['blocks']);
    final expectedRevision = body['revision'];

    if (id == null ||
        blocks == null ||
        expectedRevision is! int ||
        expectedRevision < 0) {
      return failure(400, 'Invalid schedule data');
    }

    final collection = await DatabaseService.collection('schedules');

    final result = await collection.findAndModify(
      query: where
          .id(id)
          .eq('status', 'draft')
          .eq('revision', expectedRevision),
      update: modify
          .set('blocks', blocks)
          .set('updatedAt', DateTime.now().toUtc())
          .inc('revision', 1),
      returnNew: true,
    );

    if (result == null) {
      return failure(
        409,
        'Schedule changed or is no longer editable. '
        'Reload before saving.',
      );
    }

    return Response.json(
      body: {
        'schedule': scheduleJson(result),
      },
    );
  } on FormatException {
    return failure(400, 'Invalid JSON');
  } catch (error) {
    print('Save schedule error: $error');
    return failure(500, 'Unable to save schedule');
  }
}

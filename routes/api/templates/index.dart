import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:excel/excel.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../../../lib/database.dart';

Response fail(int code, String message) {
  return Response.json(
    statusCode: code,
    body: {'error': message},
  );
}

ObjectId? objectId(dynamic value) {
  if (value is! String) return null;
  try {
    return ObjectId.fromHexString(value);
  } catch (_) {
    return null;
  }
}

Map<String, dynamic> publicTemplate(
  Map<String, dynamic> doc,
) {
  return {
    'unitId': doc['unitId'],
    'filename': doc['filename'],
    'sheetName': doc['sheetName'],
    'dateCell': doc['dateCell'],
    'revisionCell': doc['revisionCell'],
    'quantumColumn': doc['quantumColumn'],
    'startRow': doc['startRow'],
  };
}

Future<Response> onRequest(RequestContext context) async {
  switch (context.request.method) {
    case HttpMethod.get:
      return getTemplate(context);
    case HttpMethod.post:
      return uploadTemplate(context);
    default:
      return fail(405, 'Method not allowed');
  }
}

Future<Response> getTemplate(RequestContext context) async {
  try {
    final query = context.request.uri.queryParameters;
    final unitId = query['unitId'];

    if (objectId(unitId) == null) {
      return fail(400, 'Invalid unit ID');
    }

    final templates = await DatabaseService.collection('excel_templates');

    final template = await templates.findOne(
      where.eq('unitId', unitId),
    );

    if (template == null) {
      return fail(404, 'No template configured for this unit');
    }

    return Response.json(
      body: {
        'template': publicTemplate(template),
      },
    );
  } catch (e) {
    print('Template GET error: $e');
    return fail(500, 'Template operation failed');
  }
}

Future<Response> uploadTemplate(RequestContext context) async {
  try {
    final body = jsonDecode(await context.request.body());

    if (body is! Map<String, dynamic>) {
      return fail(400, 'Invalid request body');
    }

    final unitId = body['unitId'];
    final filename = body['filename'];
    final encoded = body['contentBase64'];
    final sheetName = body['sheetName'];
    final dateCell = body['dateCell'];
    final revisionCell = body['revisionCell'];
    final quantumColumn = body['quantumColumn'];
    final startRow = body['startRow'];

    if (objectId(unitId) == null ||
        filename is! String ||
        !filename.toLowerCase().endsWith('.xlsx') ||
        encoded is! String ||
        encoded.isEmpty ||
        sheetName is! String ||
        sheetName.isEmpty ||
        dateCell is! String ||
        revisionCell is! String ||
        quantumColumn is! String ||
        startRow is! int) {
      return fail(400, 'Missing or invalid template settings');
    }

    // Strict mapping for the first implementation.
    if (!RegExp(r'^[A-Z]{1,3}[1-9][0-9]*$').hasMatch(dateCell) ||
        !RegExp(r'^[A-Z]{1,3}[1-9][0-9]*$').hasMatch(revisionCell) ||
        !RegExp(r'^[A-Z]{1,3}$').hasMatch(quantumColumn) ||
        startRow < 1 ||
        startRow > 100000) {
      return fail(400, 'Invalid cell mapping');
    }

    if (encoded.length > 6500000) {
      return fail(413, 'Template exceeds size limit');
    }

    final units = await DatabaseService.collection('scheduling_units');

    final unit = await units.findOne(
      where.id(objectId(unitId)!),
    );

    if (unit == null) {
      return fail(404, 'Scheduling unit not found');
    }

    late List<int> bytes;
    try {
      bytes = base64Decode(encoded);
    } catch (_) {
      return fail(400, 'Invalid file encoding');
    }

    Excel workbook;

    try {
      workbook = Excel.decodeBytes(bytes);
    } catch (error, stackTrace) {
      print('EXCEL DECODE ERROR: $error');
      print(stackTrace);

      return fail(
        400,
        'Unable to read XLSX workbook: $error',
      );
    }

    final sheet = workbook.tables[sheetName];

    if (sheet == null) {
      return fail(400, 'Worksheet name not found');
    }

    if (sheet.maxRows < startRow + 95) {
      return fail(
        400,
        'Template does not contain all 96 block rows',
      );
    }

    final templates = await DatabaseService.collection('excel_templates');

    final document = <String, dynamic>{
      'unitId': unitId,
      'filename': filename,
      'sheetName': sheetName,
      'dateCell': dateCell,
      'revisionCell': revisionCell,
      'quantumColumn': quantumColumn,
      'startRow': startRow,
      'contentBase64': encoded,
      'updatedAt': DateTime.now().toUtc(),
    };

    final existing = await templates.findOne(
      where.eq('unitId', unitId),
    );

    if (existing == null) {
      await templates.insertOne({
        '_id': ObjectId(),
        ...document,
      });
    } else {
      await templates.updateOne(
        where.id(existing['_id'] as ObjectId),
        modify
            .set('unitId', unitId)
            .set('filename', filename)
            .set('sheetName', sheetName)
            .set('dateCell', dateCell)
            .set('revisionCell', revisionCell)
            .set('quantumColumn', quantumColumn)
            .set('startRow', startRow)
            .set('contentBase64', encoded)
            .set('updatedAt', DateTime.now().toUtc()),
      );
    }

    return Response.json(
      body: {
        'message': 'Template saved successfully',
        'template': publicTemplate(document),
      },
    );
  } catch (e) {
    print('Template upload error: $e');
    return fail(500, 'Unable to save template');
  }
}

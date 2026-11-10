import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_frog/dart_frog.dart';
import 'package:excel/excel.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../../../lib/database.dart';

Future<Response> onRequest(RequestContext context) async {
  switch (context.request.method) {
    case HttpMethod.get:
      return exportExcel(context);
    case HttpMethod.post:
      return importExcel(context);
    default:
      return Response.json(
        statusCode: 405,
        body: {'error': 'Method not allowed'},
      );
  }
}

Response errorResponse(int status, String message) {
  return Response.json(
    statusCode: status,
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

String safeFilename(String value) {
  return value
      .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
      .replaceAll(RegExp(r'_+'), '_');
}

String? validateDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    return null;
  }

  final parsed = DateTime.tryParse(value);

  if (parsed == null || parsed.toIso8601String().substring(0, 10) != value) {
    return null;
  }

  return value;
}

double? readNumber(Data? cell) {
  final value = cell?.value;

  if (value == null) return null;

  final text = value.toString().trim();

  // NumericCellValue.toString() is normally the numeric text.
  final parsed = double.tryParse(text);

  if (parsed == null || !parsed.isFinite || parsed < 0) {
    return null;
  }

  return parsed;
}

Future<Response> exportExcel(RequestContext context) async {
  try {
    final scheduleId = context.request.uri.queryParameters['scheduleId'];

    final id = parseId(scheduleId);

    if (id == null) {
      return errorResponse(400, 'Invalid schedule ID');
    }

    final schedules = await DatabaseService.collection('schedules');

    final schedule = await schedules.findOne(where.id(id));

    if (schedule == null) {
      return errorResponse(404, 'Schedule not found');
    }

    final rawBlocks = schedule['blocks'];

    if (rawBlocks is! List || rawBlocks.length != 96) {
      return errorResponse(400, 'Schedule must have 96 blocks');
    }

    final values = <double>[];

    for (var i = 0; i < 96; i++) {
      final block = rawBlocks[i];

      if (block is! Map ||
          block['block'] != i + 1 ||
          block['quantumMw'] is! num) {
        return errorResponse(
          400,
          'Invalid data at block ${i + 1}',
        );
      }

      final value = (block['quantumMw'] as num).toDouble();

      if (!value.isFinite || value < 0) {
        return errorResponse(
          400,
          'Invalid quantum at block ${i + 1}',
        );
      }

      values.add(value);
    }

    final companies = await DatabaseService.collection('companies');

    final units = await DatabaseService.collection('scheduling_units');

    final companyId = parseId(schedule['companyId'] as String?);
    final unitId = parseId(schedule['unitId'] as String?);

    if (companyId == null || unitId == null) {
      return errorResponse(400, 'Invalid company or unit');
    }

    final company = await companies.findOne(where.id(companyId));

    final unit = await units.findOne(where.id(unitId));

    if (company == null || unit == null) {
      return errorResponse(
        404,
        'Company or scheduling unit not found',
      );
    }

    final companyName = company['name'].toString();
    final unitName = unit['name'].toString();
    final date = schedule['scheduleDate'].toString();

    final excel = Excel.createExcel();

    final sheet = excel['Schedule'];

    sheet.appendRow([
      TextCellValue('ENCATAL - DAY AHEAD SCHEDULE'),
    ]);

    sheet.appendRow([
      TextCellValue('Company'),
      TextCellValue(companyName),
    ]);

    sheet.appendRow([
      TextCellValue('Scheduling Unit'),
      TextCellValue(unitName),
    ]);

    sheet.appendRow([
      TextCellValue('Schedule Date'),
      TextCellValue(date),
    ]);

    sheet.appendRow([
      TextCellValue('Status'),
      TextCellValue(schedule['status'].toString()),
    ]);

    sheet.appendRow([
      TextCellValue('Revision'),
      IntCellValue((schedule['revision'] as num).toInt()),
    ]);

    sheet.appendRow([]);

    sheet.appendRow([
      TextCellValue('Block'),
      TextCellValue('Start Time'),
      TextCellValue('End Time'),
      TextCellValue('Declared Quantum (MW)'),
    ]);

    for (var i = 0; i < 96; i++) {
      final startMinutes = i * 15;
      final endMinutes = (i + 1) * 15;

      String formatTime(int minutes) {
        final normalized = minutes % 1440;
        final hour = normalized ~/ 60;
        final minute = normalized % 60;

        return '${hour.toString().padLeft(2, '0')}:'
            '${minute.toString().padLeft(2, '0')}';
      }

      sheet.appendRow([
        IntCellValue(i + 1),
        TextCellValue(formatTime(startMinutes)),
        TextCellValue(formatTime(endMinutes)),
        DoubleCellValue(values[i]),
      ]);
    }

    if (excel.tables.containsKey('Sheet1')) {
      excel.delete('Sheet1');
    }

    final bytes = excel.encode();

    if (bytes == null) {
      return errorResponse(500, 'Excel generation failed');
    }

    final filename =
        '${date.replaceAll('-', '_')}_'
        '${safeFilename(companyName)}_'
        '${safeFilename(unitName)}.xlsx';

    return Response.json(
      body: {
        'filename': filename,
        'contentBase64': base64Encode(bytes),
      },
    );
  } catch (e) {
    print('Excel export error: $e');

    return errorResponse(500, 'Unable to export Excel');
  }
}

Future<Response> importExcel(RequestContext context) async {
  try {
    final body = jsonDecode(await context.request.body());

    if (body is! Map<String, dynamic>) {
      return errorResponse(400, 'Invalid request body');
    }

    final encoded = body['contentBase64'];

    if (encoded is! String || encoded.isEmpty) {
      return errorResponse(400, 'Excel file is required');
    }

    // Development limit: 5 MB encoded payload.
    if (encoded.length > 7000000) {
      return errorResponse(413, 'File is too large');
    }

    Uint8List bytes;

    try {
      bytes = base64Decode(encoded);
    } catch (_) {
      return errorResponse(400, 'Invalid Base64 data');
    }

    final excel = Excel.decodeBytes(bytes);

    final sheet = excel.tables['Schedule'];

    if (sheet == null) {
      return errorResponse(
        400,
        'Expected a worksheet named Schedule',
      );
    }

    // Standardized export:
    // Header is row 8; blocks occupy rows 9 through 104.
    final rows = sheet.rows;

    if (rows.length < 104) {
      return errorResponse(
        400,
        'Excel file does not contain 96 blocks',
      );
    }

    final values = <double>[];

    for (var i = 0; i < 96; i++) {
      final row = rows[i + 8];

      if (row.length < 4) {
        return errorResponse(
          400,
          'Missing quantum at block ${i + 1}',
        );
      }

      final blockNo = readNumber(row[0]);
      final quantum = readNumber(row[3]);

      if (blockNo != (i + 1).toDouble() || quantum == null) {
        return errorResponse(
          400,
          'Invalid data at block ${i + 1}',
        );
      }

      values.add(quantum);
    }

    return Response.json(
      body: {
        'message': 'Excel validated successfully',
        'values': values,
        'blockCount': values.length,
      },
    );
  } catch (e) {
    print('Excel import error: $e');

    return errorResponse(
      400,
      'Unable to read the Excel file',
    );
  }
}

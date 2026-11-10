import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';

import '../../../lib/token_excel_service.dart';

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: 405,
      body: {'error': 'Method not allowed'},
    );
  }

  final query = context.request.uri.queryParameters;
  final scheduleId = query['scheduleId'];
  final unitId = query['unitId'];

  if (scheduleId == null || unitId == null) {
    return Response.json(
      statusCode: 400,
      body: {'error': 'Schedule and unit IDs required'},
    );
  }

  try {
    final result = await TokenExcelService.generate(
      scheduleId: scheduleId,
      expectedUnitId: unitId,
    );

    return Response.json(
      body: {
        'filename': result.filename,
        'worksheetName': result.worksheetName,
        'blockCount': 96,
        'contentBase64': base64Encode(result.bytes),
      },
    );
  } on FormatException {
    return Response.json(
      statusCode: 400,
      body: {'error': 'Invalid identifier'},
    );
  } on StateError catch (error) {
    return Response.json(
      statusCode: 400,
      body: {'error': error.message},
    );
  } catch (_) {
    return Response.json(
      statusCode: 500,
      body: {'error': 'Excel generation failed'},
    );
  }
}

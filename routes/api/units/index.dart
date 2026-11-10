import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../../../lib/database.dart';

Future<Response> onRequest(RequestContext context) async {
  switch (context.request.method) {
    case HttpMethod.get:
      return _getUnits(context);

    case HttpMethod.post:
      return _createUnit(context);

    default:
      return Response(
        statusCode: 405,
        body: 'Method not allowed',
      );
  }
}

Future<Response> _getUnits(
  RequestContext context,
) async {
  try {
    final companyId = context.request.uri.queryParameters['companyId'];

    final collection = await DatabaseService.collection('scheduling_units');

    final documents = companyId == null
        ? await collection.find().toList()
        : await collection.find(where.eq('companyId', companyId)).toList();

    return Response.json(
      body: {
        'units': documents.map(DatabaseService.toJson).toList(),
      },
    );
  } catch (error) {
    print('Get units error: $error');

    return Response.json(
      statusCode: 500,
      body: {'error': 'Unable to load units'},
    );
  }
}

Future<Response> _createUnit(
  RequestContext context,
) async {
  try {
    final body = jsonDecode(
      await context.request.body(),
    );

    if (body is! Map<String, dynamic>) {
      return Response.json(
        statusCode: 400,
        body: {'error': 'Invalid request body'},
      );
    }

    final companyId = (body['companyId'] ?? '').toString();

    final name = (body['name'] ?? '').toString().trim();

    final capacity = body['capacityMw'];

    if (companyId.isEmpty ||
        name.isEmpty ||
        capacity is! num ||
        !capacity.isFinite ||
        capacity <= 0) {
      return Response.json(
        statusCode: 400,
        body: {'error': 'Invalid scheduling unit details'},
      );
    }

    ObjectId companyObjectId;

    try {
      companyObjectId = ObjectId.fromHexString(companyId);
    } catch (_) {
      return Response.json(
        statusCode: 400,
        body: {'error': 'Invalid company ID'},
      );
    }

    final companies = await DatabaseService.collection('companies');

    final company = await companies.findOne(
      where.id(companyObjectId),
    );

    if (company == null || company['active'] != true) {
      return Response.json(
        statusCode: 404,
        body: {'error': 'Active company not found'},
      );
    }

    final units = await DatabaseService.collection('scheduling_units');

    final existing = await units.findOne(
      where.eq('companyId', companyId).eq('name', name),
    );

    if (existing != null) {
      return Response.json(
        statusCode: 409,
        body: {'error': 'Scheduling unit already exists'},
      );
    }

    final unit = {
      '_id': ObjectId(),
      'companyId': companyId,
      'name': name,
      'capacityMw': capacity.toDouble(),
      'active': true,
      'createdAt': DateTime.now().toUtc(),
    };

    await units.insertOne(unit);

    return Response.json(
      statusCode: 201,
      body: {
        'message': 'Scheduling unit created',
        'unit': DatabaseService.toJson(unit),
      },
    );
  } on FormatException {
    return Response.json(
      statusCode: 400,
      body: {'error': 'Invalid JSON'},
    );
  } catch (error) {
    print('Create unit error: $error');

    return Response.json(
      statusCode: 500,
      body: {'error': 'Unable to create unit'},
    );
  }
}

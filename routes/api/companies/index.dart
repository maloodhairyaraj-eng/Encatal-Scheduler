import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../../../lib/database.dart';

Future<Response> onRequest(RequestContext context) async {
  switch (context.request.method) {
    case HttpMethod.get:
      return _getCompanies();

    case HttpMethod.post:
      return _createCompany(context);

    default:
      return Response(
        statusCode: 405,
        body: 'Method not allowed',
      );
  }
}

Future<Response> _getCompanies() async {
  try {
    final collection = await DatabaseService.collection('companies');

    final documents = await collection.find().toList();

    final companies = documents.map(DatabaseService.toJson).toList();

    return Response.json(
      body: {'companies': companies},
    );
  } catch (error) {
    print('Get companies error: $error');

    return Response.json(
      statusCode: 500,
      body: {'error': 'Unable to load companies'},
    );
  }
}

Future<Response> _createCompany(
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

    final name = (body['name'] ?? '').toString().trim();
    final code = (body['code'] ?? '').toString().trim().toUpperCase();

    if (name.isEmpty || code.isEmpty) {
      return Response.json(
        statusCode: 400,
        body: {'error': 'Name and code are required'},
      );
    }

    if (!RegExp(r'^[A-Z0-9_-]{2,20}$').hasMatch(code)) {
      return Response.json(
        statusCode: 400,
        body: {'error': 'Invalid company code'},
      );
    }

    final collection = await DatabaseService.collection('companies');

    final existing = await collection.findOne(
      where.eq('code', code),
    );

    if (existing != null) {
      return Response.json(
        statusCode: 409,
        body: {'error': 'Company code already exists'},
      );
    }

    final company = {
      '_id': ObjectId(),
      'name': name,
      'code': code,
      'active': true,
      'createdAt': DateTime.now().toUtc(),
    };

    await collection.insertOne(company);

    return Response.json(
      statusCode: 201,
      body: {
        'message': 'Company created successfully',
        'company': DatabaseService.toJson(company),
      },
    );
  } on FormatException {
    return Response.json(
      statusCode: 400,
      body: {'error': 'Invalid JSON'},
    );
  } catch (error) {
    print('Create company error: $error');

    return Response.json(
      statusCode: 500,
      body: {'error': 'Unable to create company'},
    );
  }
}

import 'dart:convert';

import 'package:dart_frog/dart_frog.dart';

import '../../../../lib/auth_service.dart';

Future<Response> onRequest(
  RequestContext context,
) async {
  if (context.request.method != HttpMethod.post) {
    return Response.json(
      statusCode: 405,
      body: {'error': 'Method not allowed'},
    );
  }

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

    final email = (body['email'] ?? '').toString().trim().toLowerCase();

    final password = (body['password'] ?? '').toString();

    if (email.isEmpty || password.isEmpty) {
      return Response.json(
        statusCode: 400,
        body: {'error': 'Email and password required'},
      );
    }

    final user = await AuthService.authenticate(
      email: email,
      password: password,
    );

    if (user == null) {
      return Response.json(
        statusCode: 401,
        body: {'error': 'Invalid email or password'},
      );
    }

    final token = AuthService.createToken(user);

    return Response.json(
      body: {
        'token': token,
        'tokenType': 'Bearer',
        'expiresIn': 28800,
        'user': AuthService.publicUser(user),
      },
    );
  } on FormatException {
    return Response.json(
      statusCode: 400,
      body: {'error': 'Invalid JSON'},
    );
  } catch (error) {
    // Do not log submitted passwords or tokens.
    return Response.json(
      statusCode: 500,
      body: {'error': 'Unable to complete login'},
    );
  }
}

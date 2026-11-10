import 'package:dart_frog/dart_frog.dart';

import '../../../../lib/auth_service.dart';

Future<Response> onRequest(
  RequestContext context,
) async {
  if (context.request.method != HttpMethod.get) {
    return Response.json(
      statusCode: 405,
      body: {'error': 'Method not allowed'},
    );
  }

  final authorization = context.request.headers['authorization'];

  if (authorization == null || !authorization.startsWith('Bearer ')) {
    return Response.json(
      statusCode: 401,
      body: {'error': 'Authentication required'},
    );
  }

  final token = authorization.substring(7).trim();

  final user = await AuthService.userFromToken(token);

  if (user == null) {
    return Response.json(
      statusCode: 401,
      body: {'error': 'Invalid or expired session'},
    );
  }

  return Response.json(
    body: {
      'user': AuthService.publicUser(user),
    },
  );
}

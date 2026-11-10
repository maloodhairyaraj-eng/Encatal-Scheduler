import 'package:dart_frog/dart_frog.dart';

import '../../lib/auth_service.dart';

Handler middleware(Handler handler) {
  return (context) async {
    final request = context.request;
    final method = request.method;
    final path = request.uri.path;

    // Browser preflight is handled by the existing
    // root CORS middleware.
    if (method == HttpMethod.options) {
      return handler(context);
    }

    // Employees must be able to log in without
    // already having an access token.
    if (path == '/api/auth/login' || path == '/api/auth/login/') {
      return handler(context);
    }

    final authorization = request.headers['authorization'];

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

    final role = user['role'] as String;

    if (!_isAllowed(role, path, method)) {
      return Response.json(
        statusCode: 403,
        body: {'error': 'Permission denied'},
      );
    }

    return handler(context);
  };
}

bool _isAllowed(
  String role,
  String path,
  HttpMethod method,
) {
  if (path == '/api/test-dispatch' || path == '/api/test-dispatch/') {
    return role == 'admin' &&
        (method == HttpMethod.get || method == HttpMethod.post);
  }

  if (path == '/api/auth/me' || path == '/api/auth/me/') {
    return method == HttpMethod.get;
  }

  // Administrators can manage all current modules.
  if (role == 'admin') {
    return true;
  }

  // All supported employees may view operational data.
  if (method == HttpMethod.get) {
    return role == 'scheduler' || role == 'approver';
  }

  // Schedulers can create and edit schedule drafts.
  if (role == 'scheduler') {
    if (path == '/api/schedules' || path == '/api/schedules/') {
      return method == HttpMethod.post || method == HttpMethod.put;
    }
  }

  // Template uploads, recipient changes, and other
  // modifications are administrator-only for now.
  return false;
}

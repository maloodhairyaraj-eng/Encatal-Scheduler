import 'package:dart_frog/dart_frog.dart';

Handler middleware(Handler handler) {
  return handler.use(
    (innerHandler) {
      return (context) async {
        final origin = context.request.headers['origin'];

        final isLocalDev =
            origin != null &&
            (origin.startsWith('http://localhost:') ||
                origin.startsWith('http://127.0.0.1:'));

        final headers = <String, String>{
          if (isLocalDev) 'Access-Control-Allow-Origin': origin,
          if (isLocalDev) 'Vary': 'Origin',
          'Access-Control-Allow-Methods': 'GET, POST, PUT, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type, Authorization',
        };

        if (context.request.method == HttpMethod.options) {
          return Response(
            statusCode: 204,
            headers: headers,
          );
        }

        final response = await innerHandler(context);

        return response.copyWith(
          headers: {
            ...response.headers,
            if (isLocalDev) ...headers,
          },
        );
      };
    },
  );
}

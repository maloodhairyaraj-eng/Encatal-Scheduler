import 'package:dart_frog/dart_frog.dart';
import 'package:mongo_dart/mongo_dart.dart';

import '../../../lib/database.dart';

Response fail(int code, String message) {
  return Response.json(
    statusCode: code,
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

Future<Response> onRequest(RequestContext context) async {
  if (context.request.method != HttpMethod.get) {
    return fail(405, 'Method not allowed');
  }

  try {
    final scheduleId = context.request.uri.queryParameters['scheduleId'];

    final id = parseId(scheduleId);

    if (id == null) {
      return fail(400, 'Invalid schedule ID');
    }

    final schedules = await DatabaseService.collection('schedules');

    final schedule = await schedules.findOne(where.id(id));

    if (schedule == null) {
      return fail(404, 'Schedule not found');
    }

    final unitId = schedule['unitId'] as String;
    final companyId = schedule['companyId'] as String;

    final units = await DatabaseService.collection('scheduling_units');
    final companies = await DatabaseService.collection('companies');
    final profiles = await DatabaseService.collection('email_profiles');
    final templates = await DatabaseService.collection('excel_templates');

    final unit = await units.findOne(
      where.id(parseId(unitId)!),
    );

    final company = await companies.findOne(
      where.id(parseId(companyId)!),
    );

    if (unit == null || company == null) {
      return fail(404, 'Company or unit not found');
    }

    final profile = await profiles.findOne(
      where.eq('unitId', unitId),
    );

    final template = await templates.findOne(
      where.eq('unitId', unitId),
    );

    final unitName = unit['name'].toString();
    final companyName = company['name'].toString();
    final date = schedule['scheduleDate'].toString();

    final parts = date.split('-');
    if (parts.length != 3) {
      return fail(400, 'Invalid schedule date');
    }

    final formattedDate = '${parts[2]}-${parts[1]}-${parts[0]}';

    final to = List<String>.from(
      profile?['to'] as List? ?? [],
    );

    final cc = List<String>.from(
      profile?['cc'] as List? ?? [],
    );

    final blocks = schedule['blocks'];

    final blocksValid =
        blocks is List &&
        blocks.length == 96 &&
        List.generate(96, (i) => i).every((i) {
          final block = blocks[i];

          if (block is! Map ||
              block['block'] != i + 1 ||
              block['quantumMw'] is! num) {
            return false;
          }

          final value = (block['quantumMw'] as num).toDouble();

          return value.isFinite && value >= 0;
        });

    final checks = {
      'recipientsConfigured': to.isNotEmpty,
      'templateConfigured': template != null,
      'blocksValid': blocksValid,
      'unitActive': unit['active'] == true,
      'companyActive': company['active'] == true,
    };

    final readyForPreview = checks.values.every((value) => value);

    final subject = 'Day Ahead Schedule - $unitName - $formattedDate';

    final body =
        'Dear Sir/Madam,\n\n'
        'Please find attached the day-ahead schedule '
        'for $unitName for $formattedDate.\n\n'
        'Kindly acknowledge receipt.\n\n'
        'Regards,\n'
        'Encatal Scheduling Team';

    final filename = '$formattedDate Day AHEAD schedule for $unitName.xlsx';

    return Response.json(
      body: {
        'scheduleId': scheduleId,
        'company': companyName,
        'unit': unitName,
        'scheduleDate': date,
        'scheduleStatus': schedule['status'],
        'revision': schedule['revision'] ?? 0,
        'to': to,
        'cc': cc,
        'subject': subject,
        'body': body,
        'attachmentFilename': filename,
        'checks': checks,
        'readyForPreview': readyForPreview,
        'canDispatch': false,
        'note':
            'Preview only. Approval and email sending '
            'are not implemented yet.',
      },
    );
  } catch (error) {
    print('Dispatch preview error: $error');
    return fail(500, 'Unable to generate preview');
  }
}

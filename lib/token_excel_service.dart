import 'dart:convert';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:mongo_dart/mongo_dart.dart';

import 'database.dart';

class GeneratedScheduleExcel {
  final String filename;
  final String worksheetName;
  final Uint8List bytes;
  final int revision;

  const GeneratedScheduleExcel({
    required this.filename,
    required this.worksheetName,
    required this.bytes,
    required this.revision,
  });
}

class TokenExcelService {
  static ObjectId parseId(String value) {
    try {
      return ObjectId.fromHexString(value);
    } catch (_) {
      throw FormatException('Invalid MongoDB ID');
    }
  }

  static String formatTime(int minutes) {
    final value = minutes % 1440;
    final hour = value ~/ 60;
    final minute = value % 60;

    return '${hour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}';
  }

  static String sheetName(String title) {
    var name = title.replaceAll(RegExp(r'[\[\]:*?/\\]'), '_').trim();

    if (name.isEmpty) name = 'Schedule';

    return name.length > 31 ? name.substring(0, 31) : name;
  }

  static String filenamePart(String value) {
    return value.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_').trim();
  }

  static String cellText(Data cell) {
    return cell.value?.toString().trim() ?? '';
  }

  static double? numericValue(CellValue? value) {
    if (value is DoubleCellValue) return value.value;
    if (value is IntCellValue) {
      return value.value.toDouble();
    }
    return null;
  }

  static Future<GeneratedScheduleExcel> generate({
    required String scheduleId,
    String? expectedUnitId,
  }) async {
    final schedules = await DatabaseService.collection('schedules');

    final schedule = await schedules.findOne(
      where.id(parseId(scheduleId)),
    );

    if (schedule == null) {
      throw StateError('Schedule not found');
    }

    final unitId = schedule['unitId'] as String;

    if (expectedUnitId != null && expectedUnitId != unitId) {
      throw StateError('Schedule belongs to another unit');
    }

    final units = await DatabaseService.collection('scheduling_units');

    final unit = await units.findOne(
      where.id(parseId(unitId)),
    );

    if (unit == null || unit['active'] != true) {
      throw StateError('Active scheduling unit not found');
    }

    final templates = await DatabaseService.collection('excel_templates');

    final template = await templates.findOne(
      where.eq('unitId', unitId),
    );

    if (template == null) {
      throw StateError('Excel template not configured');
    }

    final rawBlocks = schedule['blocks'];

    if (rawBlocks is! List || rawBlocks.length != 96) {
      throw StateError('Exactly 96 blocks are required');
    }

    final values = <double>[];

    for (var i = 0; i < 96; i++) {
      final block = rawBlocks[i];

      if (block is! Map ||
          block['block'] != i + 1 ||
          block['quantumMw'] is! num) {
        throw StateError('Invalid block ${i + 1}');
      }

      final value = (block['quantumMw'] as num).toDouble();

      if (!value.isFinite || value < 0) {
        throw StateError('Invalid quantum at block ${i + 1}');
      }

      values.add(value);
    }

    final encoded = template['contentBase64'];

    if (encoded is! String) {
      throw StateError('Template content missing');
    }

    final workbook = Excel.decodeBytes(
      base64Decode(encoded),
    );

    final originalSheetName = template['sheetName'] as String;
    final sheet = workbook.tables[originalSheetName];

    if (sheet == null) {
      throw StateError('Configured worksheet not found');
    }

    final title = unit['name'].toString();
    final date = schedule['scheduleDate'] as String;

    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date)) {
      throw StateError('Invalid schedule date');
    }

    final parts = date.split('-');
    final formattedDate = '${parts[2]}-${parts[1]}-${parts[0]}';

    // Replace metadata tokens.
    for (var r = 0; r < sheet.maxRows; r++) {
      for (var c = 0; c < sheet.maxColumns; c++) {
        final cell = sheet.cell(
          CellIndex.indexByColumnRow(
            columnIndex: c,
            rowIndex: r,
          ),
        );

        final token = cellText(cell);

        if (token == '{date}') {
          cell.value = TextCellValue(formattedDate);
        } else if (token == '{title}') {
          cell.value = TextCellValue(title);
        } else if (token == '{reason}') {
          cell.value = TextCellValue('Initial Submission');
        }
      }
    }

    // Locate each block by its token in column A.
    final seen = <int>{};
    final blockRows = <int, int>{};

    for (var r = 0; r < sheet.maxRows; r++) {
      final blockCell = sheet.cell(
        CellIndex.indexByColumnRow(
          columnIndex: 0,
          rowIndex: r,
        ),
      );

      final match = RegExp(r'^\{B(\d+)\}$').firstMatch(cellText(blockCell));

      if (match == null) continue;

      final blockNo = int.parse(match.group(1)!);

      if (blockNo < 1 || blockNo > 96 || !seen.add(blockNo)) {
        throw StateError(
          'Invalid or duplicate block token: $blockNo',
        );
      }

      blockRows[blockNo] = r;

      final start = (blockNo - 1) * 15;
      final end = blockNo * 15;

      sheet
          .cell(
            CellIndex.indexByColumnRow(
              columnIndex: 0,
              rowIndex: r,
            ),
          )
          .value = IntCellValue(
        blockNo,
      );

      sheet
          .cell(
            CellIndex.indexByColumnRow(
              columnIndex: 1,
              rowIndex: r,
            ),
          )
          .value = TextCellValue(
        formatTime(start),
      );

      sheet
          .cell(
            CellIndex.indexByColumnRow(
              columnIndex: 2,
              rowIndex: r,
            ),
          )
          .value = TextCellValue(
        formatTime(end),
      );

      sheet
          .cell(
            CellIndex.indexByColumnRow(
              columnIndex: 3,
              rowIndex: r,
            ),
          )
          .value = DoubleCellValue(
        values[blockNo - 1],
      );
    }

    if (seen.length != 96) {
      throw StateError(
        'Template contains ${seen.length}/96 block tokens',
      );
    }

    final newSheetName = sheetName(title);

    if (newSheetName != originalSheetName) {
      if (workbook.tables.containsKey(newSheetName)) {
        throw StateError('Worksheet name already exists');
      }

      workbook.rename(originalSheetName, newSheetName);
    }

    final output = workbook.encode();

    if (output == null) {
      throw StateError('Excel encoding failed');
    }

    // Verify the encoded workbook.
    final verified = Excel.decodeBytes(output);
    final resultSheet = verified.tables[newSheetName];

    if (resultSheet == null) {
      throw StateError('Generated worksheet missing');
    }

    for (var blockNo = 1; blockNo <= 96; blockNo++) {
      final row = blockRows[blockNo]!;

      final numberCell = resultSheet.cell(
        CellIndex.indexByColumnRow(
          columnIndex: 0,
          rowIndex: row,
        ),
      );

      final quantumCell = resultSheet.cell(
        CellIndex.indexByColumnRow(
          columnIndex: 3,
          rowIndex: row,
        ),
      );

      final number = numericValue(numberCell.value);
      final quantum = numericValue(quantumCell.value);

      if (number != blockNo.toDouble() ||
          quantum == null ||
          (quantum - values[blockNo - 1]).abs() > 0.0000001) {
        throw StateError(
          'Excel verification failed at block $blockNo',
        );
      }
    }

    final filename =
        '$formattedDate Day AHEAD schedule for '
        '${filenamePart(title)}.xlsx';

    return GeneratedScheduleExcel(
      filename: filename,
      worksheetName: newSheetName,
      bytes: Uint8List.fromList(output),
      revision: (schedule['revision'] as num?)?.toInt() ?? 0,
    );
  }
}

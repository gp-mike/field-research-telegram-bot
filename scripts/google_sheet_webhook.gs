/**
 * Google Apps Script webhook for Field Research bot.
 *
 * 1) Create new Apps Script project.
 * 2) Paste this file.
 * 3) Set SPREADSHEET_ID and WEBHOOK_TOKEN.
 * 4) Optional: set DRIVE_FOLDER_ID (for uploaded photos).
 * 5) Deploy -> Web app:
 *    - Execute as: Me
 *    - Who has access: Anyone
 * 6) Put web app URL into GOOGLE_SHEETS_WEBHOOK_URL in bot .env
 */

const SPREADSHEET_ID = 'PUT_YOUR_SPREADSHEET_ID_HERE';
const SHEET_NAME = 'Reports';
const WEBHOOK_TOKEN = 'PUT_YOUR_WEBHOOK_TOKEN_HERE';

// Optional: folder where photos will be uploaded. Empty string = My Drive root.
const DRIVE_FOLDER_ID = '';
const MAKE_DRIVE_FILES_PUBLIC = true;

const HEADERS = [
  'received_at',
  'report_id',
  'created_at_utc',
  'username',
  'title',
  'restaurant_name',
  'city',
  'contact_name',
  'contact_role',
  'meeting_result',
  'interest_level',
  'interest_score_1_5',
  'manager_action_priority',
  'decision_drivers',
  'main_objections',
  'main_risks',
  'requested_features',
  'questions_from_prospect',
  'next_steps',
  'summary_for_team',
  'short_confirmation_ru',
  'notes',
  'transcript_raw',
  'photo_count',
  'photo_links',
  'photo_drive_links',
  'photo_paths',
  'photo_file_ids',
  'photo_drive_file_ids',
  'photo_drive_errors',
  'voice_count',
  'voice_file_ids',
  'ai_summary_json',
  'full_report_json',
];

function doPost(e) {
  try {
    const body = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    if (WEBHOOK_TOKEN && body.token !== WEBHOOK_TOKEN) {
      return jsonResponse({ ok: false, error: 'unauthorized' }, 403);
    }

    const ss = SpreadsheetApp.openById(SPREADSHEET_ID);
    const sheet = getOrCreateSheet(ss, SHEET_NAME);

    if (body.action === 'reset_sheet') {
      resetSheet(sheet);
      return jsonResponse({ ok: true, action: 'reset_sheet' }, 200);
    }

    if (!body.report) {
      return jsonResponse({ ok: false, error: 'missing report' }, 400);
    }

    ensureHeader(sheet);

    const report = body.report || {};
    const reportId = clean(report.report_id);
    const attachmentsRaw = Array.isArray(report.attachments)
      ? report.attachments
      : [];
    const ai = parseAiSummary(report.ai_summary);

    const photoItems = attachmentsRaw.filter(
      (a) => a && a.attachment_type === 'photo'
    );
    const voiceItems = attachmentsRaw.filter(
      (a) => a && a.attachment_type === 'voice'
    );

    const photoPaths = photoItems
      .map((a) => clean(a.stored_path))
      .filter(Boolean);
    const fallbackPhotoLinks = photoPaths.map((p) => (p ? `file://${p}` : ''));
    const photoFileIds = photoItems
      .map((a) => clean(a.telegram_file_id))
      .filter(Boolean);
    const voiceFileIds = voiceItems
      .map((a) => clean(a.telegram_file_id))
      .filter(Boolean);

    const driveUpload = uploadPhotosToDrive(photoItems, reportId);
    const finalPhotoLinks =
      driveUpload.links.length > 0 ? driveUpload.links : fallbackPhotoLinks;

    const reportForStorage = sanitizeReportForStorage(report);

    const row = [
      new Date(),
      reportId,
      clean(report.created_at),
      clean(report.username),
      clean(report.title),
      clean(ai.restaurant_name),
      clean(ai.city),
      clean(ai.contact_name),
      clean(ai.contact_role),
      clean(ai.meeting_result),
      clean(ai.interest_level),
      toIntOrZero(ai.interest_score_1_5),
      clean(ai.manager_action_priority),
      joinList(ai.decision_drivers),
      joinList(ai.main_objections),
      joinList(ai.main_risks),
      joinList(ai.requested_features),
      joinList(ai.questions_from_prospect),
      joinList(ai.next_steps),
      joinList(ai.summary_for_team),
      clean(ai.short_confirmation_ru),
      clean(report.notes),
      clean(report.transcript),
      photoItems.length,
      finalPhotoLinks.join('\n'),
      driveUpload.links.join('\n'),
      photoPaths.join('\n'),
      photoFileIds.join('\n'),
      driveUpload.fileIds.join('\n'),
      driveUpload.errors.join('\n'),
      voiceItems.length,
      voiceFileIds.join('\n'),
      stringify(ai),
      stringify(reportForStorage),
    ];

    const mode = upsertReportRow(sheet, reportId, row);
    return jsonResponse({ ok: true, report_id: reportId, mode: mode }, 200);
  } catch (err) {
    return jsonResponse({ ok: false, error: String(err) }, 500);
  }
}

function sanitizeReportForStorage(report) {
  const copy = JSON.parse(JSON.stringify(report || {}));
  if (Array.isArray(copy.attachments)) {
    copy.attachments = copy.attachments.map((item) => {
      if (!item || typeof item !== 'object') return item;
      const cloned = Object.assign({}, item);
      delete cloned.content_base64;
      return cloned;
    });
  }
  return copy;
}

function upsertReportRow(sheet, reportId, row) {
  if (!reportId) {
    sheet.appendRow(row);
    return 'inserted_no_report_id';
  }

  const rowIndex = findReportRowIndex(sheet, reportId);
  if (rowIndex > 0) {
    sheet.getRange(rowIndex, 1, 1, row.length).setValues([row]);
    return 'updated';
  }

  sheet.appendRow(row);
  return 'inserted';
}

function findReportRowIndex(sheet, reportId) {
  const lastRow = sheet.getLastRow();
  if (lastRow < 2) return 0;

  const values = sheet.getRange(2, 2, lastRow - 1, 1).getValues();
  for (let i = 0; i < values.length; i += 1) {
    if (clean(values[i][0]) === reportId) {
      return i + 2;
    }
  }
  return 0;
}

function uploadPhotosToDrive(photoItems, reportId) {
  const result = { links: [], fileIds: [], errors: [] };
  if (!Array.isArray(photoItems) || photoItems.length === 0) return result;

  const folder = resolveDriveFolder();
  for (let i = 0; i < photoItems.length; i += 1) {
    const item = photoItems[i] || {};
    const maybeLink = clean(item.drive_url);
    const maybeId = clean(item.drive_file_id);
    if (maybeLink) {
      result.links.push(maybeLink);
      if (maybeId) result.fileIds.push(maybeId);
      continue;
    }

    const base64 = clean(item.content_base64);
    if (!base64) {
      result.errors.push(`photo_${i + 1}: missing content_base64`);
      continue;
    }

    try {
      const mime = clean(item.mime_type) || 'image/jpeg';
      const filename =
        clean(item.filename) || buildPhotoFilename(reportId, i, mime);
      const bytes = Utilities.base64Decode(base64);
      const blob = Utilities.newBlob(bytes, mime, filename);

      const file = folder ? folder.createFile(blob) : DriveApp.createFile(blob);
      if (MAKE_DRIVE_FILES_PUBLIC) {
        try {
          file.setSharing(
            DriveApp.Access.ANYONE_WITH_LINK,
            DriveApp.Permission.VIEW
          );
        } catch (shareErr) {
          result.errors.push(
            `photo_${i + 1}: share_failed: ${String(shareErr)}`
          );
        }
      }

      const fileId = file.getId();
      result.fileIds.push(fileId);
      result.links.push(`https://drive.google.com/file/d/${fileId}/view`);
    } catch (err) {
      result.errors.push(`photo_${i + 1}: upload_failed: ${String(err)}`);
    }
  }

  return result;
}

function resolveDriveFolder() {
  const id = clean(DRIVE_FOLDER_ID);
  if (!id) return null;
  try {
    return DriveApp.getFolderById(id);
  } catch (err) {
    return null;
  }
}

function buildPhotoFilename(reportId, index, mime) {
  const safeReportId = clean(reportId) || 'report';
  const ext = extensionFromMime(mime);
  return `${safeReportId}_photo_${index + 1}.${ext}`;
}

function extensionFromMime(mime) {
  const m = clean(mime).toLowerCase();
  if (m.indexOf('png') !== -1) return 'png';
  if (m.indexOf('webp') !== -1) return 'webp';
  if (m.indexOf('gif') !== -1) return 'gif';
  if (m.indexOf('heic') !== -1) return 'heic';
  return 'jpg';
}

function parseAiSummary(raw) {
  if (raw && typeof raw === 'object') return raw;
  if (typeof raw !== 'string') return {};

  const s = raw.trim();
  if (!s) return {};

  const candidates = [s];
  if (s.startsWith('```')) {
    candidates.push(s.replace(/^```(?:json)?\s*/i, '').replace(/\s*```$/, ''));
  }
  const i = s.indexOf('{');
  const j = s.lastIndexOf('}');
  if (i !== -1 && j !== -1 && j > i) {
    candidates.push(s.slice(i, j + 1));
  }

  for (let idx = 0; idx < candidates.length; idx += 1) {
    try {
      return JSON.parse(candidates[idx]);
    } catch (err) {
      // continue
    }
  }
  return {};
}

function ensureHeader(sheet) {
  const lastRow = sheet.getLastRow();
  if (lastRow <= 0) {
    sheet.appendRow(HEADERS);
    sheet.setFrozenRows(1);
    return;
  }

  const width = Math.max(sheet.getLastColumn(), HEADERS.length);
  const current = sheet.getRange(1, 1, 1, width).getValues()[0];
  const same =
    current.slice(0, HEADERS.length).join('||') === HEADERS.join('||');
  if (!same) {
    resetSheet(sheet);
  }
}

function resetSheet(sheet) {
  sheet.clear();
  sheet.getRange(1, 1, 1, HEADERS.length).setValues([HEADERS]);
  sheet.setFrozenRows(1);
}

function clean(v) {
  if (v === null || v === undefined) return '';
  return String(v).trim();
}

function joinList(v) {
  if (!Array.isArray(v) || v.length === 0) return 'Нет данных';
  const cleaned = v
    .map((x) => clean(x))
    .filter(Boolean);
  if (cleaned.length === 0) return 'Нет данных';
  return cleaned.join('\n');
}

function toIntOrZero(v) {
  const n = Number(v);
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.round(n));
}

function stringify(v) {
  try {
    return JSON.stringify(v || {});
  } catch (err) {
    return '{}';
  }
}

function getOrCreateSheet(ss, name) {
  let sh = ss.getSheetByName(name);
  if (!sh) sh = ss.insertSheet(name);
  return sh;
}

function jsonResponse(obj, statusCode) {
  const out = ContentService.createTextOutput(JSON.stringify(obj));
  out.setMimeType(ContentService.MimeType.JSON);
  return out;
}

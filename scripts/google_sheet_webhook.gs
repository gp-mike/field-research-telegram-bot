/**
 * Google Apps Script webhook for Field Research bot.
 *
 * 1) Create new Apps Script project.
 * 2) Paste this file.
 * 3) Set SPREADSHEET_ID and WEBHOOK_TOKEN.
 * 4) Deploy -> Web app:
 *    - Execute as: Me
 *    - Who has access: Anyone
 * 5) Put web app URL into GOOGLE_SHEETS_WEBHOOK_URL in bot .env
 */

const SPREADSHEET_ID = 'PUT_YOUR_SPREADSHEET_ID_HERE';
const SHEET_NAME = 'Reports';
const WEBHOOK_TOKEN = 'PUT_YOUR_WEBHOOK_TOKEN_HERE';

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
  'photo_paths',
  'photo_file_ids',
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

    const report = body.report;
    const attachments = Array.isArray(report.attachments) ? report.attachments : [];
    const ai = parseAiSummary(report.ai_summary);

    const photoItems = attachments.filter((a) => a && a.attachment_type === 'photo');
    const voiceItems = attachments.filter((a) => a && a.attachment_type === 'voice');

    const photoPaths = photoItems
      .map((a) => clean(a.stored_path))
      .filter(Boolean);
    const photoLinks = photoPaths.map((p) => (p ? `file://${p}` : ''));
    const photoFileIds = photoItems
      .map((a) => clean(a.telegram_file_id))
      .filter(Boolean);
    const voiceFileIds = voiceItems
      .map((a) => clean(a.telegram_file_id))
      .filter(Boolean);

    const row = [
      new Date(),
      clean(report.report_id),
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
      photoLinks.join('\n'),
      photoPaths.join('\n'),
      photoFileIds.join('\n'),
      voiceItems.length,
      voiceFileIds.join('\n'),
      stringify(ai),
      stringify(report),
    ];

    sheet.appendRow(row);
    return jsonResponse({ ok: true, report_id: clean(report.report_id) }, 200);
  } catch (err) {
    return jsonResponse({ ok: false, error: String(err) }, 500);
  }
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

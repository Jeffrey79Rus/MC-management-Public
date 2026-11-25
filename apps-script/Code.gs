/**
 * MC 교육 희망 조사 - 응답 저장소 (Google Apps Script)
 * 이 파일을 구글 스프레드시트의 "확장 프로그램 > Apps Script"에 붙여넣고,
 * 1) setup 함수를 한 번 실행한 뒤  2) "배포 > 새 배포 > 웹 앱"으로 배포합니다.
 * 이름·직급 명단과 관리자 키는 이 코드가 아니라 스프레드시트 안에만 둡니다.
 */
var SH_RESP = '응답', SH_ROSTER = '명단', SH_CONF = '설정';
var HEAD = ['제출시각', '이름', '직급', '1지망', '2지망', '3지망', '4지망', '5지망', '팀 공용 희망', '의견', 'pick_ids', 'shared_ids'];
var W = [5, 4, 3, 2, 1];

function setup() {
  var ss = SpreadsheetApp.getActiveSpreadsheet();
  var r = ss.getSheetByName(SH_RESP) || ss.insertSheet(SH_RESP);
  if (r.getLastRow() === 0) { r.appendRow(HEAD); r.setFrozenRows(1); }
  var m = ss.getSheetByName(SH_ROSTER) || ss.insertSheet(SH_ROSTER);
  if (m.getLastRow() === 0) { m.appendRow(['이름', '직급']); m.setFrozenRows(1); }
  var c = ss.getSheetByName(SH_CONF) || ss.insertSheet(SH_CONF);
  if (c.getLastRow() === 0) {
    c.appendRow(['관리자 키', Utilities.getUuid().replace(/-/g, '').slice(0, 12)]);
    c.appendRow(['마감 (닫으려면 Y)', '']);
  }
}

function json_(o) { return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON); }
function clean_(s, n) {
  s = String(s == null ? '' : s).replace(/[\r\n\t]+/g, ' ').trim().slice(0, n);
  return /^[=+\-@]/.test(s) ? "'" + s : s;   // 수식으로 해석되지 않게 막음
}
function ids_(a, n) {
  if (!Array.isArray(a)) return [];
  var out = [];
  a.forEach(function (x) { x = String(x); if (/^[a-z]{2}\d{1,2}$/.test(x) && out.indexOf(x) < 0 && out.length < n) out.push(x); });
  return out;
}
function conf_(row) {
  var c = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SH_CONF);
  return c ? String(c.getRange(row, 2).getValue()).trim() : '';
}
function rows_() {
  var sh = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(SH_RESP);
  if (!sh || sh.getLastRow() < 2) return [];
  return sh.getRange(2, 1, sh.getLastRow() - 1, HEAD.length).getValues().filter(function (v) { return String(v[1]).trim() !== ''; });
}

function doPost(e) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
    if (conf_(2).toUpperCase() === 'Y') return json_({ ok: false, error: 'closed' });
    var d = JSON.parse(e.postData.contents);
    var name = clean_(d.name, 20);
    var picks = ids_(d.picks, 5), shared = ids_(d.shared, 20);
    if (!name || !picks.length) return json_({ ok: false, error: 'invalid' });
    var pn = Array.isArray(d.pickNames) ? d.pickNames : [], sn = Array.isArray(d.sharedNames) ? d.sharedNames : [];
    var ss = SpreadsheetApp.getActiveSpreadsheet(), sh = ss.getSheetByName(SH_RESP);
    if (!sh) { setup(); sh = ss.getSheetByName(SH_RESP); }
    var last = sh.getLastRow(), row = last + 1, updated = false;
    if (last >= 2) {
      var names = sh.getRange(2, 2, last - 1, 1).getValues();
      for (var i = 0; i < names.length; i++) if (String(names[i][0]).trim() === name) { row = i + 2; updated = true; break; }
    }
    var line = [new Date(), name, '=IFERROR(VLOOKUP(B' + row + ",'" + SH_ROSTER + "'!A:B,2,FALSE),\"\")"];
    for (var k = 0; k < 5; k++) line.push(picks[k] ? clean_(pn[k], 120) : '');
    line.push(shared.map(function (_, j) { return clean_(sn[j], 120); }).join(' / '));
    line.push(clean_(d.memo, 500), picks.join(','), shared.join(','));
    sh.getRange(row, 1, 1, HEAD.length).setValues([line]);
    return json_({ ok: true, updated: updated });
  } catch (err) {
    return json_({ ok: false, error: 'server' });
  } finally { try { lock.releaseLock(); } catch (x) {} }
}

function doGet(e) {
  var p = (e && e.parameter) || {}, rows = rows_();
  if (p.action === 'admin') {
    var key = conf_(1);
    if (!key || p.key !== key) return json_({ ok: false, error: 'key' });
    return json_({ ok: true, rows: rows.map(function (v) {
      return { at: v[0] instanceof Date ? v[0].toISOString() : String(v[0]), name: String(v[1]), rank: String(v[2]),
        picks: String(v[10]).split(',').filter(String), shared: String(v[11]).split(',').filter(String), memo: String(v[9]) };
    }) });
  }
  var t = {};
  rows.forEach(function (v) {
    String(v[10]).split(',').filter(String).slice(0, 5).forEach(function (id, i) { var x = t[id] || (t[id] = [0, 0, 0, 0, 0, 0, 0]); x[0] += W[i]; x[i + 1]++; });
    String(v[11]).split(',').filter(String).forEach(function (id) { var x = t[id] || (t[id] = [0, 0, 0, 0, 0, 0, 0]); x[6]++; });
  });
  return json_({ ok: true, n: rows.length, t: t, at: new Date().toISOString(), closed: conf_(2).toUpperCase() === 'Y' });
}

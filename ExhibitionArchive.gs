/** 写真展アンケート／出展者ポータルから統合版へ移植する読み取り専用アーカイブ。 */
const EXHIBITION_ARCHIVE = Object.freeze({
  sourceSheets: {
    members: 'PortalMembers', works: 'PortalWorks', exhibitions: 'PortalExhibitions'
  },
  sheets: {
    exhibitions: 'ArchiveExhibitions', works: 'ArchiveWorks',
    comments: 'ArchiveWorkComments', overall: 'ArchiveOverallComments'
  },
  headers: {
    exhibitions: ['ExhibitionKey','EventId','Title','ResponseCount','IsPublished','ImportedAt'],
    works: ['WorkUuid','ExhibitionKey','DisplayNo','Email','Title','DriveFileId','ImageVisibleToMember','IsPublished','FavoriteCount','ResponseCount','FavoriteRate','ImportedAt'],
    comments: ['CommentId','ExhibitionKey','WorkUuid','Comment','ImportedAt'],
    overall: ['CommentId','ExhibitionKey','Comment','SubmittedAt','ImportedAt']
  },
  maxImageBytes: 8 * 1024 * 1024
});

/**
 * 大学Driveを学外アカウントから参照できない場合のローカル取込台帳を作成する。
 * 実行後、返されたスプレッドシートへ旧4シートのCSVをインポートする。
 */
function initializeLocalExhibitionImportStaging() {
  assertArchiveEditorAdmin_();
  const ss=SpreadsheetApp.openById(config_().books.exhibitionDb);
  const definitions={
    PortalMembers:['MemberId','Email','DisplayName','IsActive','IsAdmin'],
    PortalWorks:['WorkUuid','ExhibitionKey','DisplayNo','TemporaryNo','MemberId','Title','DriveFileId','ImageVisibleToMember','IsPublished'],
    PortalExhibitions:['ExhibitionKey','Title'],
    PortalImageMappings:['WorkUuid','SourceFileName']
  };
  Object.keys(definitions).forEach(function(name){let sheet=ss.getSheetByName(name);if(!sheet){sheet=ss.insertSheet(name);sheet.getRange(1,1,1,definitions[name].length).setValues([definitions[name]]).setFontWeight('bold');sheet.setFrozenRows(1);}});
  PropertiesService.getScriptProperties().setProperty('LEGACY_PORTAL_SPREADSHEET_ID',ss.getId());
  return {ok:true,spreadsheetId:ss.getId(),spreadsheetUrl:ss.getUrl(),message:'ローカル取込シートを作成しました。旧ポータルの4シートをCSVで取り込んでください。'};
}

/** 幹部Driveへ再アップロードした軽量版画像を、ファイル名対応表でPortalWorksへ結び直す。 */
function linkLocalExhibitionPreviewImages() {
  assertArchiveEditorAdmin_();
  const folderId=extractArchiveDriveId_(PropertiesService.getScriptProperties().getProperty('LEGACY_IMAGE_FOLDER_ID'));
  if(!folderId)throw new Error('スクリプトプロパティ LEGACY_IMAGE_FOLDER_ID に、幹部Driveの軽量版画像フォルダIDまたはURLを設定してください。');
  const ss=legacyPortalSpreadsheet_(),mappings=sheetObjectsByName_(ss,'PortalImageMappings'),worksSheet=ss.getSheetByName('PortalWorks');
  if(!worksSheet)throw new Error('PortalWorksシートがありません。');
  const values=worksSheet.getDataRange().getValues(),headers=values[0],uuidIndex=headers.indexOf('WorkUuid'),driveIndex=headers.indexOf('DriveFileId');
  if(uuidIndex<0||driveIndex<0)throw new Error('PortalWorksにWorkUuid / DriveFileId列がありません。');
  const rowsByUuid={};values.slice(1).forEach(function(row,index){if(row[uuidIndex])rowsByUuid[String(row[uuidIndex])]=index+2;});
  const filesByName={},duplicates={},iterator=DriveApp.getFolderById(folderId).getFiles();
  while(iterator.hasNext()){const file=iterator.next(),name=file.getName();if(filesByName[name])duplicates[name]=true;filesByName[name]=file.getId();}
  const missing=[],updates=[];
  mappings.forEach(function(mapping){const uuid=String(mapping.WorkUuid||''),name=String(mapping.SourceFileName||'');if(duplicates[name])throw new Error('画像フォルダに同名ファイルがあります: '+name);if(!rowsByUuid[uuid])throw new Error('PortalWorksに作品IDがありません: '+uuid);if(!filesByName[name])missing.push(name);else updates.push({row:rowsByUuid[uuid],id:filesByName[name]});});
  if(missing.length)throw new Error('画像フォルダに見つからないファイルがあります（'+missing.length+'件）: '+missing.join(', '));
  updates.forEach(function(item){worksSheet.getRange(item.row,driveIndex+1).setValue(item.id);});
  return {ok:true,linked:updates.length,message:updates.length+'作品の軽量版画像を対応付けました。'};
}

/**
 * 旧ポータルの接続先を登録する。Secretはソースへ書かずスクリプトプロパティだけに保存する。
 * GASエディタから一度実行する。
 */
function configureLegacyExhibitionSource(sourceSpreadsheetId, supabaseUrl, supabaseSecret) {
  if (!String(sourceSpreadsheetId || '').trim()) throw new Error('旧ポータルのスプレッドシートIDが必要です。');
  if (!String(supabaseUrl || '').trim() || !String(supabaseSecret || '').trim()) throw new Error('Supabase URLとSecret keyが必要です。');
  SpreadsheetApp.openById(String(sourceSpreadsheetId).trim());
  PropertiesService.getScriptProperties().setProperties({
    LEGACY_PORTAL_SPREADSHEET_ID: String(sourceSpreadsheetId).trim(),
    LEGACY_SUPABASE_URL: String(supabaseUrl).trim().replace(/\/$/, ''),
    LEGACY_SUPABASE_SECRET_KEY: String(supabaseSecret).trim()
  });
  return '旧写真展ポータルの接続先を保存しました。';
}

/** GASエディタの実行ボタンから選択できる、引数なしの夏写真展移行関数。 */
function import2026SummerExhibitionArchive() {
  const properties=PropertiesService.getScriptProperties();
  const required=['LEGACY_PORTAL_SPREADSHEET_ID','LEGACY_SUPABASE_URL','LEGACY_SUPABASE_SECRET_KEY'];
  const missing=required.filter(function(key){return !String(properties.getProperty(key)||'').trim();});
  if(missing.length)throw new Error('プロジェクトの設定 > スクリプト プロパティに未設定の項目があります: '+missing.join(', '));
  const result=importLegacyExhibitionArchive('2026-summer');
  console.log(JSON.stringify(result));
  return result;
}

/**
 * 旧ポータルとSupabaseを読み取り、対象写真展を統合DBへ固定保存する。
 * 2026年夏写真展は importLegacyExhibitionArchive('2026-summer') で取り込む。
 */
function importLegacyExhibitionArchive(exhibitionKey) {
  exhibitionKey = String(exhibitionKey || '').trim();
  if (!exhibitionKey) throw new Error('ExhibitionKeyが必要です。');
  assertArchiveEditorAdmin_();
  const target = ensureArchiveSheets_();
  const source = legacyPortalSpreadsheet_();
  const exhibitions = sheetObjectsByName_(source, EXHIBITION_ARCHIVE.sourceSheets.exhibitions);
  const exhibition = exhibitions.find(function(row) { return String(row.ExhibitionKey) === exhibitionKey; });
  if (!exhibition) throw new Error('旧ポータルに写真展がありません: ' + exhibitionKey);
  const members = {};
  sheetObjectsByName_(source, EXHIBITION_ARCHIVE.sourceSheets.members).forEach(function(row) {
    const memberId = String(row.MemberId || '').trim();
    if (memberId && bool_(row.IsActive)) members[memberId] = String(row.Email || '').trim().toLowerCase();
  });
  const works = sheetObjectsByName_(source, EXHIBITION_ARCHIVE.sourceSheets.works)
    .filter(function(row) { return String(row.ExhibitionKey) === exhibitionKey; });
  if (!works.length) throw new Error('対象写真展の作品がありません。');
  const stats = readLegacySurveyStats_(exhibitionKey, works);
  const now = new Date();
  const archiveWorks = works.map(function(work) {
    const uuid = String(work.WorkUuid || '').trim();
    const email = members[String(work.MemberId || '').trim()] || '';
    const stat = stats.byWork[uuid] || { favoriteCount:0, comments:[] };
    return [uuid,exhibitionKey,String(work.DisplayNo || ''),email,String(work.Title || ''),extractArchiveDriveId_(work.DriveFileId),bool_(work.ImageVisibleToMember),bool_(work.IsPublished),stat.favoriteCount,stats.responseCount,stats.responseCount ? Math.round(stat.favoriteCount / stats.responseCount * 1000) / 10 : 0,now];
  });
  const workComments = [];
  works.forEach(function(work) {
    const uuid = String(work.WorkUuid || '').trim();
    (stats.byWork[uuid] ? stats.byWork[uuid].comments : []).forEach(function(comment) {
      workComments.push([Utilities.getUuid(),exhibitionKey,uuid,String(comment),now]);
    });
  });
  replaceArchiveRows_(target.works, 2, exhibitionKey, archiveWorks);
  replaceArchiveRows_(target.comments, 2, exhibitionKey, workComments);
  replaceArchiveRows_(target.overall, 2, exhibitionKey, stats.overallComments.map(function(item) {
    return [Utilities.getUuid(),exhibitionKey,item.comment,item.submittedAt,now];
  }));
  const currentArchive = readArchiveObjects_(target.exhibitions);
  const prior = currentArchive.find(function(row) { return String(row.ExhibitionKey) === exhibitionKey; });
  const archiveRow = [exhibitionKey,prior ? String(prior.EventId || '') : '',String(exhibition.Title || exhibitionKey),stats.responseCount,prior ? bool_(prior.IsPublished) : false,now];
  replaceArchiveRows_(target.exhibitions, 1, exhibitionKey, [archiveRow]);
  return { ok:true, exhibitionKey:exhibitionKey, works:archiveWorks.length, workComments:workComments.length, overallComments:stats.overallComments.length, responseCount:stats.responseCount, message:'写真展アーカイブを取り込みました。公開前に出展者メールと表示設定を確認してください。' };
}

function getMemberExhibitionArchives_(email) {
  const sheets = ensureArchiveSheets_();
  const exhibitions = readArchiveObjects_(sheets.exhibitions).filter(function(row) { return bool_(row.IsPublished); });
  const allowed = {};
  exhibitions.forEach(function(row) { allowed[String(row.ExhibitionKey)] = row; });
  const commentsByWork = {};
  readArchiveObjects_(sheets.comments).forEach(function(row) {
    if (!commentsByWork[row.WorkUuid]) commentsByWork[row.WorkUuid] = [];
    commentsByWork[row.WorkUuid].push(String(row.Comment || ''));
  });
  const grouped = {};
  readArchiveObjects_(sheets.works).forEach(function(row) {
    const key = String(row.ExhibitionKey || '');
    if (!allowed[key] || !bool_(row.IsPublished) || String(row.Email || '').toLowerCase() !== email) return;
    if (!grouped[key]) grouped[key] = { exhibitionKey:key, title:String(allowed[key].Title || key), responseCount:Number(allowed[key].ResponseCount || 0), works:[] };
    grouped[key].works.push({workUuid:String(row.WorkUuid),displayNo:String(row.DisplayNo),title:String(row.Title),hasImage:!!extractArchiveDriveId_(row.DriveFileId)&&bool_(row.ImageVisibleToMember),favoriteCount:Number(row.FavoriteCount||0),responseCount:Number(row.ResponseCount||0),favoriteRate:Number(row.FavoriteRate||0),comments:commentsByWork[row.WorkUuid]||[]});
  });
  return Object.keys(grouped).map(function(key) { grouped[key].works.sort(function(a,b){return Number(a.displayNo)-Number(b.displayNo);}); return grouped[key]; });
}

function getArchiveWorkImage(token, workUuid) {
  const user = authenticate_(token), sheets = ensureArchiveSheets_();
  const work = readArchiveObjects_(sheets.works).find(function(row) { return String(row.WorkUuid) === String(workUuid); });
  if (!work || !bool_(work.IsPublished) || !bool_(work.ImageVisibleToMember)) throw new Error('この作品画像は表示できません。');
  if (!isAdmin_(user.email) && String(work.Email || '').toLowerCase() !== user.email) throw new Error('この作品画像を閲覧する権限がありません。');
  const id = extractArchiveDriveId_(work.DriveFileId);
  if (!id) throw new Error('表示用画像が登録されていません。');
  const blob = DriveApp.getFileById(id).getBlob(), bytes = blob.getBytes();
  if (bytes.length > EXHIBITION_ARCHIVE.maxImageBytes) throw new Error('表示用画像が8MBを超えています。軽量版へ差し替えてください。');
  return 'data:' + blob.getContentType() + ';base64,' + Utilities.base64Encode(bytes);
}

function setArchiveExhibitionPublished(token, exhibitionKey, published) {
  assertAdmin_(token);
  const archiveSheets=ensureArchiveSheets_();
  if(bool_(published)){
    const invalid=readArchiveObjects_(archiveSheets.works).filter(function(work){return String(work.ExhibitionKey)===String(exhibitionKey)&&bool_(work.IsPublished)&&(!String(work.Email||'').trim()||(bool_(work.ImageVisibleToMember)&&!extractArchiveDriveId_(work.DriveFileId)));});
    if(invalid.length)throw new Error('出展者メールまたは表示用画像が未設定の公開作品があります（'+invalid.length+'件）。旧ポータル側を確認して再取り込みしてください。');
  }
  const sheet = archiveSheets.exhibitions, values = sheet.getDataRange().getValues();
  for (let i=1;i<values.length;i++) if (String(values[i][0]) === String(exhibitionKey)) { sheet.getRange(i+1,5).setValue(bool_(published)); return {ok:true}; }
  throw new Error('写真展アーカイブが見つかりません。');
}

function getArchiveAdminSummary_() {
  const sheets=ensureArchiveSheets_(),works=readArchiveObjects_(sheets.works),comments=readArchiveObjects_(sheets.comments);
  return readArchiveObjects_(sheets.exhibitions).map(function(row){const key=String(row.ExhibitionKey);return{exhibitionKey:key,title:String(row.Title||key),responseCount:Number(row.ResponseCount||0),isPublished:bool_(row.IsPublished),workCount:works.filter(function(work){return String(work.ExhibitionKey)===key;}).length,commentCount:comments.filter(function(comment){return String(comment.ExhibitionKey)===key;}).length,importedAt:clientSafeValue_(row.ImportedAt)};});
}

function readLegacySurveyStats_(exhibitionKey, works) {
  const exhibition = legacySupabaseSelectOne_('survey_exhibitions','select=id&exhibition_key=eq.'+encodeURIComponent(exhibitionKey));
  const byWork = {}, byNumber = {};
  works.forEach(function(work){const uuid=String(work.WorkUuid||'');byWork[uuid]={favoriteCount:0,comments:[]};byNumber[String(Number(work.DisplayNo))]=uuid;});
  if (!exhibition) return {byWork:byWork,responseCount:0,overallComments:[]};
  const responses = legacySupabaseSelectAll_('survey_responses','select=id,overall_comment,submitted_at&exhibition_id=eq.'+exhibition.id);
  const overall = responses.filter(function(row){return String(row.overall_comment||'').trim();}).map(function(row){return{comment:String(row.overall_comment),submittedAt:String(row.submitted_at||'')};});
  const ids = responses.map(function(row){return row.id;});
  for(let i=0;i<ids.length;i+=100){
    legacySupabaseSelectAll_('survey_response_selections','select=response_id,work_id,work_uuid,comment,position&response_id=in.('+ids.slice(i,i+100).join(',')+')').forEach(function(selection){
      const uuid=String(selection.work_uuid||byNumber[String(Number(selection.work_id))]||'');
      if(!byWork[uuid])return;byWork[uuid].favoriteCount++;if(String(selection.comment||'').trim())byWork[uuid].comments.push(String(selection.comment));
    });
  }
  return {byWork:byWork,responseCount:responses.length,overallComments:overall};
}

function legacySupabaseSelectOne_(table, query) { const rows=legacySupabaseSelectAll_(table,query+'&limit=1');return rows.length?rows[0]:null; }
function legacySupabaseSelectAll_(table, query) { const p=PropertiesService.getScriptProperties(),url=String(p.getProperty('LEGACY_SUPABASE_URL')||''),secret=String(p.getProperty('LEGACY_SUPABASE_SECRET_KEY')||'');if(!url||!secret)throw new Error('旧Supabase接続設定がありません。');const headers={apikey:secret,Accept:'application/json'};if(/^eyJ/.test(secret))headers.Authorization='Bearer '+secret;const response=UrlFetchApp.fetch(url+'/rest/v1/'+encodeURIComponent(table)+'?'+query,{method:'get',headers:headers,muteHttpExceptions:true});if(response.getResponseCode()<200||response.getResponseCode()>=300)throw new Error('旧Supabaseからアンケートデータを取得できませんでした。');return JSON.parse(response.getContentText()||'[]'); }
function legacyPortalSpreadsheet_(){const id=PropertiesService.getScriptProperties().getProperty('LEGACY_PORTAL_SPREADSHEET_ID');if(!id)throw new Error('旧ポータルのスプレッドシートIDが未設定です。');return SpreadsheetApp.openById(id);}
function ensureArchiveSheets_(){const ss=openBook_('exhibitionDb'),out={};Object.keys(EXHIBITION_ARCHIVE.sheets).forEach(function(key){const name=EXHIBITION_ARCHIVE.sheets[key],headers=EXHIBITION_ARCHIVE.headers[key];let sheet=ss.getSheetByName(name);if(!sheet){sheet=ss.insertSheet(name);sheet.getRange(1,1,1,headers.length).setValues([headers]).setFontWeight('bold');sheet.setFrozenRows(1);}out[key]=sheet;});return out;}
function readArchiveObjects_(sheet){return objects_(sheet);}
function sheetObjectsByName_(ss,name){
  const sheet=ss.getSheetByName(name);
  if(!sheet)throw new Error(name+'シートがありません。');
  const headers=sheet.getRange(1,1,1,sheet.getLastColumn()).getValues()[0].map(function(value){return String(value||'').trim();});
  return objects_(sheet).filter(function(row){
    return !headers.every(function(header){return !header||String(row[header]||'').trim()===header;});
  });
}
function replaceArchiveRows_(sheet,keyColumn,key,rows){const values=sheet.getDataRange().getValues(),keep=values.slice(1).filter(function(row){return String(row[keyColumn-1])!==String(key);});sheet.clearContents();sheet.getRange(1,1,1,values[0].length).setValues([values[0]]).setFontWeight('bold');const all=keep.concat(rows);if(all.length)sheet.getRange(2,1,all.length,values[0].length).setValues(all);sheet.setFrozenRows(1);}
function extractArchiveDriveId_(value){const match=String(value||'').match(/[-\w]{20,}/);return match?match[0]:'';}
function assertArchiveEditorAdmin_(){const email=String(Session.getEffectiveUser().getEmail()||'').toLowerCase();if(!isAdmin_(email))throw new Error('統合アプリの管理者アカウントで実行してください。');}

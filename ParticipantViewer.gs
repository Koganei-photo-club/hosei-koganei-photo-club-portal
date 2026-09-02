/**
 * 幹部向けの参加者閲覧ブックを準備し、既存予定をすべて同期する。
 * セットアップ済み環境ではGASエディタから1回実行する。
 */
function initializeParticipantViewerBook(){
  const book=participantViewerBook_();
  const events=objects_(sheet_('settingsDb','Events'));
  events.forEach(function(event){syncParticipantViewerSheet_(event.EventId);});
  return{ok:true,spreadsheetId:book.getId(),spreadsheetUrl:book.getUrl(),eventCount:events.length,message:events.length+'件の予定シートを準備しました。'};
}

/** 幹部が必要なときに、全予定の参加者一覧を再構築できる。 */
function syncAllParticipantViewerSheets(){
  const events=objects_(sheet_('settingsDb','Events'));
  events.forEach(function(event){syncParticipantViewerSheet_(event.EventId);});
  return{ok:true,eventCount:events.length,message:events.length+'件の参加者一覧を同期しました。'};
}

function participantViewerBook_(){
  const config=config_();
  if(config.books.participantViewDb){
    if(!runtimeBookCache_.participantViewDb)runtimeBookCache_.participantViewDb=SpreadsheetApp.openById(config.books.participantViewDb);
    return runtimeBookCache_.participantViewDb;
  }
  const book=SpreadsheetApp.create('行事参加者 閲覧ブック');
  DriveApp.getFileById(book.getId()).moveTo(DriveApp.getFolderById(config.dbFolderId));
  const index=book.getSheets()[0];
  index.setName('ParticipantSheets');
  index.getRange(1,1,1,APP.headers.ParticipantSheets.length).setValues([APP.headers.ParticipantSheets]).setFontWeight('bold');
  index.setFrozenRows(1);
  config.books.participantViewDb=book.getId();
  PropertiesService.getScriptProperties().setProperty(APP.propertyKey,JSON.stringify(config));
  runtimeConfigCache_=config;
  runtimeBookCache_.participantViewDb=book;
  return book;
}

function ensureParticipantEventSheet_(eventId){
  const event=findEvent_(eventId);
  if(!event)throw new Error('参加者閲覧シートを作成する予定が見つかりません。');
  const book=participantViewerBook_(),index=book.getSheetByName('ParticipantSheets'),values=index.getDataRange().getValues();
  for(let row=1;row<values.length;row++){
    if(String(values[row][0]).trim()===String(event.EventId).trim()){
      const sheet=book.getSheetByName(String(values[row][1]));
      if(sheet){
        index.getRange(row+1,3,1,3).setValues([[event.Title,event.Genre,new Date()]]);
        return sheet;
      }
    }
  }
  const sheetName=participantSheetName_(book,event);
  const sheet=book.insertSheet(sheetName);
  sheet.getRange(1,1,1,APP.headers.ParticipantView.length).setValues([APP.headers.ParticipantView]).setFontWeight('bold');
  sheet.setFrozenRows(1);
  sheet.getRange(1,1,1,APP.headers.ParticipantView.length).setBackground('#1c5b3c').setFontColor('#ffffff');
  index.appendRow([event.EventId,sheetName,event.Title,event.Genre,new Date()]);
  return sheet;
}

function syncParticipantViewerSheet_(eventId){
  const event=findEvent_(eventId);
  if(!event)return;
  const target=ensureParticipantEventSheet_(event.EventId),responses=objects_(responseSheet_(event.Genre)).filter(function(response){return String(response.EventId).trim()===String(event.EventId).trim();});
  const membersByEmail={};
  objects_(sheet_('memberDb','Members')).forEach(function(member){membersByEmail[String(member.Email||'').trim().toLowerCase()]=member;});
  const rows=responses.map(function(response){
    const member=membersByEmail[String(response.Email||'').trim().toLowerCase()]||{};
    return[
      response.ResponseId,response.SubmittedAt,member.MemberId||'',response.Name||member.Name||'',member.Faculty||'',member.Grade||'',member.Department||'',member.GraduateSchool||'',member.Major||'',member.Gender||'',response.LineName||member.LineName||'',response.Attendance,bool_(response.Camera),bool_(response.DisposableCamera),response.Allergies,response.OtherAllergy,response.Note,bool_(response.Agreement),response.PaymentStatus,response.CancelledAt
    ];
  });
  const width=APP.headers.ParticipantView.length,lastRow=target.getLastRow();
  if(lastRow>1)target.getRange(2,1,lastRow-1,width).clearContent();
  if(rows.length)target.getRange(2,1,rows.length,width).setValues(rows);
  target.autoResizeColumns(1,width);
  const index=participantViewerBook_().getSheetByName('ParticipantSheets'),indexValues=index.getDataRange().getValues();
  for(let row=1;row<indexValues.length;row++)if(String(indexValues[row][0]).trim()===String(event.EventId).trim()){index.getRange(row+1,5).setValue(new Date());break;}
}

/** 自動生成した予定シートと索引だけを削除する。元の回答台帳は削除しない。 */
function deleteParticipantEventSheet_(eventId){
  const config=config_(),bookId=config.books.participantViewDb;
  if(!bookId)return;
  const book=participantViewerBook_(),index=book.getSheetByName('ParticipantSheets'),values=index.getDataRange().getValues(),target=String(eventId||'').trim();
  for(let row=values.length-1;row>=1;row--){
    if(String(values[row][0]||'').trim()!==target)continue;
    const sheet=book.getSheetByName(String(values[row][1]||''));
    if(sheet&&sheet.getName()!=='ParticipantSheets')book.deleteSheet(sheet);
    index.deleteRow(row+1);
  }
}

function participantSheetName_(book,event){
  const suffix=String(event.EventId||'').replace(/[^A-Za-z0-9]/g,'').slice(-6)||Utilities.getUuid().slice(0,6);
  const base=String(event.Title||'予定').replace(/[\\\/\?\*\[\]:]/g,' ').replace(/\s+/g,' ').trim().slice(0,85)||'予定';
  let name=(base+' ['+suffix+']').slice(0,100),number=2;
  while(book.getSheetByName(name)){name=(base.slice(0,90)+' '+number).slice(0,100);number++;}
  return name;
}

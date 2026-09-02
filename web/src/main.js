import './styles.css'
import { configured, googleClientId, supabase } from './supabase.js'

const app=document.querySelector('#app')
let session=null

const esc=value=>{const node=document.createElement('div');node.textContent=String(value??'');return node.innerHTML}
const fmt=value=>value?new Date(value).toLocaleString('ja-JP'):'未定'
const fiscalYear=()=>{const d=new Date();return d.getFullYear()-(d.getMonth()<3?1:0)}
const eventLabel=e=>e.genre==='camp'?'合宿':e.genre==='exhibition'?'写真展':e.subtype==='dining'?'全体会・お食事会':'全体会・撮影会'
const route=()=>location.hash.replace(/^#/,'')||'/'

function layout(title='活動ポータル',actions=''){
  app.innerHTML=`<header class="site-header"><div><p class="eyebrow">HOSEI PHOTO CLUB</p><h1 class="site-title">${esc(title)}</h1></div><div class="header-actions">${actions}</div></header><main class="page"><div id="message" class="notice">読み込んでいます…</div><div id="view"></div></main>`
}
function message(text,error=false){const box=document.querySelector('#message');box.textContent=text;box.classList.remove('hidden');box.classList.toggle('error',error)}
function hideMessage(){document.querySelector('#message')?.classList.add('hidden')}
function failure(error){message(typeof error==='string'?error:error?.message||'処理に失敗しました。',true)}

async function boot(){
  if(!configured){layout();failure('Supabaseの接続先が未設定です。.envを設定してください。');return}
  const {data}=await supabase.auth.getSession();session=data.session
  supabase.auth.onAuthStateChange((_event,next)=>{session=next;setTimeout(()=>next?navigate():renderAuth(),0)})
  if(session)navigate();else renderAuth()
}

function loadGoogleIdentity(){
  if(window.google?.accounts?.id)return Promise.resolve()
  return new Promise((resolve,reject)=>{
    const existing=document.querySelector('#google-identity-script')
    if(existing){existing.addEventListener('load',resolve,{once:true});existing.addEventListener('error',reject,{once:true});return}
    const script=document.createElement('script');script.id='google-identity-script';script.src='https://accounts.google.com/gsi/client';script.async=true;script.defer=true;script.onload=resolve;script.onerror=()=>reject(new Error('Googleログインを読み込めませんでした。外部ブラウザで開き直してください。'));document.head.appendChild(script)
  })
}

async function createGoogleNonce(){
  const bytes=crypto.getRandomValues(new Uint8Array(32))
  const nonce=btoa(String.fromCharCode(...bytes)).replaceAll('+','-').replaceAll('/','_').replaceAll('=','')
  const digest=await crypto.subtle.digest('SHA-256',new TextEncoder().encode(nonce))
  const hashed=Array.from(new Uint8Array(digest),byte=>byte.toString(16).padStart(2,'0')).join('')
  return{nonce,hashed}
}

async function renderAuth(){
  layout('活動ポータル')
  hideMessage()
  app.insertAdjacentHTML('beforeend',`<section class="auth-layer"><div class="panel auth-card"><p class="eyebrow">SECURE SIGN IN</p><h2>Googleアカウントでログイン</h2><p class="copy">部員は大学のGoogleアカウント、幹部は管理者として登録されたGoogleアカウントを使用してください。</p><div id="googleSignIn"></div><p id="authMessage" class="muted">Googleログインを準備しています…</p><p class="muted">LINE内で開いている場合は、外部ブラウザで開いてください。</p></div></section>`)
  const authMessage=document.querySelector('#authMessage')
  if(!googleClientId){authMessage.textContent='Google Client IDが未設定です。';return}
  try{
    await loadGoogleIdentity();const {nonce,hashed}=await createGoogleNonce()
    google.accounts.id.initialize({client_id:googleClientId,nonce:hashed,use_fedcm_for_prompt:true,itp_support:true,auto_select:false,callback:async response=>{
      authMessage.textContent='ログイン情報を確認しています…'
      const {error}=await supabase.auth.signInWithIdToken({provider:'google',token:response.credential,nonce})
      if(error)authMessage.textContent=`ログインできませんでした：${error.message}`
    }})
    google.accounts.id.renderButton(document.querySelector('#googleSignIn'),{type:'standard',shape:'rectangular',theme:'outline',text:'continue_with',size:'large',logo_alignment:'left',width:300})
    authMessage.textContent=''
  }catch(error){authMessage.textContent=error.message||'Googleログインを準備できませんでした。'}
}

function renderAccessDenied(email){
  layout('利用対象外のアカウント')
  hideMessage()
  document.querySelector('#view').innerHTML=`<section class="panel auth-card"><p class="eyebrow">ACCESS DENIED</p><h2>対象アカウントではありません</h2><p class="copy">${esc(email)} は、現在の部員名簿または管理者一覧に登録されていません。</p><div class="actions"><button id="switchAccount">アカウントを切り替える</button></div></section>`
  document.querySelector('#switchAccount').onclick=async()=>{google?.accounts?.id?.disableAutoSelect();await supabase.auth.signOut()}
}

async function navigate(){
  try{
    const context=await getContext()
    if(!context.member&&!context.admin){renderAccessDenied(context.email);return}
    const path=route()
    if(path.startsWith('/event/'))return renderEvent(path.split('/')[2],context)
    if(path==='/admin')return renderAdmin(context)
    return renderPortal(context)
  }catch(error){layout();failure(error)}
}

async function getContext(){
  const email=session.user.email.toLowerCase()
  const [{data:member,error:memberError},{data:admin,error:adminError}]=await Promise.all([
    supabase.from('members').select('*,membership_years(*)').eq('email',email).maybeSingle(),
    supabase.from('admins').select('email,name,role_name').eq('email',email).eq('active',true).maybeSingle(),
  ])
  if(memberError)throw memberError;if(adminError)throw adminError
  return{email,member,admin}
}

async function renderPortal(context){
  layout('活動ポータル','<button id="logout" class="secondary">ログアウト</button>')
  document.querySelector('#logout').onclick=()=>supabase.auth.signOut()
  try{
    if(context.admin)document.querySelector('.header-actions').insertAdjacentHTML('afterbegin','<a class="button secondary" href="#/admin">管理画面</a>')
    const {data:events,error}=await supabase.from('events').select('*,event_responses(*)').is('deleted_at',null).order('starts_at')
    if(error)throw error
    hideMessage();const view=document.querySelector('#view'),membership=context.member?.membership_years?.find(y=>y.fiscal_year===fiscalYear()&&y.active)
    view.innerHTML=`<section class="panel"><span class="tag">MEMBER</span><h2>${esc(context.member?.name||context.email)}さん</h2>${context.member?`<p>${esc([context.member.grade,context.member.faculty,context.member.department].filter(Boolean).join('・'))}</p><p>部員ID：${esc(context.member.member_no)}</p><p class="status">${membership?`${fiscalYear()}年度 在籍中`:`${fiscalYear()}年度の在籍登録はありません`}</p>`:'<p>部員名簿に登録されていません。</p>'}</section><div class="section-head"><p class="eyebrow">OPEN EVENTS</p><h2>現在参加できる活動</h2></div><section id="events" class="grid"></section><div class="section-head"><p class="eyebrow">MY EXHIBITION</p><h2>写真展マイページ</h2></div><section id="archives" class="stack"></section>`
    const eventRoot=document.querySelector('#events')
    if(!events?.length)eventRoot.innerHTML='<div class="panel">現在参加できる活動はありません。</div>'
    events?.forEach(event=>{const response=event.event_responses?.[0];eventRoot.insertAdjacentHTML('beforeend',`<a class="card" href="#/event/${event.id}"><div><span class="tag">${eventLabel(event)}</span><h3>${esc(event.title)}</h3><p>${fmt(event.starts_at)}・${esc(event.place)}</p>${response?`<p class="status">${response.cancelled_at?'キャンセル済み':`回答済み：${esc(response.attendance)}`}</p>`:''}</div><strong>→</strong></a>`)})
    await renderArchives()
  }catch(error){failure(error)}
}

async function renderArchives(){
  const {data:works,error}=await supabase.from('archive_works').select('*,archive_exhibitions(*),archive_work_comments(*)').order('display_no')
  if(error)throw error
  const root=document.querySelector('#archives');if(!works?.length){root.innerHTML='<div class="panel muted">公開中の作品アーカイブはありません。</div>';return}
  const grouped=works.reduce((result,work)=>{(result[work.exhibition_id]??=[]).push(work);return result},{})
  Object.values(grouped).forEach(items=>root.insertAdjacentHTML('beforeend',`<article class="panel"><span class="tag">EXHIBITION ARCHIVE</span><h3>${esc(items[0].archive_exhibitions.title)}</h3><div class="grid">${items.map(w=>`<section><p class="tag">No.${esc(w.display_no)}</p><h3>${esc(w.title)}</h3><p><strong>${w.favorite_count}票</strong>・${w.favorite_rate}%</p><details><summary>寄せられた感想（${w.archive_work_comments.length}件）</summary><ul>${w.archive_work_comments.map(c=>`<li>${esc(c.comment)}</li>`).join('')}</ul></details></section>`).join('')}</div></article>`))
}

async function renderEvent(id,context){
  layout('参加回答','<a class="button secondary" href="#/">部員画面へ戻る</a>')
  try{
    const {data:event,error}=await supabase.from('events').select('*,event_responses(*)').eq('id',id).single()
    const member=context.member
    if(error)throw error;hideMessage();const existing=event.event_responses?.[0],view=document.querySelector('#view')
    view.innerHTML=`<section class="panel"><span class="tag">${eventLabel(event)}</span><h2>${esc(event.title)}</h2><dl><dt>日時</dt><dd>${fmt(event.starts_at)}</dd><dt>場所</dt><dd>${esc(event.place)}</dd><dt>連絡先</dt><dd>${esc(event.contact)}</dd>${event.fee?`<dt>費用</dt><dd>${event.fee.toLocaleString()}円</dd>`:''}</dl><p class="copy">${esc(event.details)}</p></section><section id="response" class="panel"></section>`
    const root=document.querySelector('#response')
    if(existing){root.innerHTML=`<span class="tag">YOUR RESPONSE</span><h2>回答済みです</h2><dl><dt>回答</dt><dd class="status">${esc(existing.attendance)}</dd><dt>回答日時</dt><dd>${fmt(existing.submitted_at)}</dd>${existing.note?`<dt>備考</dt><dd>${esc(existing.note)}</dd>`:''}</dl><p>変更が必要な場合は幹部へ連絡してください。</p>`;return}
    root.innerHTML=`<h2>出欠を回答</h2><form id="responseForm"><fieldset><legend>出欠</legend><label><input type="radio" name="attendance" value="参加" required>参加</label><label><input type="radio" name="attendance" value="不参加" required>不参加</label></fieldset><label>LINEの名前<input name="line_name" value="${esc(member?.line_name||'')}" required></label><div id="joinFields">${event.genre==='camp'||event.subtype==='dining'?'<label>アレルギー<input name="allergies" required placeholder="なしの場合は「なし」"></label>':''}${event.camera_enabled?'<label><input type="checkbox" name="camera">貸出カメラを希望</label>':''}${event.disposable_enabled?'<label><input type="checkbox" name="disposable_camera">写るんですを希望</label>':''}${event.genre==='camp'?'<div class="notice"><p>送信後の取消しは原則として認められません。期限までに費用を支払わない場合は自動キャンセルになります。</p><label><input type="checkbox" name="agreement" required>条件に同意します</label></div>':''}</div><label>備考<textarea name="note" rows="4"></textarea></label><div class="actions"><button>この内容で回答</button></div></form>`
    const form=document.querySelector('#responseForm');form.querySelectorAll('[name=attendance]').forEach(r=>r.onchange=()=>{const join=document.querySelector('#joinFields'),hide=r.value==='不参加'&&r.checked;join.classList.toggle('hidden',hide);join.querySelectorAll('input,select,textarea').forEach(control=>control.disabled=hide)})
    form.onsubmit=async submit=>{submit.preventDefault();const values=Object.fromEntries(new FormData(form)),button=form.querySelector('button');button.disabled=true;const attendance=values.attendance
      const {error:insertError}=await supabase.from('event_responses').insert({event_id:id,member_id:member.id,line_name:values.line_name,attendance,camera:attendance==='参加'&&values.camera==='on',disposable_camera:attendance==='参加'&&values.disposable_camera==='on',allergies:attendance==='参加'?values.allergies||'':'',note:values.note||'',agreement:attendance==='参加'&&values.agreement==='on',payment_status:attendance==='参加'&&event.fee>0?'unpaid':'not_required'})
      if(insertError){button.disabled=false;failure(insertError);return}renderEvent(id)}
  }catch(error){failure(error)}
}

async function renderAdmin(context){
  context??=await getContext()
  layout('予定管理','<a class="button secondary" href="#/">部員画面</a><button id="logout" class="secondary">ログアウト</button>')
  document.querySelector('#logout').onclick=()=>supabase.auth.signOut()
  try{
    if(!context.admin)throw new Error('管理者権限がありません。')
    const {data:events,error}=await supabase.from('events').select('*').is('deleted_at',null).order('updated_at',{ascending:false});if(error)throw error
    hideMessage();const view=document.querySelector('#view');view.innerHTML=`<div class="admin-nav"><button id="showEvents" class="secondary">予定管理</button><button id="showReceipt" class="secondary">領収証発行</button></div><section id="eventAdmin"><div class="actions"><button id="newEvent">新規予定を作成</button></div><section class="panel"><div id="adminList"></div></section><section id="editor" class="panel hidden"></section></section><section id="receiptAdmin" class="panel hidden"><span class="tag">MEMBERSHIP RECEIPT</span><h2>部費領収証を発行</h2><p class="muted">既存部員は大学メールから情報を呼び出せます。登録と同時に年度在籍が有効になります。</p><form id="receiptForm" class="form-grid"><label class="full">大学メールアドレス<div class="inline-field"><input type="email" name="email" required autocomplete="off"><button type="button" id="findMember" class="secondary">名簿から検索</button></div></label><label>氏名<input name="name" required></label><label>学年<input name="grade" required placeholder="B1 / M1"></label><label>学部（学部生）<input name="faculty"></label><label>学科（学部生）<input name="department"></label><label>研究科（院生）<input name="graduate_school"></label><label>専攻（院生）<input name="major"></label><label>性別<select name="gender"><option value=""></option><option>男性</option><option>女性</option><option>その他</option><option>回答しない</option></select></label><label>LINEの名前<input name="line_name" required></label><label>前年度在籍状況<select name="previous_member"><option value=""></option><option>在籍</option><option>未在籍</option><option>不明</option></select></label><label>年度<input type="number" name="fiscal_year" min="2000" max="2200" required value="${fiscalYear()}"></label><label>金額<input type="number" name="amount" min="0" required value="6000"></label><div class="full notice">但書は「<strong><span id="receiptYear">${fiscalYear()}</span>年度部費として</strong>」で記録されます。</div><div class="actions full"><button id="issueReceipt">年度在籍登録・領収証発行</button></div></form><section id="receiptResult" class="receipt-result hidden"></section></section>`
    const list=document.querySelector('#adminList');if(!events.length)list.innerHTML='<p>予定はまだありません。</p>'
    events.forEach(event=>list.insertAdjacentHTML('beforeend',`<article class="admin-row" data-id="${event.id}"><div><span class="tag">${event.status==='draft'?'下書き':event.published?'公開中':'非公開'}</span><h3>${esc(event.title)}</h3><p>${fmt(event.starts_at)}</p></div><div class="actions"><button class="secondary edit">編集</button><button class="secondary publish">${event.published?'非公開にする':'公開する'}</button><button class="danger delete">削除</button></div></article>`))
    list.querySelectorAll('.admin-row').forEach(row=>{const event=events.find(e=>e.id===row.dataset.id);row.querySelector('.edit').onclick=()=>renderEditor(event);row.querySelector('.publish').onclick=async()=>{if(!confirm(`「${event.title}」の公開状態を変更しますか？`))return;await supabase.from('events').update({published:!event.published,updated_at:new Date().toISOString()}).eq('id',event.id);renderAdmin()};row.querySelector('.delete').onclick=async()=>{if(!confirm(`「${event.title}」を削除しますか？\n回答記録は保持されます。`))return;const {error}=await supabase.from('events').update({deleted_at:new Date().toISOString(),published:false}).eq('id',event.id);if(error)failure(error);else renderAdmin()}})
    document.querySelector('#newEvent').onclick=()=>renderEditor(null)
    const eventAdmin=document.querySelector('#eventAdmin'),receiptAdmin=document.querySelector('#receiptAdmin')
    document.querySelector('#showEvents').onclick=()=>{eventAdmin.classList.remove('hidden');receiptAdmin.classList.add('hidden')}
    document.querySelector('#showReceipt').onclick=()=>{eventAdmin.classList.add('hidden');receiptAdmin.classList.remove('hidden')}
    setupReceiptForm()
  }catch(error){failure(error)}
}

function setupReceiptForm(){
  const form=document.querySelector('#receiptForm'),result=document.querySelector('#receiptResult')
  form.fiscal_year.oninput=()=>document.querySelector('#receiptYear').textContent=form.fiscal_year.value||'----'
  document.querySelector('#findMember').onclick=async()=>{
    const email=form.email.value.trim().toLowerCase();if(!email){failure('大学メールアドレスを入力してください。');return}
    const {data,error}=await supabase.from('members').select('*').eq('email',email).maybeSingle()
    if(error){failure(error);return}if(!data){message('名簿に未登録です。新規部員として必要事項を入力してください。');return}
    for(const name of ['name','faculty','grade','department','graduate_school','major','gender','line_name','previous_member'])form.elements[name].value=data[name]||''
    message(`${data.member_no} の部員情報を読み込みました。`)
  }
  form.onsubmit=async event=>{
    event.preventDefault();const button=document.querySelector('#issueReceipt')
    if(!confirm(`${form.elements.name.value}さんの${form.elements.fiscal_year.value}年度部費 ${Number(form.elements.amount.value).toLocaleString()}円を記録しますか？`))return
    button.disabled=true;result.classList.add('hidden')
    const values=Object.fromEntries(new FormData(form));values.fiscal_year=Number(values.fiscal_year);values.amount=Number(values.amount)
    const {data,error}=await supabase.rpc('issue_membership_receipt',Object.fromEntries(Object.entries(values).map(([key,value])=>[`p_${key}`,value])))
    button.disabled=false;if(error){failure(error);return}
    result.innerHTML=`<span class="tag">ISSUED</span><h3>領収証記録を保存しました</h3><dl><dt>部員ID</dt><dd>${esc(data.memberId)}</dd><dt>領収証ID</dt><dd>${esc(data.receiptId)}</dd><dt>但書</dt><dd>${esc(data.description)}</dd></dl>`;result.classList.remove('hidden');message('年度在籍登録と領収証発行が完了しました。');form.reset();form.fiscal_year.value=fiscalYear();form.amount.value=6000;form.fiscal_year.oninput()
  }
}

function renderEditor(event){
  const root=document.querySelector('#editor');root.classList.remove('hidden');root.innerHTML=`<h2>${event?'予定を編集':'新規予定'}</h2><form id="eventForm" class="form-grid"><label class="full">予定名<input name="title" value="${esc(event?.title||'')}" required></label><label>ジャンル<select name="genre"><option value="meeting">全体会</option><option value="camp">合宿</option><option value="exhibition">写真展</option></select></label><label>種別<select name="subtype"><option value="shooting">撮影会</option><option value="dining">お食事会</option></select></label><label>開始日時<input type="datetime-local" name="starts_at"></label><label>終了日時<input type="datetime-local" name="ends_at"></label><label>場所<input name="place" value="${esc(event?.place||'')}"></label><label>連絡先<input name="contact" value="${esc(event?.contact||'')}"></label><label class="full">必要事項<textarea name="details">${esc(event?.details||'')}</textarea></label><div class="actions full"><button type="button" id="draft" class="secondary">一時保存</button><button>保存</button></div></form>`
  const form=document.querySelector('#eventForm');form.genre.value=event?.genre||'meeting';form.subtype.value=event?.subtype||'shooting';if(event?.starts_at)form.starts_at.value=new Date(event.starts_at).toISOString().slice(0,16);if(event?.ends_at)form.ends_at.value=new Date(event.ends_at).toISOString().slice(0,16)
  const save=async draft=>{const values=Object.fromEntries(new FormData(form));const payload={...values,status:draft?'draft':'saved',starts_at:values.starts_at||null,ends_at:values.ends_at||null,updated_at:new Date().toISOString(),updated_by:session.user.email};const query=event?supabase.from('events').update(payload).eq('id',event.id):supabase.from('events').insert(payload);const {error}=await query;if(error)failure(error);else{message(draft?'下書きを保存しました。':'予定を保存しました。');renderAdmin()}}
  form.onsubmit=e=>{e.preventDefault();save(false)};document.querySelector('#draft').onclick=()=>save(true);root.scrollIntoView({behavior:'smooth'})
}

window.addEventListener('hashchange',()=>session&&navigate())
boot()

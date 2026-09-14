const esc = (value) => {
  const node = document.createElement("div");
  node.textContent = String(value ?? "");
  return node.innerHTML;
};
const fmt = (value) =>
  value
    ? new Date(value).toLocaleString("ja-JP", { timeZone: "Asia/Tokyo" })
    : "未定";
const local = (value) =>
  value
    ? new Date(new Date(value).getTime() - new Date(value).getTimezoneOffset() * 60000)
        .toISOString()
        .slice(0, 16)
    : "";
const iso = (value) => (value ? new Date(value).toISOString() : null);
const statusLabel = (status) =>
  status === "scheduled" ? "予定" : status === "in_progress" ? "実施中" : "終了";
const elapsed = (value) => {
  if (!value) return "開始日時を確認できません";
  const minutes = Math.max(0, Math.floor((Date.now() - new Date(value)) / 60000));
  return `開始から ${Math.floor(minutes / 60)}時間${minutes % 60}分`;
};

let pollTimer = null;
let permissionTimer = null;
let lockTimer = null;
let currentLockId = null;
let stateCache = null;
let maintenanceClient = null;

window.addEventListener("pagehide", () => {
  if (currentLockId && maintenanceClient)
    maintenanceClient.rpc("release_maintenance_lock", {
      p_maintenance_id: currentLockId,
    });
});

export async function publicMaintenanceInfo(supabase) {
  const { data, error } = await supabase.rpc("get_public_maintenance_info");
  if (error) throw error;
  return data;
}

export function maintenanceLoginMarkup(info) {
  if (!info) return "";
  const active = info.state === "maintenance" ? info.maintenance : null;
  return `<section class="maintenance-login-info">
    ${active ? `<div class="notice error"><strong>現在システムメンテナンス中です</strong><p>${esc(active.message)}</p><dl><dt>開始</dt><dd>${fmt(active.started_at)}</dd><dt>終了予定</dt><dd>${fmt(active.scheduled_end_at)}</dd><dt>連絡先</dt><dd>${esc(active.contact)}</dd></dl></div>` : ""}
    <h3>今後のメンテナンス予定</h3>
    ${(info.scheduled || []).length ? `<div class="maintenance-public-list">${info.scheduled.map((item) => `<article><strong>${esc(item.title)}</strong><span>${fmt(item.scheduled_start_at)} 〜 ${fmt(item.scheduled_end_at)}</span><p>${esc(item.message)}</p></article>`).join("")}</div>` : '<p class="muted">現在予定されているメンテナンスはありません。</p>'}
  </section>`;
}

export async function maintenanceState(supabase) {
  const { data, error } = await supabase.rpc("get_maintenance_state");
  if (error) throw error;
  stateCache = data;
  return data;
}

export async function ensurePortalAvailable(supabase) {
  try {
    const state = await maintenanceState(supabase);
    if (state.state === "normal" || state.isMaintenanceAdmin) return true;
    location.hash = "/maintenance";
    window.dispatchEvent(new HashChangeEvent("hashchange"));
    return false;
  } catch (error) {
    console.error("submit-time maintenance check failed", error);
    location.hash = "/maintenance";
    window.dispatchEvent(new HashChangeEvent("hashchange"));
    return false;
  }
}

export function stopMaintenancePolling() {
  clearInterval(pollTimer);
  clearInterval(permissionTimer);
  clearInterval(lockTimer);
  pollTimer = permissionTimer = lockTimer = null;
}

export function startMaintenancePolling(supabase, onChange) {
  clearInterval(pollTimer);
  pollTimer = setInterval(async () => {
    try {
      const before = stateCache?.state;
      const next = await maintenanceState(supabase);
      if (next.state !== before || next.state === "maintenance_state_error")
        onChange(next);
    } catch (error) {
      console.error("maintenance state polling failed", error);
      onChange({ state: "state_unavailable" });
    }
  }, 30000);
}

export function renderMaintenanceBlock({ app, layout, hideMessage, supabase, state, retry }) {
  stopMaintenancePolling();
  const unavailable = state.state === "state_unavailable";
  const inconsistent = state.state === "maintenance_state_error";
  layout(
    unavailable
      ? "システムの状態を確認できません"
      : inconsistent
        ? "システムの状態に問題が発生しています"
        : "システムメンテナンス中",
    '<button id="maintenanceLogout" class="secondary">ログアウト</button>',
  );
  hideMessage();
  const target = document.querySelector("#view");
  if (unavailable || inconsistent) {
    target.innerHTML = `<section class="panel maintenance-block"><p class="eyebrow">SYSTEM STATUS</p><h2>${unavailable ? "システムの状態を確認できません" : "システムの状態に問題が発生しています"}</h2><p>${unavailable ? "現在、ポータルの状態を確認できないため、一時的にご利用いただけません。通信環境をご確認のうえ、しばらくしてからもう一度お試しください。" : "現在、ポータルの利用状態を正しく判定できないため、安全のため一時的にご利用いただけません。管理者による確認・復旧をお待ちください。"}</p><div class="actions"><button id="maintenanceRetry">もう一度確認する</button></div></section>`;
    document.querySelector("#maintenanceRetry").onclick = retry;
  } else {
    const item = state.maintenance;
    target.innerHTML = `<section class="panel maintenance-block"><p class="eyebrow">MAINTENANCE</p><h2>システムメンテナンス中</h2><p class="copy">${esc(item.message)}</p><dl><dt>開始日時</dt><dd>${fmt(item.started_at)}</dd><dt>終了予定</dt><dd>${fmt(item.scheduled_end_at)}</dd><dt>連絡先</dt><dd>${esc(item.contact)}</dd></dl><p class="muted">メンテナンス終了後、自動的にポータルトップへ移動します。</p></section>`;
    startMaintenancePolling(supabase, (next) => {
      if (next.state === "normal") {
        location.hash = "/";
        window.dispatchEvent(new HashChangeEvent("hashchange"));
      } else if (next.state !== "maintenance") retry(next);
    });
  }
  document.querySelector("#maintenanceLogout").onclick = () => supabase.auth.signOut();
}

function validateForm(values, existing = null) {
  for (const [name, max] of [["title", 50], ["message", 100], ["contact", 30], ["description", 500]]) {
    const value = values[name]?.trim() || "";
    if (!value) throw new Error(`${name === "title" ? "タイトル" : name === "message" ? "公開メッセージ" : name === "contact" ? "連絡先" : "内部説明"}は必須です。`);
    if (value.length > max) throw new Error(`${name}は${max}文字以内にしてください。`);
    if (["title", "contact"].includes(name) && /[\r\n]/.test(value)) throw new Error(`${name}に改行は使用できません。`);
  }
  if (!values.scheduled_start_at) throw new Error("開始予定は必須です。");
  if (!values.end_unknown && !values.scheduled_end_at) throw new Error("終了予定または終了未定を指定してください。");
  if (values.scheduled_end_at && values.scheduled_end_at <= values.scheduled_start_at) throw new Error("終了予定は開始予定より後にしてください。");
  if (!existing && new Date(values.scheduled_start_at) <= new Date()) throw new Error("開始予定は未来の日時にしてください。");
}

function maintenanceForm(item = null) {
  const progress = item?.status === "in_progress";
  return `<form id="maintenanceForm" class="form-grid" data-id="${esc(item?.id || "")}" data-updated-at="${esc(item?.updated_at || "")}">
    <label class="full">タイトル（必須・50文字以内）<input name="title" maxlength="50" value="${esc(item?.title || "")}" ${progress ? "disabled" : ""} required></label>
    <label>開始予定<input type="datetime-local" name="scheduled_start_at" value="${local(item?.scheduled_start_at)}" ${progress ? "disabled" : ""} required></label>
    <label>終了予定<input type="datetime-local" name="scheduled_end_at" value="${local(item?.scheduled_end_at)}"></label>
    <label class="full"><input type="checkbox" name="end_unknown" ${item && !item.scheduled_end_at ? "checked" : ""}>終了予定未定</label>
    <label class="full">ログイン画面に表示するメッセージ（必須・100文字以内）<textarea name="message" maxlength="100" rows="3" required>${esc(item?.message || "")}</textarea></label>
    <label>連絡先（必須・30文字以内）<input name="contact" maxlength="30" value="${esc(item?.contact || "")}" ${progress ? "disabled" : ""} required></label>
    <label class="full">内部説明（必須・500文字以内）<textarea name="description" maxlength="500" rows="5" required>${esc(item?.description || "")}</textarea></label>
    <div class="actions full"><button type="button" id="cancelMaintenanceEdit" class="secondary">キャンセル</button><button>保存</button></div>
  </form>`;
}

function detailMarkup(item, admins, logs, lock) {
  const actor = (email) => admins.find((admin) => admin.email === email)?.name || email || "不明";
  return `<article class="maintenance-detail" data-id="${item.id}"><div class="entry-heading"><div><span class="tag status-${item.status}">${statusLabel(item.status)}</span><h2>${esc(item.title)}</h2></div></div><dl><dt>開始予定</dt><dd>${fmt(item.scheduled_start_at)}</dd><dt>終了予定</dt><dd>${fmt(item.scheduled_end_at)}</dd><dt>公開メッセージ</dt><dd>${esc(item.message)}</dd><dt>連絡先</dt><dd>${esc(item.contact)}</dd><dt>内部説明</dt><dd>${esc(item.description)}</dd><dt>作成者</dt><dd>${esc(actor(item.created_by))}</dd><dt>最終更新者</dt><dd>${esc(actor(item.updated_by))}</dd><dt>作成日時</dt><dd>${fmt(item.created_at)}</dd><dt>更新日時</dt><dd>${fmt(item.updated_at)}</dd>${item.started_at || item.started_at_is_unknown || item.status !== "scheduled" ? `<dt>実績開始</dt><dd>${item.started_at_is_unknown ? "不明" : `${item.started_at_is_estimated ? "約 " : ""}${fmt(item.started_at)}`}</dd><dt>開始者</dt><dd>${item.started_at_is_unknown ? "不明" : esc(actor(item.started_by))}</dd>` : ""}${item.status === "completed" ? `<dt>実績終了</dt><dd>${item.ended_at_is_unknown ? "不明" : `${item.ended_at_is_estimated ? "約 " : ""}${fmt(item.ended_at)}`}</dd><dt>終了者</dt><dd>${item.ended_at_is_unknown ? "不明" : esc(actor(item.ended_by))}</dd>` : ""}</dl>${lock ? `<div class="notice">${esc(actor(lock.owner_email))}さんが編集中です。</div>` : ""}<div class="actions maintenance-detail-actions">${item.status !== "completed" ? '<button class="secondary maintenance-edit">編集</button>' : ""}${item.status === "scheduled" ? '<button class="maintenance-start">開始</button><button class="danger maintenance-delete">削除</button>' : ""}${item.status === "in_progress" ? '<button class="maintenance-end">終了</button><button class="danger maintenance-emergency">緊急終了</button>' : ""}</div>${logs.length ? `<h3>例外操作履歴</h3>${logs.map((log) => `<div class="notice"><strong>${log.operation_type === "repair" ? "修復" : "緊急終了"}</strong> ${fmt(log.performed_at)}<br>${esc(log.reason)}</div>`).join("")}` : ""}</article>`;
}

function monthCalendar(items, date) {
  const year = date.getFullYear(), month = date.getMonth();
  const first = new Date(year, month, 1), last = new Date(year, month + 1, 0);
  const cells = Array(first.getDay()).fill(null).concat(Array.from({ length: last.getDate() }, (_, index) => index + 1));
  return `<div class="calendar-head"><button id="calendarPrev" class="secondary" aria-label="前月">‹</button><strong>${year}年${month + 1}月</strong><button id="calendarNext" class="secondary" aria-label="次月">›</button></div><div class="calendar-grid">${["日","月","火","水","木","金","土"].map((day) => `<b>${day}</b>`).join("")}${cells.map((day) => day ? `<div class="calendar-day"><span>${day}</span>${items.filter((item) => { const d=new Date(item.scheduled_start_at); return d.getFullYear()===year&&d.getMonth()===month&&d.getDate()===day; }).map((item) => `<button class="calendar-item status-${item.status}" data-id="${item.id}">${esc(item.title)}</button>`).join("")}</div>` : '<div class="calendar-day empty"></div>').join("")}</div>`;
}

export async function renderMaintenanceAdmin({ supabase, layout, hideMessage, message, failure }) {
  maintenanceClient = supabase;
  stopMaintenancePolling();
  layout("メンテナンス管理", '<a class="button secondary" href="#/admin">予定管理へ戻る</a><a class="button secondary" href="#/">ポータルトップ</a><button id="logout" class="secondary">ログアウト</button>');
  document.querySelector("#logout").onclick = () => supabase.auth.signOut();
  try {
    const state = await maintenanceState(supabase);
    if (!state.isMaintenanceAdmin) throw new Error("メンテナンス管理者権限がありません。");
    const [{ data: items, error }, { data: admins }, { data: logs }, { data: locks }, { data: events }] = await Promise.all([
      supabase.from("maintenances").select("*").order("scheduled_start_at"),
      supabase.from("maintenance_admins").select("email,name,role_name,active"),
      supabase.from("maintenance_operation_logs").select("*").order("performed_at", { ascending: false }),
      supabase.from("maintenance_edit_locks").select("*"),
      supabase.from("events").select("id,title,genre,subtype,starts_at,registration_deadline").gte("starts_at", new Date().toISOString()).lte("starts_at", new Date(Date.now()+62*86400000).toISOString()).order("starts_at"),
    ]);
    if (error) throw error;
    hideMessage();
    let selectedId = items.find((item) => item.status === "in_progress")?.id || items.find((item) => item.status === "scheduled")?.id || null;
    let centerMode = "new", historyPage = 1, calendarDate = new Date();
    const view = document.querySelector("#view");
    view.innerHTML = `<div id="maintenanceStateBanner"></div><div class="maintenance-mobile-tools"><button id="openCalendar" class="secondary">カレンダー</button></div><div class="maintenance-admin-grid"><aside id="maintenanceAside" class="stack"></aside><section class="panel maintenance-center"><div id="maintenanceUpcoming"></div><div class="maintenance-tabs"><button data-mode="new">新規</button><button data-mode="history" class="secondary">履歴</button></div><div id="maintenanceCenter"></div></section><aside id="maintenanceCalendar" class="panel maintenance-calendar"></aside></div><div id="calendarBackdrop" class="calendar-backdrop hidden"></div>`;
    const active = items.filter((item) => item.status === "in_progress");
    const banner = document.querySelector("#maintenanceStateBanner");
    if (state.state === "maintenance_state_error" || active.length > 1) banner.innerHTML = `<section class="notice error"><strong>⚠ メンテナンス状態に異常があります</strong><p>状態を診断し、必要に応じて修復してください。</p><button id="diagnoseState" class="danger">状態を確認・修復する</button></section>`;
    else if (active.length === 1) banner.innerHTML = `<section class="notice maintenance-active"><strong>● メンテナンス実施中</strong><p>${esc(active[0].title)}／${esc(elapsed(active[0].started_at))}</p><button id="activeDetail" class="secondary">詳細</button></section>`;
    const upcoming = items.filter((item) => item.status === "scheduled").slice(0,3);
    document.querySelector("#maintenanceUpcoming").innerHTML = `<h2>メンテナンスの予定</h2>${upcoming.length ? upcoming.map((item) => `<button class="maintenance-list-item" data-id="${item.id}"><span class="tag">予定</span><strong>${esc(item.title)}</strong><small>${fmt(item.scheduled_start_at)}</small></button>`).join("") : '<p class="muted">予定はありません。</p>'}`;
    const recent = items.filter((item) => item.status === "completed").sort((a,b)=>new Date(b.ended_at||b.updated_at)-new Date(a.ended_at||a.updated_at)).slice(0,5);
    document.querySelector("#maintenanceAside").innerHTML = `${active.length===1 ? `<section class="panel"><h3>実施中</h3><button class="maintenance-list-item" data-id="${active[0].id}"><strong>${esc(active[0].title)}</strong></button></section>`:""}<section class="panel"><h3>直近の通常予定</h3>${(events||[]).length ? events.map((event)=>`<article class="maintenance-reference"><strong>${esc(event.title)}</strong><small>${fmt(event.starts_at)}<br>申込締切 ${fmt(event.registration_deadline)}</small></article>`).join(""):'<p class="muted">予定はありません。</p>'}</section><section class="panel"><h3>最近のメンテナンス</h3>${recent.length ? recent.map((item)=>`<button class="maintenance-list-item" data-id="${item.id}"><strong>${esc(item.title)}</strong><small>${fmt(item.ended_at)}</small></button>`).join(""):'<p class="muted">履歴はありません。</p>'}<button id="moreHistory" class="secondary">履歴をもっと見る</button></section>`;
    const center = document.querySelector("#maintenanceCenter");
    const showNew = () => { centerMode="new"; center.innerHTML=`<h2>新規作成</h2>${maintenanceForm()}`; bindForm(null); updateTabs(); };
    const showHistory = () => {
      centerMode="history";
      const completed=items.filter((item)=>item.status==="completed"), pageItems=completed.slice((historyPage-1)*10,historyPage*10);
      center.innerHTML=`<h2>履歴</h2><form id="historyFilter" class="form-grid compact-form"><label>開始日<input type="date" name="start"></label><label>終了日<input type="date" name="end"></label><label class="full">キーワード<input name="keyword" placeholder="タイトル・内部説明"></label><div class="actions full"><button type="button" id="clearHistory" class="secondary">条件をクリア</button><button>検索</button></div></form><div id="historyRows">${pageItems.map((item)=>`<button class="maintenance-list-item" data-id="${item.id}"><span class="tag">終了</span><strong>${esc(item.title)}</strong><small>${fmt(item.ended_at)}</small></button>`).join("")||'<p class="muted">履歴はありません。</p>'}</div><div class="actions"><button id="historyPrev" class="secondary" ${historyPage===1?'disabled':''}>前へ</button><span>${historyPage}ページ</span><button id="historyNext" class="secondary" ${historyPage*10>=completed.length?'disabled':''}>次へ</button></div>`;
      bindList(center); updateTabs();
      center.querySelector("#historyPrev").onclick=()=>{historyPage--;showHistory();}; center.querySelector("#historyNext").onclick=()=>{historyPage++;showHistory();};
      center.querySelector("#clearHistory").onclick=()=>showHistory();
      center.querySelector("#historyFilter").onsubmit=(event)=>{event.preventDefault();const v=Object.fromEntries(new FormData(event.currentTarget));const filtered=completed.filter((item)=>(!v.start||new Date(item.ended_at)>=new Date(`${v.start}T00:00:00`))&&(!v.end||new Date(item.ended_at)<=new Date(`${v.end}T23:59:59`))&&(!v.keyword||`${item.title} ${item.description}`.toLowerCase().includes(v.keyword.toLowerCase())));center.querySelector("#historyRows").innerHTML=filtered.slice(0,10).map((item)=>`<button class="maintenance-list-item" data-id="${item.id}"><strong>${esc(item.title)}</strong><small>${fmt(item.ended_at)}</small></button>`).join("")||'<p class="muted">該当する履歴はありません。</p>';bindList(center.querySelector("#historyRows"));};
    };
    const updateTabs=()=>document.querySelectorAll(".maintenance-tabs button").forEach((button)=>{const active=button.dataset.mode===centerMode;button.classList.toggle("secondary",!active);});
    const showDetail=(id)=>{
      selectedId=id; const item=items.find((row)=>row.id===id); if(!item)return;
      center.innerHTML=detailMarkup(item,admins||[],(logs||[]).filter((log)=>log.maintenance_id===id),(locks||[]).find((lock)=>lock.maintenance_id===id));
      const sameTime=items.filter((row)=>row.status==="scheduled"&&row.scheduled_start_at===item.scheduled_start_at).sort((a,b)=>a.display_order-b.display_order||new Date(a.created_at)-new Date(b.created_at));
      if(sameTime.length>1){
        center.querySelector(".maintenance-detail").insertAdjacentHTML("beforeend",`<section class="maintenance-order"><h3>同一開始時刻内の表示順</h3><p class="muted">項目をドラッグして並べ替えます。</p><div id="maintenanceOrderList">${sameTime.map((row)=>`<div draggable="true" class="maintenance-order-item" data-id="${row.id}">↕ ${esc(row.title)}</div>`).join("")}</div><div class="actions"><button id="resetOrder" class="secondary">基本順へリセット</button><button id="restoreOrder" class="secondary">直前の正常順へ戻す</button></div></section>`);
        const orderList=center.querySelector("#maintenanceOrderList");let dragged=null;
        orderList.querySelectorAll(".maintenance-order-item").forEach((row)=>{row.ondragstart=()=>dragged=row;row.ondragover=(event)=>event.preventDefault();row.ondrop=async(event)=>{event.preventDefault();if(!dragged||dragged===row)return;const boxes=[...orderList.children],from=boxes.indexOf(dragged),to=boxes.indexOf(row);orderList.insertBefore(dragged,to>from?row.nextSibling:row);const ordered=[...orderList.children].map((node)=>node.dataset.id);const{error}=await supabase.rpc("reorder_maintenance_group",{p_scheduled_start_at:item.scheduled_start_at,p_ordered_ids:ordered});if(error)return failure(error);message("表示順を保存しました。");};});
        const restore=async(mode)=>{const{error}=await supabase.rpc("restore_maintenance_group_order",{p_scheduled_start_at:item.scheduled_start_at,p_mode:mode});if(error)return failure(error);message("表示順を復元しました。");renderMaintenanceAdmin({supabase,layout,hideMessage,message,failure});};
        center.querySelector("#resetOrder").onclick=()=>restore("base");center.querySelector("#restoreOrder").onclick=()=>restore("last_snapshot");
      }
      center.querySelector(".maintenance-edit")?.addEventListener("click",()=>beginEdit(item));
      center.querySelector(".maintenance-start")?.addEventListener("click",()=>lifecycle("start_maintenance",item,"開始すると一般利用者はポータルを利用できなくなります。開始しますか？"));
      center.querySelector(".maintenance-end")?.addEventListener("click",()=>lifecycle("end_maintenance",item,"メンテナンスを終了し、一般利用を再開しますか？"));
      center.querySelector(".maintenance-delete")?.addEventListener("click",()=>remove(item));
      center.querySelector(".maintenance-emergency")?.addEventListener("click",()=>emergency(item));
    };
    const bindList=(root)=>root.querySelectorAll("[data-id]").forEach((button)=>button.onclick=()=>showDetail(button.dataset.id));
    const beginEdit=async(item)=>{const {data,error}=await supabase.rpc("acquire_maintenance_lock",{p_maintenance_id:item.id});if(error)return failure(error);if(!data.acquired)return failure(`${data.ownerName||data.ownerEmail}さんが編集中です。`);currentLockId=item.id;center.innerHTML=`<h2>編集</h2>${maintenanceForm(item)}`;bindForm(item);lockTimer=setInterval(()=>supabase.rpc("heartbeat_maintenance_lock",{p_maintenance_id:item.id}),120000);};
    const release=async()=>{clearInterval(lockTimer);if(currentLockId)await supabase.rpc("release_maintenance_lock",{p_maintenance_id:currentLockId});currentLockId=null;};
    const bindForm=(item)=>{
      const form=center.querySelector("#maintenanceForm"),end=form.elements.scheduled_end_at,unknown=form.elements.end_unknown,requestId=crypto.randomUUID();
      const sync=()=>{end.disabled=unknown.checked; if(unknown.checked)end.value="";};unknown.onchange=sync;sync();
      form.querySelector("#cancelMaintenanceEdit").onclick=async()=>{await release();item?showDetail(item.id):showNew();};
      form.onsubmit=async(event)=>{event.preventDefault();const values=Object.fromEntries(new FormData(form));try{validateForm(values,item);const args=item?{p_id:item.id,p_expected_updated_at:item.updated_at,p_title:values.title,p_scheduled_start_at:iso(values.scheduled_start_at),p_scheduled_end_at:unknown.checked?null:iso(values.scheduled_end_at),p_message:values.message,p_contact:values.contact,p_description:values.description}:{p_client_request_id:requestId,p_title:values.title,p_scheduled_start_at:iso(values.scheduled_start_at),p_scheduled_end_at:unknown.checked?null:iso(values.scheduled_end_at),p_message:values.message,p_contact:values.contact,p_description:values.description};let {error}=await supabase.rpc(item?"update_maintenance":"create_maintenance",args);if(error){const check=item?await supabase.from("maintenances").select("*").eq("id",item.id).maybeSingle():await supabase.from("maintenances").select("*").eq("client_request_id",requestId).maybeSingle();const saved=check.data&&(!item||(check.data.message===values.message.trim()&&check.data.description===values.description.trim()&&check.data.scheduled_end_at===(unknown.checked?null:iso(values.scheduled_end_at))));if(!saved)throw error;}await release();message(item?"メンテナンス予定を更新しました。":"メンテナンス予定を作成しました。");return renderMaintenanceAdmin({supabase,layout,hideMessage,message,failure});}catch(error){failure(error);}};
    };
    const lifecycle=async(rpc,item,promptText)=>{if(!confirm(promptText))return;const {error}=await supabase.rpc(rpc,{p_id:item.id});if(error){const{data}=await supabase.from("maintenances").select("status").eq("id",item.id).maybeSingle();const expected=rpc==="start_maintenance"?"in_progress":"completed";if(data?.status!==expected)return failure(error);}message(rpc==="start_maintenance"?"メンテナンスを開始しました。":"メンテナンスを終了しました。");renderMaintenanceAdmin({supabase,layout,hideMessage,message,failure});};
    const remove=async(item)=>{if(!confirm(`「${item.title}」を削除しますか？`))return;const{error}=await supabase.rpc("delete_maintenance",{p_id:item.id,p_expected_updated_at:item.updated_at});if(error){const{data}=await supabase.from("maintenances").select("id").eq("id",item.id).maybeSingle();if(data)return failure(error);}message("予定を削除しました。");renderMaintenanceAdmin({supabase,layout,hideMessage,message,failure});};
    const emergency=async(item)=>{const reason=prompt(`「${item.title}」を緊急終了します。編集中の未保存内容は破棄され、一般利用が再開します。\n理由を入力してください。`);if(!reason?.trim())return;const{error}=await supabase.rpc("emergency_end_maintenance",{p_id:item.id,p_reason:reason});if(error){const{data}=await supabase.from("maintenances").select("status").eq("id",item.id).maybeSingle();if(data?.status!=="completed")return failure(error);}message("緊急終了しました。監査ログへ記録されています。");renderMaintenanceAdmin({supabase,layout,hideMessage,message,failure});};
    const diagnose=async()=>{const{data,error}=await supabase.rpc("diagnose_maintenance_state");if(error)return failure(error);center.innerHTML=`<h2>メンテナンス状態の診断・修復</h2>${data.ok?'<div class="notice">問題は検出されませんでした。</div>':data.issues.map((issue)=>`<div class="notice error">${esc(issue.message)}</div>`).join("")}<p class="muted">異常レコードを選択し、状態を確認したうえで修復してください。修復理由は監査ログに保存されます。</p>${items.map((item)=>`<button class="maintenance-list-item repair-target" data-id="${item.id}"><strong>${esc(item.title)}</strong><small>${statusLabel(item.status)}</small></button>`).join("")}`;center.querySelectorAll(".repair-target").forEach((button)=>button.onclick=()=>repair(items.find((item)=>item.id===button.dataset.id)));};
    const repair=async(item)=>{
      const action=prompt("修復後の状態を入力してください：scheduled / in_progress / completed / delete");
      if(!["scheduled","in_progress","completed","delete"].includes(action))return;
      if(action==="delete"&&!confirm("この記録を削除します。履歴本体は失われますが修復監査ログは残ります。続けますか？"))return;
      const reason=prompt("修復理由を入力してください。");if(!reason?.trim())return;
      const adminGuide=(admins||[]).map((admin)=>`${admin.name}: ${admin.email}${admin.active?"":"（無効）"}`).join("\n");
      const actual=(kind,currentAt,currentBy,currentEstimated,currentUnknown)=>{
        const accuracy=prompt(`${kind}日時の確度を入力してください：exact / estimated / unknown`,currentUnknown?"unknown":currentEstimated?"estimated":"exact");
        if(!["exact","estimated","unknown"].includes(accuracy))throw new Error(`${kind}日時の確度を確認してください。`);
        if(accuracy==="unknown")return{at:null,by:null,estimated:false,unknown:true};
        const at=prompt(`${kind}日時を日本時間で入力してください（YYYY-MM-DDTHH:mm）`,local(currentAt));
        if(!at)throw new Error(`${kind}日時を入力してください。`);
        const by=prompt(`${kind}者のメールアドレスを入力してください。\n${adminGuide}`,currentBy||"");
        if(!by)throw new Error(`${kind}者を入力してください。`);
        return{at:iso(at),by:by.trim().toLowerCase(),estimated:accuracy==="estimated",unknown:false};
      };
      try{
        const start=["in_progress","completed"].includes(action)?actual("開始",item.started_at,item.started_by,item.started_at_is_estimated,item.started_at_is_unknown):{at:null,by:null,estimated:false,unknown:false};
        const end=action==="completed"?actual("終了",item.ended_at,item.ended_by,item.ended_at_is_estimated,item.ended_at_is_unknown):{at:null,by:null,estimated:false,unknown:false};
        const args={p_id:item.id,p_action:action,p_reason:reason,p_started_at:start.at,p_started_by:start.by,p_started_estimated:start.estimated,p_started_unknown:start.unknown,p_ended_at:end.at,p_ended_by:end.by,p_ended_estimated:end.estimated,p_ended_unknown:end.unknown};
        const{error}=await supabase.rpc("repair_maintenance",args);if(error)throw error;
        const {data:diagnosis,error:diagnosisError}=await supabase.rpc("diagnose_maintenance_state");if(diagnosisError)throw diagnosisError;
        message(diagnosis.ok?"状態を修復し、再診断でも問題がないことを確認しました。":"修復を保存しましたが、ほかの問題が残っています。");
        renderMaintenanceAdmin({supabase,layout,hideMessage,message,failure});
      }catch(error){failure(error);}
    };
    const drawCalendar=()=>{const target=document.querySelector("#maintenanceCalendar");target.innerHTML=`<button id="closeCalendar" class="secondary calendar-close">×</button>${monthCalendar(items,calendarDate)}`;target.querySelector("#calendarPrev").onclick=()=>{calendarDate=new Date(calendarDate.getFullYear(),calendarDate.getMonth()-1,1);drawCalendar();};target.querySelector("#calendarNext").onclick=()=>{calendarDate=new Date(calendarDate.getFullYear(),calendarDate.getMonth()+1,1);drawCalendar();};target.querySelector("#closeCalendar").onclick=closeCalendar;bindList(target);};
    const closeCalendar=()=>{document.querySelector("#maintenanceCalendar").classList.remove("is-open");document.querySelector("#calendarBackdrop").classList.add("hidden");};
    document.querySelector("#openCalendar").onclick=()=>{document.querySelector("#maintenanceCalendar").classList.add("is-open");document.querySelector("#calendarBackdrop").classList.remove("hidden");};document.querySelector("#calendarBackdrop").onclick=closeCalendar;
    document.querySelectorAll(".maintenance-tabs button").forEach((button)=>button.onclick=()=>button.dataset.mode==="new"?showNew():showHistory());
    document.querySelector("#moreHistory").onclick=showHistory;document.querySelector("#activeDetail")?.addEventListener("click",()=>showDetail(active[0].id));document.querySelector("#diagnoseState")?.addEventListener("click",diagnose);
    bindList(document.querySelector("#maintenanceAside"));bindList(document.querySelector("#maintenanceUpcoming"));drawCalendar();showNew();
    permissionTimer=setInterval(async()=>{try{const next=await maintenanceState(supabase);if(!next.isMaintenanceAdmin){stopMaintenancePolling();failure("このアカウントは現在、メンテナンス管理者として承認されていません。数秒後にポータルトップへ移動します。");setTimeout(()=>location.hash="/",4000);}}catch(error){console.error(error);}},60000);
  } catch (error) { failure(error); }
}

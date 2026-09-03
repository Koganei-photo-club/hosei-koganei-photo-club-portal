import "./styles.css";
import { configured, googleClientId, supabase } from "./supabase.js";

const app = document.querySelector("#app");
let session = null;
let overdueChecked = false;

const esc = (value) => {
  const node = document.createElement("div");
  node.textContent = String(value ?? "");
  return node.innerHTML;
};
const fmt = (value) =>
  value ? new Date(value).toLocaleString("ja-JP") : "未定";
const fiscalYear = () => {
  const d = new Date();
  return d.getFullYear() - (d.getMonth() < 3 ? 1 : 0);
};
const eventLabel = (e) =>
  e.genre === "camp"
    ? "合宿"
    : e.genre === "exhibition"
      ? "写真展"
      : e.subtype === "dining"
        ? "全体会・お食事会"
        : "全体会・撮影会";
const route = () => location.hash.replace(/^#/, "") || "/";

function layout(title = "活動ポータル", actions = "") {
  app.innerHTML = `<header class="site-header"><div><p class="eyebrow">HOSEI PHOTO CLUB</p><h1 class="site-title">${esc(title)}</h1></div><div class="header-actions">${actions}</div></header><main class="page"><div id="message" class="notice">読み込んでいます…</div><div id="view"></div></main>`;
}
function message(text, error = false) {
  const box = document.querySelector("#message");
  box.textContent = text;
  box.classList.remove("hidden");
  box.classList.toggle("error", error);
}
function hideMessage() {
  document.querySelector("#message")?.classList.add("hidden");
}
function failure(error) {
  message(
    typeof error === "string"
      ? error
      : error?.message || "処理に失敗しました。",
    true,
  );
}

async function boot() {
  if (!configured) {
    layout();
    failure("Supabaseの接続先が未設定です。.envを設定してください。");
    return;
  }
  const { data } = await supabase.auth.getSession();
  session = data.session;
  supabase.auth.onAuthStateChange((_event, next) => {
    session = next;
    setTimeout(() => (next ? navigate() : renderAuth()), 0);
  });
  if (session) navigate();
  else renderAuth();
}

function loadGoogleIdentity() {
  if (window.google?.accounts?.id) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const existing = document.querySelector("#google-identity-script");
    if (existing) {
      existing.addEventListener("load", resolve, { once: true });
      existing.addEventListener("error", reject, { once: true });
      return;
    }
    const script = document.createElement("script");
    script.id = "google-identity-script";
    script.src = "https://accounts.google.com/gsi/client";
    script.async = true;
    script.defer = true;
    script.onload = resolve;
    script.onerror = () =>
      reject(
        new Error(
          "Googleログインを読み込めませんでした。外部ブラウザで開き直してください。",
        ),
      );
    document.head.appendChild(script);
  });
}

async function createGoogleNonce() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  const nonce = btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(nonce),
  );
  const hashed = Array.from(new Uint8Array(digest), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
  return { nonce, hashed };
}

async function renderAuth() {
  layout("活動ポータル");
  hideMessage();
  app.insertAdjacentHTML(
    "beforeend",
    `<section class="auth-layer"><div class="panel auth-card"><p class="eyebrow">SECURE SIGN IN</p><h2>Googleアカウントでログイン</h2><p class="copy">部員は大学のGoogleアカウント、幹部は管理者として登録されたGoogleアカウントを使用してください。</p><div id="googleSignIn"></div><p id="authMessage" class="muted">Googleログインを準備しています…</p><p class="muted">LINE内で開いている場合は、外部ブラウザで開いてください。</p></div></section>`,
  );
  const authMessage = document.querySelector("#authMessage");
  if (!googleClientId) {
    authMessage.textContent = "Google Client IDが未設定です。";
    return;
  }
  try {
    await loadGoogleIdentity();
    const { nonce, hashed } = await createGoogleNonce();
    google.accounts.id.initialize({
      client_id: googleClientId,
      nonce: hashed,
      use_fedcm_for_prompt: true,
      itp_support: true,
      auto_select: false,
      callback: async (response) => {
        authMessage.textContent = "ログイン情報を確認しています…";
        const { error } = await supabase.auth.signInWithIdToken({
          provider: "google",
          token: response.credential,
          nonce,
        });
        if (error)
          authMessage.textContent = `ログインできませんでした：${error.message}`;
      },
    });
    google.accounts.id.renderButton(document.querySelector("#googleSignIn"), {
      type: "standard",
      shape: "rectangular",
      theme: "outline",
      text: "continue_with",
      size: "large",
      logo_alignment: "left",
      width: 300,
    });
    authMessage.textContent = "";
  } catch (error) {
    authMessage.textContent =
      error.message || "Googleログインを準備できませんでした。";
  }
}

function renderAccessDenied(email) {
  layout("利用対象外のアカウント");
  hideMessage();
  document.querySelector("#view").innerHTML =
    `<section class="panel auth-card"><p class="eyebrow">ACCESS DENIED</p><h2>対象アカウントではありません</h2><p class="copy">${esc(email)} は、現在の部員名簿または管理者一覧に登録されていません。</p><div class="actions"><button id="switchAccount">アカウントを切り替える</button></div></section>`;
  document.querySelector("#switchAccount").onclick = async () => {
    google?.accounts?.id?.disableAutoSelect();
    await supabase.auth.signOut();
  };
}

async function navigate() {
  try {
    if (!overdueChecked) {
      overdueChecked = true;
      const { error } = await supabase.rpc(
        "apply_overdue_payment_cancellations",
      );
      if (error) console.warn("期限超過処理を実行できませんでした。", error);
    }
    const context = await getContext();
    if (!context.member && !context.admin) {
      renderAccessDenied(context.email);
      return;
    }
    const path = route();
    if (path.startsWith("/event/"))
      return renderEvent(path.split("/")[2], context);
    if (path === "/admin") return renderAdmin(context);
    return renderPortal(context);
  } catch (error) {
    layout();
    failure(error);
  }
}

async function getContext() {
  const email = session.user.email.toLowerCase();
  const [
    { data: member, error: memberError },
    { data: admin, error: adminError },
  ] = await Promise.all([
    supabase
      .from("members")
      .select("*,membership_years(*)")
      .eq("email", email)
      .maybeSingle(),
    supabase
      .from("admins")
      .select("email,name,role_name")
      .eq("email", email)
      .eq("active", true)
      .maybeSingle(),
  ]);
  if (memberError) throw memberError;
  if (adminError) throw adminError;
  return { email, member, admin };
}

async function renderPortal(context) {
  layout(
    "活動ポータル",
    '<button id="logout" class="secondary">ログアウト</button>',
  );
  document.querySelector("#logout").onclick = () => supabase.auth.signOut();
  try {
    if (context.admin)
      document
        .querySelector(".header-actions")
        .insertAdjacentHTML(
          "afterbegin",
          '<a class="button secondary" href="#/admin">管理画面</a>',
        );
    const { data: events, error } = await supabase
      .from("events")
      .select("*,event_responses(*)")
      .is("deleted_at", null)
      .order("starts_at");
    if (error) throw error;
    let exhibitionEntries = {};
    if (context.member) {
      const { data: entries, error: entryError } = await supabase
        .from("exhibition_entries")
        .select(
          "event_id,status,exhibition_works(status,orientation,print_size)",
        )
        .eq("member_id", context.member.id);
      if (entryError) throw entryError;
      exhibitionEntries = Object.fromEntries(
        (entries || []).map((entry) => [entry.event_id, entry]),
      );
    }
    hideMessage();
    const view = document.querySelector("#view"),
      membership = context.member?.membership_years?.find(
        (y) => y.fiscal_year === fiscalYear() && y.active,
      );
    view.innerHTML = `<section class="panel"><span class="tag">MEMBER</span><h2>${esc(context.member?.name || context.email)}さん</h2>${context.member ? `<p>${esc([context.member.grade, context.member.faculty || context.member.graduate_school, context.member.department || context.member.major].filter(Boolean).join("・"))}</p><p>部員ID：${esc(context.member.member_no)}</p><p class="status">${membership ? `${fiscalYear()}年度 在籍中` : `${fiscalYear()}年度の在籍登録はありません`}</p>` : "<p>部員名簿に登録されていません。</p>"}</section><div class="section-head"><p class="eyebrow">OPEN EVENTS</p><h2>現在参加できる活動</h2></div><section id="events" class="grid"></section><div class="section-head"><p class="eyebrow">MY EXHIBITION</p><h2>写真展マイページ</h2></div><section id="archives" class="stack"></section>`;
    const eventRoot = document.querySelector("#events");
    if (!events?.length)
      eventRoot.innerHTML =
        '<div class="panel">現在参加できる活動はありません。</div>';
    events?.forEach((event) => {
      const response = event.event_responses?.[0],
        entry = exhibitionEntries[event.id],
        entryWorks = (entry?.exhibition_works || []).filter(
          (work) => work.status !== "withdrawn",
        ),
        state = entryWorks.some(
          (work) =>
            work.status === "rejected" || !work.orientation || !work.print_size,
        )
          ? "要修正の作品があります"
          : entryWorks.length &&
              entryWorks.every((work) => work.status === "accepted")
            ? "全作品を確認済み"
            : entry?.status === "submitted"
              ? "出展申込済み"
              : entry?.status === "draft"
                ? "出展申込を下書き保存中"
                : entry?.status === "withdrawn"
                  ? "出展申込を取り下げ済み"
                  : "";
      eventRoot.insertAdjacentHTML(
        "beforeend",
        `<a class="card" href="#/event/${event.id}"><div><span class="tag">${eventLabel(event)}</span><h3>${esc(event.title)}</h3><p>${fmt(event.starts_at)}・${esc(event.place)}</p>${event.genre === "exhibition" && state ? `<p class="status">${state}</p>` : response ? `<p class="status">${response.cancelled_at ? "キャンセル済み" : `回答済み：${esc(response.attendance)}`}</p>` : ""}</div><strong>→</strong></a>`,
      );
    });
    await renderArchives();
  } catch (error) {
    failure(error);
  }
}

async function renderArchives() {
  const { data: works, error } = await supabase
    .from("archive_works")
    .select("*,archive_exhibitions(*),archive_work_comments(*)")
    .order("display_no");
  if (error) throw error;
  const root = document.querySelector("#archives");
  if (!works?.length) {
    root.innerHTML =
      '<div class="panel muted">公開中の作品アーカイブはありません。</div>';
    return;
  }
  const grouped = works.reduce((result, work) => {
    (result[work.exhibition_id] ??= []).push(work);
    return result;
  }, {});
  Object.values(grouped).forEach((items) =>
    root.insertAdjacentHTML(
      "beforeend",
      `<article class="panel"><span class="tag">EXHIBITION ARCHIVE</span><h3>${esc(items[0].archive_exhibitions.title)}</h3><div class="grid">${items.map((w) => `<section><p class="tag">No.${esc(w.display_no)}</p><h3>${esc(w.title)}</h3><p><strong>${w.favorite_count}票</strong>・${w.favorite_rate}%</p><details><summary>寄せられた感想（${w.archive_work_comments.length}件）</summary><ul>${w.archive_work_comments.map((c) => `<li>${esc(c.comment)}</li>`).join("")}</ul></details></section>`).join("")}</div></article>`,
    ),
  );
}

const exhibitionWorkStatus = (value) =>
  value === "submitted"
    ? "提出済み"
    : value === "accepted"
      ? "確認済み"
      : value === "rejected"
        ? "要修正"
        : value === "withdrawn"
          ? "取り下げ"
          : "下書き";
const allowedOriginalTypes = new Set([
  "image/jpeg",
  "image/png",
  "image/tiff",
  "image/heic",
  "image/heif",
]);
const allowedQrTypes = new Set(["image/jpeg", "image/png", "image/webp"]);
const originalExtension = (file) =>
  ({
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/tiff": "tiff",
    "image/heic": "heic",
    "image/heif": "heif",
  })[file.type];
const qrExtension = (file) =>
  ({ "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" })[
    file.type
  ];
const safeStorageFileName = (value, fallback) =>
  value.replace(/[\\/:*?"<>|\u0000-\u001f]/g, "_").trim() || fallback;
const orientationLabel = (value) =>
  value === "portrait" ? "縦" : value === "landscape" ? "横" : "未選択";
const printSizeLabel = (size, detail = "") =>
  size === "composite"
    ? `組み写真${detail ? `（${detail}）` : ""}`
    : size === "other"
      ? `その他${detail ? `（${detail}）` : ""}`
      : size || "未選択";
const managedOriginalFileName = (member, work) => {
  const ext = work.original_image_path?.split(".").pop() || "jpg";
  return `${safeStorageFileName(member.name, member.member_no)}_作品${work.sort_order}.${ext}`;
};

async function createWorkPreview(file) {
  if (!["image/jpeg", "image/png"].includes(file.type)) return null;
  let source = null,
    objectUrl = "";
  try {
    if (window.createImageBitmap) source = await createImageBitmap(file);
    else {
      objectUrl = URL.createObjectURL(file);
      source = await new Promise((resolve, reject) => {
        const image = new Image();
        image.onload = () => resolve(image);
        image.onerror = () => reject(new Error("画像を読み込めませんでした。"));
        image.src = objectUrl;
      });
    }
    const scale = Math.min(1, 1800 / Math.max(source.width, source.height)),
      canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(source.width * scale));
    canvas.height = Math.max(1, Math.round(source.height * scale));
    canvas
      .getContext("2d")
      .drawImage(source, 0, 0, canvas.width, canvas.height);
    const blob = await new Promise((resolve, reject) =>
      canvas.toBlob(
        (value) =>
          value
            ? resolve(value)
            : reject(new Error("プレビューを生成できませんでした。")),
        "image/webp",
        0.86,
      ),
    );
    return new File([blob], "preview.webp", { type: "image/webp" });
  } finally {
    source?.close?.();
    if (objectUrl) URL.revokeObjectURL(objectUrl);
  }
}

async function renderExhibitionEvent(event, context) {
  layout(
    "写真展出展申込",
    '<a class="button secondary" href="#/">ポータルトップに戻る</a>',
  );
  try {
    if (!context.member)
      throw new Error("出展申込には部員名簿への登録が必要です。");
    const { data: entry, error } = await supabase
      .from("exhibition_entries")
      .select("*,exhibition_works(*)")
      .eq("event_id", event.id)
      .eq("member_id", context.member.id)
      .maybeSingle();
    if (error) throw error;
    hideMessage();
    const view = document.querySelector("#view"),
      allWorks = (entry?.exhibition_works || []).sort(
        (a, b) => a.sort_order - b.sort_order,
      ),
      works = allWorks.filter((work) => work.status !== "withdrawn"),
      hasRejected = works.some(
        (work) =>
          work.status === "rejected" || !work.orientation || !work.print_size,
      ),
      allAccepted =
        works.length > 0 &&
        works.every(
          (work) =>
            work.status === "accepted" && work.orientation && work.print_size,
        ),
      entryState = hasRejected
        ? "要修正"
        : allAccepted
          ? "確認済み"
          : entry
            ? entry.status === "submitted"
              ? "申込済み"
              : entry.status === "withdrawn"
                ? "取り下げ済み"
                : "下書き"
            : "未入力";
    view.innerHTML = `<section class="panel"><span class="tag">EXHIBITION ENTRY</span><h2>${esc(event.exhibition_title || event.title)}</h2><dl><dt>日時</dt><dd>${fmt(event.starts_at)}${event.ends_at ? ` 〜 ${fmt(event.ends_at)}` : ""}</dd><dt>場所</dt><dd>${esc(event.place)}</dd><dt>連絡先</dt><dd>${esc(event.contact)}</dd><dt>出展上限</dt><dd>1人 ${event.max_works}作品</dd></dl><p class="copy">${esc(event.details)}</p></section><section class="panel exhibition-entry-panel"><div class="entry-heading"><div><span class="tag">YOUR ENTRY</span><h2>出展作品を登録</h2></div><span class="status">${entryState}</span></div>${hasRejected ? '<div class="notice error">要修正になっている作品があります。該当作品を修正し、変更内容を再提出してください。</div>' : ""}<p class="muted">原画像は非公開で保存され、本人と管理者だけが閲覧できます。JPEG・PNG・TIFF・HEIC・HEIF、1作品50MBまでです。</p><form id="exhibitionEntryForm" class="stack"><div id="workEditors" class="stack"></div><div class="actions work-actions"><button type="button" id="addWork" class="secondary">作品を追加</button></div><label>出展全体に関する備考<textarea name="entry_note" rows="3">${esc(entry?.note || "")}</textarea></label><div class="notice">「下書き保存」では提出は完了しません。「出展申込を確定」を押すと、登録した全作品が提出済みになります。</div><div class="actions"><button type="button" id="saveEntryDraft" class="secondary">下書き保存</button><button type="submit" id="submitEntry">${entry?.status === "submitted" ? "申込済み" : "出展申込を確定"}</button></div></form></section>`;
    const form = document.querySelector("#exhibitionEntryForm"),
      editors = document.querySelector("#workEditors"),
      addButton = document.querySelector("#addWork");
    const addEditor = (work = null) => {
      const activeCount = editors.querySelectorAll(".work-editor").length;
      if (activeCount >= event.max_works) {
        message(`出展可能作品数は${event.max_works}作品までです。`, true);
        return;
      }
      const usedSlots = new Set(
          [...editors.querySelectorAll(".work-editor")].map((editor) =>
            Number(editor.dataset.sortOrder),
          ),
        ),
        slot =
          work?.sort_order ||
          Array.from({ length: event.max_works }, (_, index) => index + 1).find(
            (number) => !usedSlots.has(number),
          );
      const locked =
          work?.status === "accepted" && work?.orientation && work?.print_size,
        storedFileName =
          work?.original_file_name ||
          work?.original_image_path?.split("/").pop() ||
          "",
        storedQrName =
          work?.instagram_qr_file_name ||
          work?.instagram_qr_path?.split("/").pop() ||
          "",
        fileInput = `<input type="file" name="original" class="${work?.original_image_path ? "hidden" : ""}" accept="image/jpeg,image/png,image/tiff,image/heic,image/heif,.jpg,.jpeg,.png,.tif,.tiff,.heic,.heif" ${locked ? "disabled" : ""}>`,
        fileControl = work?.original_image_path
          ? `<div class="registered-file"><span>登録済み：<strong>${esc(storedFileName)}</strong></span>${locked ? "" : '<button type="button" class="secondary replace-image">画像を差し替える</button>'}</div>${fileInput}`
          : fileInput,
        qrInput = `<input type="file" name="instagram_qr" class="${work?.instagram_qr_path ? "hidden" : ""}" accept="image/jpeg,image/png,image/webp,.jpg,.jpeg,.png,.webp" ${locked ? "disabled" : ""}>`,
        qrControl = work?.instagram_qr_path
          ? `<div class="registered-file"><span>登録済み：<strong>${esc(storedQrName)}</strong></span>${locked ? "" : '<button type="button" class="secondary replace-qr">QRコードを差し替える</button>'}</div>${qrInput}`
          : qrInput;
      editors.insertAdjacentHTML(
        "beforeend",
        `<article class="work-editor" data-id="${esc(work?.id || "")}" data-sort-order="${work?.sort_order || ""}" data-original-path="${esc(work?.original_image_path || "")}" data-original-file-name="${esc(storedFileName)}" data-preview-path="${esc(work?.preview_image_path || "")}" data-qr-path="${esc(work?.instagram_qr_path || "")}" data-qr-file-name="${esc(storedQrName)}" data-locked="${locked}"><div class="work-editor-head"><div><span class="tag">WORK ${activeCount + 1}</span><h3>${work ? esc(exhibitionWorkStatus(work.status)) : "新しい作品"}</h3></div><button type="button" class="danger remove-work" ${locked ? "disabled" : ""}>${work && work.status !== "draft" ? "取り下げ" : "削除"}</button></div><div class="form-grid"><label>作品名（提出時必須）<input name="title" value="${esc(work?.title || "")}" ${locked ? "disabled" : ""}></label><label>原画像${work?.original_image_path ? "（登録済み）" : "（提出時必須）"}${fileControl}</label><fieldset class="full print-fields"><legend>展示仕様</legend><p class="muted">原則としてA4以上での出展をお願いします。組み写真ではL判・2L判も選択できます。</p><div class="form-grid"><label>作品の向き（必須）<select name="orientation" ${locked ? "disabled" : ""}><option value="">選択してください</option><option value="portrait" ${work?.orientation === "portrait" ? "selected" : ""}>縦</option><option value="landscape" ${work?.orientation === "landscape" ? "selected" : ""}>横</option></select></label><label>出展サイズ（必須）<select name="print_size" ${locked ? "disabled" : ""}><option value="">選択してください</option><option value="A4" ${work?.print_size === "A4" ? "selected" : ""}>A4</option><option value="A3" ${work?.print_size === "A3" ? "selected" : ""}>A3</option><option value="A2" ${work?.print_size === "A2" ? "selected" : ""}>A2</option><option value="composite" ${work?.print_size === "composite" ? "selected" : ""}>組み写真</option><option value="other" ${work?.print_size === "other" ? "selected" : ""}>その他</option></select></label><label class="full print-size-detail ${["composite", "other"].includes(work?.print_size) ? "" : "hidden"}">サイズ詳細（組み写真・その他は必須）<input name="print_size_detail" maxlength="500" value="${esc(work?.print_size_detail || "")}" placeholder="例：2L判を4枚" ${locked ? "disabled" : ""}></label></div></fieldset><fieldset class="full caption-fields"><legend>キャプション</legend><div class="form-grid"><label>作者名・ペンネーム（必須）<input name="artist_name" maxlength="100" value="${esc(work?.artist_name || "")}" ${locked ? "disabled" : ""}></label><label>Camera（必須）<input name="camera_name" maxlength="200" value="${esc(work?.camera_name || "")}" ${locked ? "disabled" : ""}></label><label class="full">Lens, other（任意）<input name="lens_other" maxlength="500" value="${esc(work?.lens_other || "")}" placeholder="レンズ名、フィルム名など" ${locked ? "disabled" : ""}></label><label class="full">Description（任意）<textarea name="description" maxlength="3000" rows="3" ${locked ? "disabled" : ""}>${esc(work?.description || work?.caption || "")}</textarea></label></div></fieldset><label class="full">Instagram QRコード（任意）${qrControl}</label><label class="full">作品に関する備考<textarea name="note" rows="2" ${locked ? "disabled" : ""}>${esc(work?.note || "")}</textarea></label></div>${work?.preview_image_path ? '<div class="work-preview"><span class="muted">登録済みプレビューを読み込んでいます…</span></div>' : work?.original_image_path ? '<p class="muted">原画像登録済み（この形式のプレビューはブラウザでは生成されません）</p>' : ""}</article>`,
      );
      const editor = editors.lastElementChild;
      editor.dataset.sortOrder = String(slot);
      editor.querySelector(".tag").textContent = `作品 ${slot}`;
      editor.querySelector(".remove-work").textContent = "削除";
      editor
        .querySelector(".replace-image")
        ?.addEventListener("click", (click) => {
          if (
            !confirm(
              `作品${editor.dataset.sortOrder}の原画像を差し替えます。保存すると現在の原画像は破棄され、元に戻せません。続けますか？`,
            )
          )
            return;
          click.currentTarget.classList.add("hidden");
          const input = editor.querySelector("[name=original]");
          input.classList.remove("hidden");
          input.click();
        });
      editor
        .querySelector(".replace-qr")
        ?.addEventListener("click", (click) => {
          click.currentTarget.classList.add("hidden");
          editor
            .querySelector("[name=instagram_qr]")
            .classList.remove("hidden");
        });
      editor.querySelector("[name=original]").onchange = (change) => {
        const file = change.target.files[0];
        if (file && !allowedOriginalTypes.has(file.type)) {
          change.target.value = "";
          failure(
            "対応していない画像形式です。JPEG・PNG・TIFF・HEIC・HEIFを選択してください。",
          );
        }
      };
      editor.querySelector("[name=instagram_qr]").onchange = (change) => {
        const file = change.target.files[0];
        if (file && !allowedQrTypes.has(file.type)) {
          change.target.value = "";
          failure("QRコードはJPEG・PNG・WebPを選択してください。");
        }
      };
      const sizeSelect = editor.querySelector("[name=print_size]"),
        sizeDetail = editor.querySelector(".print-size-detail");
      sizeSelect.onchange = () =>
        sizeDetail.classList.toggle(
          "hidden",
          !["composite", "other"].includes(sizeSelect.value),
        );
      editor.querySelector(".remove-work").onclick = async () => {
        if (!work) {
          editor.remove();
          renumber();
          updateEntryButtons();
          return;
        }
        if (
          !confirm(
            `作品${work.sort_order}「${work.title || "名称未入力"}」を削除しますか？保存画像も破棄され、元に戻せません。`,
          )
        )
          return;
        try {
          if (entry?.status === "submitted") {
            const { error: draftError } = await supabase
              .from("exhibition_entries")
              .update({ status: "draft" })
              .eq("id", entry.id);
            if (draftError) throw draftError;
          }
          const paths = [
            work.original_image_path,
            work.preview_image_path,
            work.instagram_qr_path,
          ].filter(Boolean);
          for (const [bucket, path] of [
            ["exhibition-originals", work.original_image_path],
            ["exhibition-previews", work.preview_image_path],
            ["exhibition-previews", work.instagram_qr_path],
          ])
            if (path) {
              const { error: removeError } = await supabase.storage
                .from(bucket)
                .remove([path]);
              if (removeError) throw removeError;
            }
          if (work.status !== "draft") {
            const { error: workDraftError } = await supabase
              .from("exhibition_works")
              .update({ status: "draft" })
              .eq("id", work.id);
            if (workDraftError) throw workDraftError;
          }
          const { error: removeRowError } = await supabase
            .from("exhibition_works")
            .delete()
            .eq("id", work.id);
          if (removeRowError) throw removeRowError;
          await renderExhibitionEvent(event, context);
          message(
            paths.length
              ? "作品と保存画像を削除しました。"
              : "作品を削除しました。",
          );
        } catch (removeError) {
          failure(removeError);
        }
      };
      if (work?.preview_image_path)
        loadWorkPreview(editor, work.preview_image_path);
      renumber();
    };
    const renumber = () => {
      editors.querySelectorAll(".work-editor").forEach((editor) => {
        editor.querySelector(".tag").textContent =
          `作品 ${editor.dataset.sortOrder}`;
      });
      addButton.disabled =
        editors.querySelectorAll(".work-editor").length >= event.max_works;
    };
    const loadWorkPreview = async (editor, path) => {
      const { data, error } = await supabase.storage
        .from("exhibition-previews")
        .createSignedUrl(path, 900);
      const target = editor.querySelector(".work-preview");
      if (!target) return;
      if (error) {
        target.innerHTML =
          '<span class="muted">プレビューを表示できませんでした。</span>';
        return;
      }
      target.innerHTML = `<img src="${esc(data.signedUrl)}" alt="登録済み作品のプレビュー">`;
    };
    works.forEach(addEditor);
    if (!works.length) addEditor();
    const draftButton = document.querySelector("#saveEntryDraft"),
      submitButton = document.querySelector("#submitEntry"),
      formSnapshot = () =>
        JSON.stringify({
          entryNote: form.entry_note.value,
          works: [...editors.querySelectorAll(".work-editor")].map((editor) => {
            const original = editor.querySelector("[name=original]").files[0],
              qr = editor.querySelector("[name=instagram_qr]").files[0];
            return {
              id: editor.dataset.id,
              title: editor.querySelector("[name=title]").value,
              orientation: editor.querySelector("[name=orientation]").value,
              printSize: editor.querySelector("[name=print_size]").value,
              printSizeDetail: editor.querySelector("[name=print_size_detail]")
                .value,
              artistName: editor.querySelector("[name=artist_name]").value,
              cameraName: editor.querySelector("[name=camera_name]").value,
              lensOther: editor.querySelector("[name=lens_other]").value,
              description: editor.querySelector("[name=description]").value,
              note: editor.querySelector("[name=note]").value,
              original: original
                ? `${original.name}:${original.size}:${original.lastModified}`
                : "",
              qr: qr ? `${qr.name}:${qr.size}:${qr.lastModified}` : "",
            };
          }),
        }),
      initialSnapshot = formSnapshot(),
      updateEntryButtons = () => {
        const changed = formSnapshot() !== initialSnapshot;
        draftButton.disabled = !changed;
        submitButton.disabled = entry?.status === "submitted" && !changed;
        submitButton.textContent =
          entry?.status === "submitted"
            ? changed
              ? hasRejected
                ? "修正内容を再提出"
                : "変更内容で再確定"
              : hasRejected
                ? "修正してください"
                : "申込済み"
            : "出展申込を確定";
      };
    updateEntryButtons();
    form.addEventListener("input", updateEntryButtons);
    form.addEventListener("change", updateEntryButtons);
    addButton.onclick = () => {
      addEditor();
      updateEntryButtons();
    };
    const save = async (submitted) => {
      const saveButton = document.querySelector(
          submitted ? "#submitEntry" : "#saveEntryDraft",
        ),
        editorList = [...editors.querySelectorAll(".work-editor")];
      try {
        if (submitted && !editorList.length)
          throw new Error("提出する作品を1件以上追加してください。");
        editorList.forEach((editor, index) => {
          if (editor.dataset.locked === "true") return;
          const title = editor.querySelector("[name=title]").value.trim(),
            orientation = editor.querySelector("[name=orientation]").value,
            printSize = editor.querySelector("[name=print_size]").value,
            printSizeDetail = editor
              .querySelector("[name=print_size_detail]")
              .value.trim(),
            artistName = editor
              .querySelector("[name=artist_name]")
              .value.trim(),
            cameraName = editor
              .querySelector("[name=camera_name]")
              .value.trim(),
            file = editor.querySelector("[name=original]").files[0],
            qrFile = editor.querySelector("[name=instagram_qr]").files[0],
            hasOriginal = Boolean(editor.dataset.originalPath);
          if (submitted && !title)
            throw new Error(`作品${index + 1}の作品名を入力してください。`);
          if (submitted && !orientation)
            throw new Error(`作品${index + 1}の向きを選択してください。`);
          if (submitted && !printSize)
            throw new Error(`作品${index + 1}の出展サイズを選択してください。`);
          if (
            submitted &&
            ["composite", "other"].includes(printSize) &&
            !printSizeDetail
          )
            throw new Error(`作品${index + 1}のサイズ詳細を入力してください。`);
          if (submitted && !artistName)
            throw new Error(
              `作品${index + 1}の作者名・ペンネームを入力してください。`,
            );
          if (submitted && !cameraName)
            throw new Error(`作品${index + 1}のCameraを入力してください。`);
          if (submitted && !file && !hasOriginal)
            throw new Error(`作品${index + 1}の原画像を選択してください。`);
          if (file && file.size > 52428800)
            throw new Error(`作品${index + 1}の原画像が50MBを超えています。`);
          if (file && !allowedOriginalTypes.has(file.type))
            throw new Error(`作品${index + 1}の画像形式に対応していません。`);
          if (qrFile && qrFile.size > 10485760)
            throw new Error(`作品${index + 1}のQRコードが10MBを超えています。`);
          if (qrFile && !allowedQrTypes.has(qrFile.type))
            throw new Error(
              `作品${index + 1}のQRコード形式に対応していません。`,
            );
        });
        saveButton.disabled = true;
        message(
          submitted
            ? "画像を保存し、出展申込を確定しています…"
            : "下書きを保存しています…",
        );
        let currentEntry = entry;
        if (!currentEntry) {
          const { data, error: createError } = await supabase
            .from("exhibition_entries")
            .insert({
              event_id: event.id,
              member_id: context.member.id,
              status: "draft",
              note: form.entry_note.value.trim(),
            })
            .select()
            .single();
          if (createError) throw createError;
          currentEntry = data;
        }
        if (currentEntry.status === "submitted") {
          const { error: draftError } = await supabase
            .from("exhibition_entries")
            .update({ status: "draft" })
            .eq("id", currentEntry.id);
          if (draftError) throw draftError;
        }
        for (const editor of editorList) {
          if (editor.dataset.locked === "true") continue;
          let workId = editor.dataset.id,
            sortOrder = Number(editor.dataset.sortOrder),
            originalPath = editor.dataset.originalPath || null,
            originalFileName = editor.dataset.originalFileName || "",
            previewPath = editor.dataset.previewPath || null,
            qrPath = editor.dataset.qrPath || null,
            qrFileName = editor.dataset.qrFileName || "";
          if (!workId) {
            const withdrawnInSlot = allWorks.find(
              (work) =>
                work.sort_order === sortOrder && work.status === "withdrawn",
            );
            if (withdrawnInSlot) {
              const { error: restoreRowError } = await supabase
                .from("exhibition_works")
                .update({ status: "draft" })
                .eq("id", withdrawnInSlot.id);
              if (restoreRowError) throw restoreRowError;
              const { error: oldRowError } = await supabase
                .from("exhibition_works")
                .delete()
                .eq("id", withdrawnInSlot.id);
              if (oldRowError) throw oldRowError;
            }
            const { data: newWork, error: createWorkError } = await supabase
              .from("exhibition_works")
              .insert({
                entry_id: currentEntry.id,
                event_id: event.id,
                owner_member_id: context.member.id,
                sort_order: sortOrder,
                status: "draft",
              })
              .select()
              .single();
            if (createWorkError) throw createWorkError;
            workId = newWork.id;
            editor.dataset.id = workId;
          }
          const file = editor.querySelector("[name=original]").files[0];
          if (file) {
            const prefix = `${event.id}/${context.member.id}/${workId}`,
              internalMemberNo = context.member.member_no.replace(
                /[^A-Za-z0-9_-]/g,
                "_",
              ),
              newOriginalPath = `${prefix}/${internalMemberNo}_work-${sortOrder}.${originalExtension(file)}`;
            const { error: uploadError } = await supabase.storage
              .from("exhibition-originals")
              .upload(newOriginalPath, file, {
                upsert: true,
                contentType: file.type,
              });
            if (uploadError) throw uploadError;
            if (originalPath && originalPath !== newOriginalPath) {
              const { error: oldError } = await supabase.storage
                .from("exhibition-originals")
                .remove([originalPath]);
              if (oldError)
                console.warn("以前の原画像を削除できませんでした。", oldError);
            }
            originalPath = newOriginalPath;
            originalFileName = file.name;
            const preview = await createWorkPreview(file);
            if (preview) {
              const newPreviewPath = `${prefix}/preview.webp`,
                { error: previewError } = await supabase.storage
                  .from("exhibition-previews")
                  .upload(newPreviewPath, preview, {
                    upsert: true,
                    contentType: "image/webp",
                  });
              if (previewError) throw previewError;
              previewPath = newPreviewPath;
            }
          }
          const qrFile = editor.querySelector("[name=instagram_qr]").files[0];
          if (qrFile) {
            const prefix = `${event.id}/${context.member.id}/${workId}`,
              newQrPath = `${prefix}/instagram-qr.${qrExtension(qrFile)}`;
            const { error: qrUploadError } = await supabase.storage
              .from("exhibition-previews")
              .upload(newQrPath, qrFile, {
                upsert: true,
                contentType: qrFile.type,
              });
            if (qrUploadError) throw qrUploadError;
            if (qrPath && qrPath !== newQrPath) {
              const { error: oldQrError } = await supabase.storage
                .from("exhibition-previews")
                .remove([qrPath]);
              if (oldQrError)
                console.warn(
                  "以前のQRコードを削除できませんでした。",
                  oldQrError,
                );
            }
            qrPath = newQrPath;
            qrFileName = qrFile.name;
          }
          const payload = {
            title: editor.querySelector("[name=title]").value.trim(),
            orientation: editor.querySelector("[name=orientation]").value,
            print_size: editor.querySelector("[name=print_size]").value,
            print_size_detail: editor
              .querySelector("[name=print_size_detail]")
              .value.trim(),
            artist_name: editor
              .querySelector("[name=artist_name]")
              .value.trim(),
            camera_name: editor
              .querySelector("[name=camera_name]")
              .value.trim(),
            lens_other: editor.querySelector("[name=lens_other]").value.trim(),
            description: editor
              .querySelector("[name=description]")
              .value.trim(),
            note: editor.querySelector("[name=note]").value.trim(),
            original_image_path: originalPath,
            original_file_name: originalFileName,
            preview_image_path: previewPath,
            instagram_qr_path: qrPath,
            instagram_qr_file_name: qrFileName,
            status: submitted ? "submitted" : "draft",
          };
          const { error: updateError } = await supabase
            .from("exhibition_works")
            .update(payload)
            .eq("id", workId);
          if (updateError) throw updateError;
        }
        const { error: entryError } = await supabase
          .from("exhibition_entries")
          .update({
            note: form.entry_note.value.trim(),
            status: submitted ? "submitted" : "draft",
          })
          .eq("id", currentEntry.id);
        if (entryError) throw entryError;
        await renderExhibitionEvent(event, context);
        message(
          submitted ? "出展申込を確定しました。" : "下書きを保存しました。",
        );
      } catch (saveError) {
        saveButton.disabled = false;
        failure(saveError);
      }
    };
    document.querySelector("#saveEntryDraft").onclick = () => save(false);
    form.onsubmit = (submit) => {
      submit.preventDefault();
      save(true);
    };
  } catch (error) {
    failure(error);
  }
}

async function renderEvent(id, context) {
  context ??= await getContext();
  layout(
    "参加回答",
    '<a class="button secondary" href="#/">ポータルトップに戻る</a>',
  );
  try {
    const { data: event, error } = await supabase
      .from("events")
      .select("*,event_responses(*)")
      .eq("id", id)
      .single();
    const member = context.member;
    if (error) throw error;
    if (event.genre === "exhibition")
      return renderExhibitionEvent(event, context);
    hideMessage();
    const existing = event.event_responses?.[0],
      view = document.querySelector("#view");
    let cameraRemaining = 0;
    if (event.camera_enabled) {
      const { data, error: cameraError } = await supabase.rpc(
        "get_camera_remaining",
        { p_event_id: id },
      );
      if (cameraError) throw cameraError;
      cameraRemaining = data;
    }
    view.innerHTML = `<section class="panel"><span class="tag">${eventLabel(event)}</span><h2>${esc(event.title)}</h2><dl><dt>日時</dt><dd>${fmt(event.starts_at)}${event.ends_at ? ` 〜 ${fmt(event.ends_at)}` : ""}</dd><dt>場所</dt><dd>${esc(event.place)}</dd><dt>連絡先</dt><dd>${esc(event.contact)}</dd>${event.fee_enabled ? `<dt>費用</dt><dd>${event.fee.toLocaleString()}円</dd>` : ""}${event.payment_deadline_enabled && event.payment_deadline ? `<dt>支払期限</dt><dd>${fmt(event.payment_deadline)}</dd>` : ""}</dl><p class="copy">${esc(event.details)}</p></section><section id="response" class="panel"></section>`;
    const root = document.querySelector("#response");
    if (existing) {
      root.innerHTML = `<span class="tag">YOUR RESPONSE</span><h2>回答済みです</h2><dl><dt>回答</dt><dd class="status">${existing.cancelled_at ? "キャンセル済み" : esc(existing.attendance)}</dd><dt>回答日時</dt><dd>${fmt(existing.submitted_at)}</dd>${existing.attendance === "参加" && existing.camera ? "<dt>貸出カメラ</dt><dd>希望する</dd>" : ""}${existing.attendance === "参加" && existing.disposable_camera ? "<dt>写るんです</dt><dd>希望する</dd>" : ""}${existing.allergies ? `<dt>アレルギー</dt><dd>${esc([existing.allergies, existing.other_allergy].filter(Boolean).join("・"))}</dd>` : ""}${existing.payment_status !== "not_required" ? `<dt>支払い状況</dt><dd>${esc(paymentLabel(existing.payment_status))}</dd>` : ""}${existing.payment_status === "cancelled" && existing.payment_updated_by === "system:payment-deadline" ? "<dt>キャンセル理由</dt><dd>支払期限超過による自動キャンセル</dd>" : ""}${existing.note ? `<dt>備考</dt><dd>${esc(existing.note)}</dd>` : ""}</dl><p>同じ予定へ複数回答することはできません。変更が必要な場合は幹部へ連絡してください。</p>`;
      return;
    }
    const allergyFields =
      event.genre === "camp" || event.subtype === "dining"
        ? '<fieldset><legend>アレルギー（参加者必須）</legend><label>主要項目<select name="allergies" required><option value="">選択してください</option><option>なし</option><option>卵</option><option>乳</option><option>小麦</option><option>えび</option><option>かに</option><option>そば</option><option>落花生</option><option>その他</option></select></label><label>その他・詳細<input name="other_allergy"></label></fieldset>'
        : "";
    root.innerHTML = `<h2>出欠を回答</h2><form id="responseForm" class="stack"><section class="member-summary"><strong>${esc(member.name)}さん</strong><span>${esc([member.grade, member.faculty || member.graduate_school, member.department || member.major].filter(Boolean).join("・"))}</span></section><fieldset><legend>出欠</legend><label><input type="radio" name="attendance" value="参加" required>参加</label><label><input type="radio" name="attendance" value="不参加" required>不参加</label></fieldset><label>LINEの名前<input name="line_name" value="${esc(member?.line_name || "")}" required></label><div id="joinFields" class="stack hidden">${allergyFields}${event.camera_enabled ? `<label><input type="checkbox" name="camera" ${cameraRemaining === 0 ? "disabled" : ""}>貸出カメラを希望（残り ${cameraRemaining}台）</label>` : ""}${event.disposable_enabled ? '<label><input type="checkbox" name="disposable_camera">写るんですを希望</label>' : ""}${event.genre === "camp" ? '<div class="notice agreement"><p>本申込みの送信後は、疾病その他やむを得ない事情を除き、参加者都合による取消しは原則として認められません。また、支払期限までに費用全額の入金が確認できない場合、申込みは通知なく自動的に取り消されます。</p><label><input type="checkbox" name="agreement" required>上記条件を確認し、同意します</label></div>' : ""}</div><label>備考<textarea name="note" rows="4"></textarea></label><div class="actions"><button>この内容で回答</button></div></form>`;
    const form = document.querySelector("#responseForm"),
      join = document.querySelector("#joinFields");
    form.querySelectorAll("[name=attendance]").forEach(
      (r) =>
        (r.onchange = () => {
          const participating = r.value === "参加" && r.checked;
          join.classList.toggle("hidden", !participating);
          join
            .querySelectorAll("input,select,textarea")
            .forEach(
              (control) =>
                (control.disabled =
                  !participating ||
                  (control.name === "camera" && cameraRemaining === 0)),
            );
        }),
    );
    form.onsubmit = async (submit) => {
      submit.preventDefault();
      const values = Object.fromEntries(new FormData(form)),
        button = form.querySelector("button");
      button.disabled = true;
      const attendance = values.attendance;
      const { error: insertError } = await supabase
        .from("event_responses")
        .insert({
          event_id: id,
          member_id: member.id,
          line_name: values.line_name,
          attendance,
          camera: attendance === "参加" && values.camera === "on",
          disposable_camera:
            attendance === "参加" && values.disposable_camera === "on",
          allergies: attendance === "参加" ? values.allergies || "" : "",
          other_allergy:
            attendance === "参加" ? values.other_allergy || "" : "",
          note: values.note || "",
          agreement: attendance === "参加" && values.agreement === "on",
          payment_status: "not_required",
        });
      if (insertError) {
        button.disabled = false;
        failure(insertError);
        return;
      }
      renderEvent(id);
    };
  } catch (error) {
    failure(error);
  }
}

const paymentLabel = (value) =>
  value === "paid"
    ? "支払い済み"
    : value === "unpaid"
      ? "未払い"
      : value === "cancelled"
        ? "キャンセル"
        : "対象外";

async function renderAdmin(context) {
  context ??= await getContext();
  layout(
    "予定管理",
    '<a class="button secondary" href="#/">ポータルトップに戻る</a><button id="logout" class="secondary">ログアウト</button>',
  );
  document.querySelector("#logout").onclick = () => supabase.auth.signOut();
  try {
    if (!context.admin) throw new Error("管理者権限がありません。");
    const { data: events, error } = await supabase
      .from("events")
      .select("*")
      .is("deleted_at", null)
      .order("updated_at", { ascending: false });
    if (error) throw error;
    hideMessage();
    const view = document.querySelector("#view");
    view.innerHTML = `<div class="admin-nav"><button id="showEvents" class="secondary">予定管理</button><button id="showReceipt" class="secondary">領収証発行</button></div><section id="eventAdmin"><div class="actions"><button id="newEvent">新規予定を作成</button></div><section class="panel"><div id="adminList"></div></section><section id="editor" class="panel hidden"></section><section id="participantAdmin" class="panel hidden"></section></section><section id="receiptAdmin" class="panel hidden"><span class="tag">MEMBERSHIP RECEIPT</span><h2>部費領収証を発行</h2><p class="muted">既存部員は大学メールから情報を呼び出せます。登録と同時に年度在籍が有効になります。</p><form id="receiptForm" class="form-grid"><label class="full">大学メールアドレス<div class="inline-field"><input type="email" name="email" required autocomplete="off"><button type="button" id="findMember" class="secondary">名簿から検索</button></div></label><label>氏名<input name="name" required></label><label>学年<input name="grade" required placeholder="B1 / M1"></label><label>学部（学部生）<input name="faculty"></label><label>学科（学部生）<input name="department"></label><label>研究科（院生）<input name="graduate_school"></label><label>専攻（院生）<input name="major"></label><label>性別<select name="gender"><option value=""></option><option>男性</option><option>女性</option><option>その他</option><option>回答しない</option></select></label><label>LINEの名前<input name="line_name" required></label><label>前年度在籍状況<select name="previous_member"><option value=""></option><option>在籍</option><option>未在籍</option><option>不明</option></select></label><label>年度<input type="number" name="fiscal_year" min="2000" max="2200" required value="${fiscalYear()}"></label><label>金額<input type="number" name="amount" min="0" required value="6000"></label><div class="full notice">但書は「<strong><span id="receiptYear">${fiscalYear()}</span>年度部費として</strong>」で記録されます。</div><div class="actions full"><button id="issueReceipt">年度在籍登録・領収証発行</button></div></form><section id="receiptResult" class="receipt-result hidden"></section></section>`;
    const list = document.querySelector("#adminList");
    if (!events.length) list.innerHTML = "<p>予定はまだありません。</p>";
    events.forEach((event) =>
      list.insertAdjacentHTML(
        "beforeend",
        `<article class="admin-row" data-id="${event.id}"><div><span class="tag">${event.status === "draft" ? "下書き" : event.published ? "公開中" : "非公開"}</span><h3>${esc(event.title)}</h3><p>${fmt(event.starts_at)}</p></div><div class="actions"><button class="secondary participants">${event.genre === "exhibition" ? "出展者・作品管理" : "参加者・支払い"}</button>${event.genre === "exhibition" ? '<button class="secondary simulator">展示シミュレータ</button>' : ""}<button class="secondary edit">編集</button><button class="secondary publish">${event.published ? "非公開にする" : "公開する"}</button><button class="danger delete">削除</button></div></article>`,
      ),
    );
    list.querySelectorAll(".admin-row").forEach((row) => {
      const event = events.find((e) => e.id === row.dataset.id);
      row.querySelector(".participants").onclick = () =>
        renderParticipants(event);
      row.querySelector(".simulator")?.addEventListener("click", () =>
        renderExhibitionSimulator(event),
      );
      row.querySelector(".edit").onclick = () => renderEditor(event);
      row.querySelector(".publish").onclick = async () => {
        if (!confirm(`「${event.title}」の公開状態を変更しますか？`)) return;
        await supabase
          .from("events")
          .update({
            published: !event.published,
            updated_at: new Date().toISOString(),
          })
          .eq("id", event.id);
        renderAdmin();
      };
      row.querySelector(".delete").onclick = async () => {
        if (
          !confirm(
            `「${event.title}」を削除しますか？\n回答記録は保持されます。`,
          )
        )
          return;
        const { error } = await supabase
          .from("events")
          .update({ deleted_at: new Date().toISOString(), published: false })
          .eq("id", event.id);
        if (error) failure(error);
        else renderAdmin();
      };
    });
    document.querySelector("#newEvent").onclick = () => renderEditor(null);
    const eventAdmin = document.querySelector("#eventAdmin"),
      receiptAdmin = document.querySelector("#receiptAdmin");
    document.querySelector("#showEvents").onclick = () => {
      eventAdmin.classList.remove("hidden");
      receiptAdmin.classList.add("hidden");
    };
    document.querySelector("#showReceipt").onclick = () => {
      eventAdmin.classList.add("hidden");
      receiptAdmin.classList.remove("hidden");
    };
    setupReceiptForm();
  } catch (error) {
    failure(error);
  }
}

async function renderParticipants(event) {
  if (event.genre === "exhibition") return renderExhibitionParticipants(event);
  const root = document.querySelector("#participantAdmin");
  document.querySelector("#editor").classList.add("hidden");
  root.classList.remove("hidden");
  root.innerHTML = "<p>参加者情報を読み込んでいます…</p>";
  root.scrollIntoView({ behavior: "smooth" });
  const { data: responses, error } = await supabase
    .from("event_responses")
    .select(
      "*,members(member_no,name,email,grade,faculty,department,graduate_school,major)",
    )
    .eq("event_id", event.id)
    .order("submitted_at");
  if (error) {
    failure(error);
    root.classList.add("hidden");
    return;
  }
  const joined = responses.filter(
      (response) => response.attendance === "参加" && !response.cancelled_at,
    ).length,
    paid = responses.filter(
      (response) => response.payment_status === "paid",
    ).length,
    unpaid = responses.filter(
      (response) => response.payment_status === "unpaid",
    ).length;
  root.innerHTML = `<span class="tag">PARTICIPANTS</span><h2>${esc(event.title)}｜参加者・支払い管理</h2><div class="summary-strip"><span>回答 ${responses.length}名</span><span>参加 ${joined}名</span>${event.fee_enabled && event.fee > 0 ? `<span>支払い済み ${paid}名</span><span>未払い ${unpaid}名</span>` : ""}</div><div id="participantList" class="participant-list"></div>`;
  const list = root.querySelector("#participantList");
  if (!responses.length) {
    list.innerHTML = '<p class="muted">回答はまだありません。</p>';
    return;
  }
  responses.forEach((response) => {
    const member = response.members || {},
      paymentTarget =
        event.fee_enabled && event.fee > 0 && response.attendance === "参加",
      affiliation = [
        member.grade,
        member.faculty || member.graduate_school,
        member.department || member.major,
      ]
        .filter(Boolean)
        .join("・");
    list.insertAdjacentHTML(
      "beforeend",
      `<article class="participant-row" data-id="${response.id}"><div><strong>${esc(member.name || "部員情報なし")}</strong><p>${esc(member.member_no || "")} ${esc(affiliation)}</p><p class="muted">${esc(member.email || "")}／回答 ${fmt(response.submitted_at)}</p></div><div><span class="status">${response.cancelled_at ? "キャンセル済み" : esc(response.attendance)}</span></div><div>${paymentTarget ? `<label>支払い状況<select class="payment-status"><option value="unpaid" ${response.payment_status === "unpaid" ? "selected" : ""}>未払い</option><option value="paid" ${response.payment_status === "paid" ? "selected" : ""}>支払い済み</option><option value="cancelled" ${response.payment_status === "cancelled" ? "selected" : ""}>キャンセル</option></select></label>${response.payment_updated_at ? `<small class="muted">${fmt(response.payment_updated_at)}<br>${esc(response.payment_updated_by)}</small>` : ""}` : '<span class="muted">支払い対象外</span>'}</div></article>`,
    );
  });
  list.querySelectorAll(".payment-status").forEach((select) => {
    const previous = select.value;
    select.onchange = async () => {
      const row = select.closest(".participant-row"),
        next = select.value,
        label = paymentLabel(next);
      if (!confirm(`支払い状況を「${label}」へ変更しますか？`)) {
        select.value = previous;
        return;
      }
      select.disabled = true;
      const { error } = await supabase.rpc("set_event_payment_status", {
        p_response_id: row.dataset.id,
        p_status: next,
      });
      if (error) {
        select.value = previous;
        select.disabled = false;
        failure(error);
        return;
      }
      message(`支払い状況を「${label}」へ変更しました。`);
      renderParticipants(event);
    };
  });
}

async function copyText(text) {
  if (navigator.clipboard?.writeText) {
    await navigator.clipboard.writeText(text);
    return;
  }
  const area = document.createElement("textarea");
  area.value = text;
  area.style.position = "fixed";
  area.style.opacity = "0";
  document.body.appendChild(area);
  area.select();
  document.execCommand("copy");
  area.remove();
}

async function downloadStorageFile(bucket, path, fileName) {
  const { data, error } = await supabase.storage.from(bucket).download(path);
  if (error) throw error;
  const url = URL.createObjectURL(data),
    link = document.createElement("a");
  link.href = url;
  link.download = fileName || path.split("/").pop() || "download";
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

const clamp = (value, min, max) => Math.min(max, Math.max(min, value));

async function renderExhibitionSimulator(event, preferredLayoutId = null) {
  const root = document.querySelector("#participantAdmin");
  document.querySelector("#editor").classList.add("hidden");
  root.classList.remove("hidden");
  root.innerHTML = "<p>展示シミュレータを読み込んでいます…</p>";
  root.scrollIntoView({ behavior: "smooth" });
  try {
    const [venueResult, workResult, layoutResult] = await Promise.all([
      supabase
        .from("exhibition_venues")
        .select("*,exhibition_walls(*)")
        .order("name"),
      supabase
        .from("exhibition_works")
        .select("*,exhibition_entries!inner(event_id,members(member_no,name))")
        .eq("exhibition_entries.event_id", event.id)
        .neq("status", "withdrawn")
        .order("display_no"),
      supabase
        .from("exhibition_layouts")
        .select("*")
        .eq("event_id", event.id)
        .order("updated_at", { ascending: false }),
    ]);
    if (venueResult.error) throw venueResult.error;
    if (workResult.error) throw workResult.error;
    if (layoutResult.error) throw layoutResult.error;
    const venues = venueResult.data || [],
      works = workResult.data || [],
      layouts = layoutResult.data || [],
      venue = venues.find((item) => item.id === event.exhibition_venue_id);
    if (!venue) {
      root.innerHTML = `<div class="entry-heading"><div><span class="tag">EXHIBITION LAYOUT</span><h2>${esc(event.exhibition_title || event.title)}｜展示シミュレータ</h2></div></div><div class="notice">最初に、この写真展で使用する会場を選択または登録してください。</div><form id="venueSetupForm" class="form-grid simulator-setup"><label class="full">登録済み会場<select name="venue_id"><option value="">新しい会場を登録する</option>${venues.filter((item) => item.status === "active").map((item) => `<option value="${item.id}">${esc(item.name)}</option>`).join("")}</select></label><label>新しい会場名<input name="name" placeholder="例：EAST館 202"></label><label>所在地・建物情報<input name="address"></label><label class="full">会場メモ<textarea name="notes" rows="2"></textarea></label><div class="actions full"><button>この会場を使用する</button></div></form>`;
      root.querySelector("#venueSetupForm").onsubmit = async (submit) => {
        submit.preventDefault();
        const form = submit.currentTarget,
          values = Object.fromEntries(new FormData(form));
        try {
          let venueId = values.venue_id;
          if (!venueId) {
            if (!values.name.trim()) throw new Error("会場名を入力してください。");
            const { data, error } = await supabase
              .from("exhibition_venues")
              .insert({
                name: values.name.trim(),
                address: values.address.trim(),
                notes: values.notes.trim(),
              })
              .select()
              .single();
            if (error) throw error;
            venueId = data.id;
          }
          const { error } = await supabase
            .from("events")
            .update({ exhibition_venue_id: venueId })
            .eq("id", event.id);
          if (error) throw error;
          event.exhibition_venue_id = venueId;
          await renderExhibitionSimulator(event);
          message("写真展で使用する会場を設定しました。");
        } catch (error) {
          failure(error);
        }
      };
      return;
    }

    const walls = (venue.exhibition_walls || []).sort(
        (a, b) => a.display_order - b.display_order,
      ),
      currentLayout =
        layouts.find((item) => item.id === preferredLayoutId) ||
        layouts.find((item) => item.is_current) ||
        layouts[0] ||
        null;
    let placements = [];
    if (currentLayout) {
      const { data, error } = await supabase
        .from("exhibition_placements")
        .select("*")
        .eq("layout_id", currentLayout.id)
        .neq("status", "removed");
      if (error) throw error;
      placements = data || [];
    }
    const workById = Object.fromEntries(works.map((work) => [work.id, work])),
      placedIds = new Set(placements.map((placement) => placement.work_id)),
      unplaced = works.filter((work) => !placedIds.has(work.id));
    root.innerHTML = `<div class="entry-heading"><div><span class="tag">EXHIBITION LAYOUT</span><h2>${esc(event.exhibition_title || event.title)}｜展示シミュレータ</h2><p class="muted">会場：${esc(venue.name)}／座標はすべてmm。高さは床面から作品上端までです。</p></div></div><section class="simulator-section"><div class="section-head compact"><h3>1. 壁面</h3></div><div class="wall-summary">${walls.length ? walls.map((wall) => `<span>${esc(wall.name)}：${wall.width_mm} × ${wall.height_mm} mm</span>`).join("") : '<span class="muted">壁面が未登録です。</span>'}</div><form id="wallForm" class="form-grid compact-form"><label>壁面名<input name="name" required placeholder="例：正面壁面"></label><label>表示順<input type="number" name="display_order" min="1" required value="${walls.length + 1}"></label><label>幅（mm）<input type="number" name="width_mm" min="1" step="0.01" required></label><label>高さ（mm）<input type="number" name="height_mm" min="1" step="0.01" required></label><label>壁面色<input type="color" name="background_color" value="#FFFFFF"></label><label class="full">注意事項<input name="notes" placeholder="例：右端500mmは配電盤"></label><div class="actions full"><button>壁面を追加</button></div></form></section><section class="simulator-section"><div class="section-head compact"><h3>2. 作品の占有外寸</h3><p>単写真は用紙寸法が初期入力されています。額装・組み写真は実際に壁を占有する外寸へ修正してください。</p></div><div class="dimension-list">${works.length ? works.map((work) => `<form class="dimension-row" data-work-id="${work.id}"><div><strong>${work.display_no ? `No.${esc(work.display_no)}` : `作品${work.sort_order}`} ${esc(work.title || "作品名未入力")}</strong><small>${esc(work.exhibition_entries?.members?.name || "")}／${esc(printSizeLabel(work.print_size, work.print_size_detail))}</small></div><label>幅<input type="number" name="width" min="1" step="0.01" value="${work.occupied_width_mm || ""}" required></label><label>高さ<input type="number" name="height" min="1" step="0.01" value="${work.occupied_height_mm || ""}" required></label><button class="secondary">外寸を保存</button></form>`).join("") : '<p class="muted">出展作品がありません。</p>'}</div></section><section class="simulator-section"><div class="section-head compact"><h3>3. 配置案</h3></div><div class="layout-toolbar"><select id="layoutSelect"><option value="">配置案を選択</option>${layouts.map((layout) => `<option value="${layout.id}" ${layout.id === currentLayout?.id ? "selected" : ""}>${esc(layout.name)} v${layout.version_no}${layout.is_current ? "（現在案）" : ""}</option>`).join("")}</select><form id="layoutForm" class="inline-field"><input name="name" required placeholder="例：第1案"><button>新しい配置案を作成</button></form></div>${currentLayout ? `<div class="layout-status"><strong>${esc(currentLayout.name)} v${currentLayout.version_no}</strong><span>${currentLayout.status === "approved" ? "承認済み" : currentLayout.status === "review" ? "確認中" : currentLayout.status === "archived" ? "保管" : "下書き"}</span></div><div class="unplaced-works"><h4>未配置作品（${unplaced.length}点）</h4>${unplaced.length ? unplaced.map((work) => `<div class="unplaced-work"><span>${work.display_no ? `No.${esc(work.display_no)}` : `作品${work.sort_order}`} ${esc(work.title || "作品名未入力")}</span>${work.occupied_width_mm && walls.length ? `<select data-wall-choice><option value="">配置先の壁面</option>${walls.filter((wall) => wall.usable).map((wall) => `<option value="${wall.id}">${esc(wall.name)}</option>`).join("")}</select><button class="place-work secondary" data-work-id="${work.id}">配置</button>` : '<small class="muted">占有外寸または壁面が未設定です。</small>'}</div>`).join("") : '<p class="muted">すべての作品が配置されています。</p>'}</div><div class="wall-canvases">${walls.map((wall) => renderWallCanvas(wall, placements.filter((item) => item.wall_id === wall.id), workById)).join("")}</div>` : '<div class="notice">配置案を作成すると、作品を壁面へ配置できます。</div>'}</section>`;

    root.querySelector("#wallForm").onsubmit = async (submit) => {
      submit.preventDefault();
      const values = Object.fromEntries(new FormData(submit.currentTarget)),
        { error } = await supabase.from("exhibition_walls").insert({
          venue_id: venue.id,
          name: values.name.trim(),
          display_order: Number(values.display_order),
          width_mm: Number(values.width_mm),
          height_mm: Number(values.height_mm),
          background_color: values.background_color,
          notes: values.notes.trim(),
        });
      if (error) return failure(error);
      await renderExhibitionSimulator(event, currentLayout?.id);
      message("壁面を追加しました。");
    };
    root.querySelectorAll(".dimension-row").forEach((form) => {
      form.onsubmit = async (submit) => {
        submit.preventDefault();
        const values = Object.fromEntries(new FormData(form)),
          { error } = await supabase
            .from("exhibition_works")
            .update({
              occupied_width_mm: Number(values.width),
              occupied_height_mm: Number(values.height),
            })
            .eq("id", form.dataset.workId);
        if (error) return failure(error);
        await renderExhibitionSimulator(event, currentLayout?.id);
        message("作品の占有外寸を保存しました。");
      };
    });
    root.querySelector("#layoutSelect").onchange = (change) =>
      renderExhibitionSimulator(event, change.target.value || null);
    root.querySelector("#layoutForm").onsubmit = async (submit) => {
      submit.preventDefault();
      const name = new FormData(submit.currentTarget).get("name").trim();
      const { data, error } = await supabase
        .from("exhibition_layouts")
        .insert({
          event_id: event.id,
          name,
          version_no: 1,
          is_current: layouts.length === 0,
          created_by: session.user.email,
        })
        .select()
        .single();
      if (error) return failure(error);
      await renderExhibitionSimulator(event, data.id);
      message("新しい配置案を作成しました。");
    };
    root.querySelectorAll(".place-work").forEach((button) => {
      button.onclick = async () => {
        const wallId = button.parentElement.querySelector("select").value,
          wall = walls.find((item) => item.id === wallId),
          work = workById[button.dataset.workId];
        if (!wallId) return failure("配置先の壁面を選択してください。");
        if (work.occupied_width_mm > wall.width_mm || work.occupied_height_mm > wall.height_mm)
          return failure("作品の占有外寸が壁面より大きいため配置できません。");
        const { error } = await supabase.from("exhibition_placements").insert({
          layout_id: currentLayout.id,
          work_id: work.id,
          wall_id: wall.id,
          x_mm: 0,
          top_from_floor_mm: Number(wall.height_mm),
          z_order: placements.length + 1,
        });
        if (error) return failure(error);
        await renderExhibitionSimulator(event, currentLayout.id);
        message(`作品を「${wall.name}」へ配置しました。`);
      };
    });
    setupPlacementControls(root, event, currentLayout, walls, workById);
    root.querySelectorAll(".placed-work[data-preview-path]").forEach(
      async (item) => {
        const { data, error } = await supabase.storage
          .from("exhibition-previews")
          .createSignedUrl(item.dataset.previewPath, 900);
        if (!error) {
          item.insertAdjacentHTML(
            "afterbegin",
            `<img src="${esc(data.signedUrl)}" alt="">`,
          );
        }
      },
    );
    addWallGuides(root);
  } catch (error) {
    failure(error);
  }
}

function renderWallCanvas(wall, placements, workById) {
  return `<section class="wall-panel"><div class="wall-panel-head"><h4>${esc(wall.name)}</h4><span>${wall.width_mm} × ${wall.height_mm} mm</span></div><div class="wall-canvas" data-wall-id="${wall.id}" data-wall-width="${wall.width_mm}" data-wall-height="${wall.height_mm}" style="--wall-ratio:${wall.width_mm}/${wall.height_mm};background:${esc(wall.background_color)}">${placements.map((placement) => { const work = workById[placement.work_id]; if (!work) return ""; const left = Number(placement.x_mm) / Number(wall.width_mm) * 100, top = (Number(wall.height_mm) - Number(placement.top_from_floor_mm)) / Number(wall.height_mm) * 100, width = Number(work.occupied_width_mm) / Number(wall.width_mm) * 100, height = Number(work.occupied_height_mm) / Number(wall.height_mm) * 100; return `<button type="button" class="placed-work ${placement.locked ? "is-locked" : ""}" data-placement-id="${placement.id}" ${work.preview_image_path ? `data-preview-path="${esc(work.preview_image_path)}"` : ""} style="left:${left}%;top:${top}%;width:${width}%;height:${height}%;z-index:${placement.z_order}" title="${esc(work.title)}"><strong>${work.display_no ? `No.${esc(work.display_no)}` : `作品${work.sort_order}`}</strong><span>${esc(work.title || "")}</span></button>`; }).join("")}</div><div class="placement-list">${placements.map((placement) => { const work = workById[placement.work_id]; return work ? `<form class="placement-row" data-placement-id="${placement.id}" data-work-id="${work.id}"><strong>${work.display_no ? `No.${esc(work.display_no)}` : `作品${work.sort_order}`} ${esc(work.title || "")}</strong><label>左端 x<input type="number" name="x_mm" min="0" step="1" value="${placement.x_mm}"></label><label>床から上端<input type="number" name="top_from_floor_mm" min="0" step="1" value="${placement.top_from_floor_mm}"></label><label class="lock-label"><input type="checkbox" name="locked" ${placement.locked ? "checked" : ""}>固定</label><button class="secondary save-placement">保存</button><button type="button" class="danger remove-placement">配置解除</button></form>` : ""; }).join("")}</div></section>`;
}

function addWallGuides(root) {
  root.querySelectorAll(".wall-canvas").forEach((canvas) => {
    const wallHeight = Number(canvas.dataset.wallHeight);
    canvas.insertAdjacentHTML(
      "afterbegin",
      '<span class="wall-guide wall-guide-center" aria-hidden="true"></span>',
    );
    const levels = new Set([1400]);
    for (let level = 1000; level < wallHeight; level += 1000)
      levels.add(level);
    [...levels]
      .filter((level) => level > 0 && level < wallHeight)
      .sort((a, b) => a - b)
      .forEach((level) => {
        const top = ((wallHeight - level) / wallHeight) * 100,
          special = level === 1400 ? " wall-guide-eye" : "";
        canvas.insertAdjacentHTML(
          "afterbegin",
          `<span class="wall-guide wall-guide-horizontal${special}" style="top:${top}%" aria-hidden="true"><small>床から${level.toLocaleString()}mm</small></span>`,
        );
      });
  });
}

function setupPlacementControls(root, event, layout, walls, workById) {
  if (!layout) return;
  const savePlacement = async (form, quiet = false) => {
    const work = workById[form.dataset.workId],
      wall = walls.find((item) => item.id === form.closest(".wall-panel").querySelector(".wall-canvas").dataset.wallId),
      x = Number(form.elements.x_mm.value),
      top = Number(form.elements.top_from_floor_mm.value);
    if (x < 0 || x + Number(work.occupied_width_mm) > Number(wall.width_mm)) throw new Error("作品が壁面の左右端を超えています。");
    if (top > Number(wall.height_mm) || top - Number(work.occupied_height_mm) < 0) throw new Error("作品が壁面の上下端を超えています。");
    const { error } = await supabase.from("exhibition_placements").update({ x_mm: x, top_from_floor_mm: top, locked: form.elements.locked.checked }).eq("id", form.dataset.placementId);
    if (error) throw error;
    if (!quiet) message("配置座標を保存しました。");
  };
  root.querySelectorAll(".placement-row").forEach((form) => {
    const lockLabel = form.querySelector(".lock-label"),
      updateLockLabel = () => {
        lockLabel.lastChild.textContent = form.elements.locked.checked
          ? "配置固定済み"
          : "配置を固定";
      };
    updateLockLabel();
    form.onsubmit = async (submit) => { submit.preventDefault(); try { await savePlacement(form); await renderExhibitionSimulator(event, layout.id); } catch (error) { failure(error); } };
    form.querySelector(".remove-placement").onclick = async () => {
      if (!confirm("この作品を壁面から外しますか？作品登録自体は削除されません。")) return;
      const { error } = await supabase.from("exhibition_placements").update({ status: "removed" }).eq("id", form.dataset.placementId);
      if (error) return failure(error);
      await renderExhibitionSimulator(event, layout.id);
      message("作品を配置から外しました。");
    };
    form.elements.locked.onchange = async () => {
      const locked = form.elements.locked.checked,
        item = root.querySelector(
          `.placed-work[data-placement-id="${form.dataset.placementId}"]`,
        );
      item?.classList.toggle("is-locked", locked);
      updateLockLabel();
      const { error } = await supabase
        .from("exhibition_placements")
        .update({ locked })
        .eq("id", form.dataset.placementId);
      if (error) {
        form.elements.locked.checked = !locked;
        item?.classList.toggle("is-locked", !locked);
        updateLockLabel();
        failure(error);
        return;
      }
      await renderExhibitionSimulator(event, layout.id);
      message(locked ? "配置を固定しました。" : "配置の固定を解除しました。");
    };
  });
  root.querySelectorAll(".placed-work").forEach((item) => {
    const form = root.querySelector(`.placement-row[data-placement-id="${item.dataset.placementId}"]`);
    if (!form || form.elements.locked.checked) return;
    item.onpointerdown = (down) => {
      if (form.elements.locked.checked) return;
      down.preventDefault();
      item.setPointerCapture(down.pointerId);
      const canvas = item.closest(".wall-canvas"), wallWidth = Number(canvas.dataset.wallWidth), wallHeight = Number(canvas.dataset.wallHeight), startX = down.clientX, startY = down.clientY, initialX = Number(form.elements.x_mm.value), initialTop = Number(form.elements.top_from_floor_mm.value), work = workById[form.dataset.workId];
      item.onpointermove = (move) => {
        const x = clamp(initialX + (move.clientX - startX) / canvas.clientWidth * wallWidth, 0, wallWidth - Number(work.occupied_width_mm)), top = clamp(initialTop - (move.clientY - startY) / canvas.clientHeight * wallHeight, Number(work.occupied_height_mm), wallHeight);
        form.elements.x_mm.value = Math.round(x);
        form.elements.top_from_floor_mm.value = Math.round(top);
        item.style.left = `${x / wallWidth * 100}%`;
        item.style.top = `${(wallHeight - top) / wallHeight * 100}%`;
      };
      item.onpointerup = async () => { item.onpointermove = null; try { await savePlacement(form, true); message("ドラッグ後の配置座標を保存しました。"); } catch (error) { failure(error); await renderExhibitionSimulator(event, layout.id); } };
    };
  });
}

const csvCell = (value) =>
  `"${String(value ?? "").replaceAll('"', '""')}"`;

function downloadCsv(fileName, headers, rows) {
  const csv = [headers, ...rows]
    .map((row) => row.map(csvCell).join(","))
    .join("\r\n");
  const url = URL.createObjectURL(
      new Blob(["\uFEFF", csv], { type: "text/csv;charset=utf-8" }),
    ),
    link = document.createElement("a");
  link.href = url;
  link.download = fileName;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function renderExhibitionParticipants(event) {
  const root = document.querySelector("#participantAdmin");
  document.querySelector("#editor").classList.add("hidden");
  root.classList.remove("hidden");
  root.innerHTML = "<p>出展者と作品情報を読み込んでいます…</p>";
  root.scrollIntoView({ behavior: "smooth" });
  const { data: entries, error } = await supabase
    .from("exhibition_entries")
    .select(
      "*,members(member_no,name,grade,faculty,department,graduate_school,major),exhibition_works(*)",
    )
    .eq("event_id", event.id)
    .order("created_at");
  if (error) {
    failure(error);
    root.classList.add("hidden");
    return;
  }
  const visibleWorks = (entries || []).flatMap((entry) =>
      (entry.exhibition_works || [])
        .filter((work) => work.status !== "withdrawn")
        .map((work) => ({ entry, work })),
    ),
    submitted = entries.filter((entry) => entry.status === "submitted").length;
  root.innerHTML = `<div class="entry-heading"><div><span class="tag">EXHIBITORS & WORKS</span><h2>${esc(event.exhibition_title || event.title)}｜出展者・作品管理</h2></div><div class="actions admin-work-actions"><button id="assignDisplayNumbers" class="secondary" ${visibleWorks.some((item) => !item.work.display_no) ? "" : "disabled"}>未採番作品へ連番を付与</button><button id="exportExhibitionManifest" class="secondary" ${visibleWorks.length ? "" : "disabled"}>連携用CSVを出力</button><button id="copyExhibitionCaptions" class="secondary" ${visibleWorks.length ? "" : "disabled"}>タイトル・キャプションを一括コピー</button></div></div><div class="summary-strip"><span>申込 ${entries.length}名</span><span>確定 ${submitted}名</span><span>作品 ${visibleWorks.length}点</span><span>未採番 ${visibleWorks.filter((item) => !item.work.display_no).length}点</span><span>確認済み ${visibleWorks.filter((item) => item.work.status === "accepted").length}点</span><span>要修正 ${visibleWorks.filter((item) => item.work.status === "rejected").length}点</span><span>QR登録 ${visibleWorks.filter((item) => item.work.instagram_qr_path).length}点</span></div><div id="exhibitorList" class="exhibitor-list"></div>`;
  const list = root.querySelector("#exhibitorList");
  if (!entries.length) {
    list.innerHTML = '<p class="muted">出展申込はまだありません。</p>';
    return;
  }
  entries.forEach((entry) => {
    const member = entry.members || {},
      affiliation = [
        member.grade,
        member.faculty || member.graduate_school,
        member.department || member.major,
      ]
        .filter(Boolean)
        .join("・"),
      works = (entry.exhibition_works || [])
        .filter((work) => work.status !== "withdrawn")
        .sort((a, b) => (a.sort_order || 0) - (b.sort_order || 0));
    list.insertAdjacentHTML(
      "beforeend",
      `<article class="exhibitor-card"><div class="exhibitor-head"><div><span class="tag">${entry.status === "submitted" ? "申込済み" : entry.status === "withdrawn" ? "取り下げ" : "下書き"}</span><h3>${esc(member.name || "部員情報なし")}</h3><p>${esc(member.member_no || "")} ${esc(affiliation)}</p></div><span class="status">${works.length}作品</span></div>${entry.note ? `<p class="muted">出展備考：${esc(entry.note)}</p>` : ""}<div class="admin-work-list">${works.length ? works.map((work) => `<section class="admin-work-card" data-work-id="${work.id}"><div class="admin-work-image">${work.preview_image_path ? `<span class="storage-image" data-storage-path="${esc(work.preview_image_path)}" data-alt="${esc(work.title || "作品プレビュー")}">プレビュー読込中…</span>` : '<span class="muted">プレビューなし</span>'}${work.original_image_path ? `<button type="button" class="secondary download-original" data-original-path="${esc(work.original_image_path)}" data-file-name="${esc(managedOriginalFileName(member, work))}">原画像をダウンロード</button>` : ""}</div><div class="admin-work-copy"><div class="work-meta"><span class="tag">${work.display_no ? `No.${esc(work.display_no)}` : `WORK ${work.sort_order}`}</span><span>${esc(exhibitionWorkStatus(work.status))}</span></div><h3>${esc(work.title || "作品名未入力")}</h3><dl class="caption-details"><dt>向き</dt><dd>${esc(orientationLabel(work.orientation))}</dd><dt>出展サイズ</dt><dd>${esc(printSizeLabel(work.print_size, work.print_size_detail))}</dd><dt>作者</dt><dd>${work.artist_name ? esc(work.artist_name) : '<span class="muted">未入力</span>'}</dd><dt>Camera</dt><dd>${work.camera_name ? esc(work.camera_name) : '<span class="muted">未入力</span>'}</dd><dt>Lens, other</dt><dd>${work.lens_other ? esc(work.lens_other) : '<span class="muted">未入力</span>'}</dd><dt>Description</dt><dd class="caption-text">${work.description ? esc(work.description) : '<span class="muted">未入力</span>'}</dd></dl><p class="muted">アップロード元：${esc(work.original_file_name || "不明")}</p><p class="muted">管理ファイル名：${esc(managedOriginalFileName(member, work))}</p>${work.note ? `<p class="muted">作品備考：${esc(work.note)}</p>` : ""}<div class="work-admin-controls"><label>作品番号<input class="display-no" value="${esc(work.display_no || "")}" placeholder="例：01"></label><label>確認状態<select class="review-status"><option value="submitted" ${work.status === "submitted" || work.status === "draft" ? "selected" : ""}>提出済み</option><option value="accepted" ${work.status === "accepted" ? "selected" : ""}>確認済み</option><option value="rejected" ${work.status === "rejected" ? "selected" : ""}>要修正</option></select></label><button type="button" class="update-work">作品情報を更新</button></div></div><div class="admin-work-qr"><strong>Instagram QR</strong>${work.instagram_qr_path ? `<span class="storage-image qr-image" data-storage-path="${esc(work.instagram_qr_path)}" data-alt="${esc(`${work.title || "作品"}のInstagram QRコード`)}">QR読込中…</span><small>${esc(work.instagram_qr_file_name || "登録済み")}</small><button type="button" class="secondary download-qr" data-qr-path="${esc(work.instagram_qr_path)}" data-file-name="${esc(work.instagram_qr_file_name || "instagram-qr")}">QR画像をダウンロード</button>` : '<span class="muted">未登録</span>'}</div></section>`).join("") : '<p class="muted">作品はまだ登録されていません。</p>'}</div></article>`,
    );
  });
  root.querySelector("#exportExhibitionManifest").onclick = () => {
    const headers = [
        "WorkUuid",
        "ExhibitionEventId",
        "DisplayNo",
        "SubmissionSlot",
        "MemberId",
        "MemberName",
        "Title",
        "Artist",
        "Camera",
        "LensOther",
        "Description",
        "Orientation",
        "PrintSize",
        "PrintSizeDetail",
        "OriginalFileName",
        "OriginalStoragePath",
        "InstagramQrPath",
        "Status",
      ],
      rows = visibleWorks.map(({ entry, work }) => {
        const member = entry.members || {};
        return [
          work.id,
          event.id,
          work.display_no,
          work.sort_order,
          member.member_no,
          member.name,
          work.title,
          work.artist_name,
          work.camera_name,
          work.lens_other,
          work.description,
          work.orientation,
          work.print_size,
          work.print_size_detail,
          managedOriginalFileName(member, work),
          work.original_image_path,
          work.instagram_qr_path,
          work.status,
        ];
      }),
      eventName = safeStorageFileName(
        event.exhibition_title || event.title,
        "exhibition",
      );
    downloadCsv(`${eventName}_作品連携.csv`, headers, rows);
    message("写真展サイト・展示管理アプリ向けの連携用CSVを出力しました。");
  };
  root.querySelector("#copyExhibitionCaptions").onclick = async () => {
    const text = visibleWorks
      .map(({ entry, work }, index) => {
        const member = entry.members || {};
        return [
          `【作品${index + 1}${work.display_no ? `／No.${work.display_no}` : ""}】`,
          `出展者：${member.name || ""}（${member.member_no || ""}）`,
          `作品名：${work.title || ""}`,
          `向き：${orientationLabel(work.orientation)}`,
          `出展サイズ：${printSizeLabel(work.print_size, work.print_size_detail)}`,
          `作者：${work.artist_name || ""}`,
          `Camera：${work.camera_name || ""}`,
          `Lens, other：${work.lens_other || ""}`,
          `Description：${work.description || ""}`,
          `Instagram QR：${work.instagram_qr_path ? "あり" : "なし"}`,
        ].join("\n");
      })
      .join("\n\n");
    try {
      await copyText(text);
      message("全作品のタイトルとキャプションをコピーしました。");
    } catch (copyError) {
      failure("クリップボードへコピーできませんでした。");
    }
  };
  root.querySelector("#assignDisplayNumbers").onclick = async () => {
    if (
      !confirm(
        "未採番の作品へ01から順に作品番号を付けますか？\nすでに採番済みの作品は変更しません。",
      )
    )
      return;
    const button = root.querySelector("#assignDisplayNumbers");
    button.disabled = true;
    const { data, error: assignError } = await supabase.rpc(
      "admin_assign_exhibition_display_numbers",
      { p_event_id: event.id, p_start: 1, p_padding: 2 },
    );
    if (assignError) {
      button.disabled = false;
      failure(assignError);
      return;
    }
    await renderExhibitionParticipants(event);
    message(`${data.assignedCount}作品へ番号を付けました。`);
  };
  root.querySelectorAll(".storage-image").forEach(async (target) => {
    const { data, error: imageError } = await supabase.storage
      .from("exhibition-previews")
      .createSignedUrl(target.dataset.storagePath, 900);
    if (imageError) {
      target.textContent = "画像を表示できませんでした。";
      return;
    }
    target.innerHTML = `<img src="${esc(data.signedUrl)}" alt="${esc(target.dataset.alt)}">`;
  });
  root.querySelectorAll(".download-qr").forEach(
    (button) =>
      (button.onclick = async () => {
        button.disabled = true;
        try {
          await downloadStorageFile(
            "exhibition-previews",
            button.dataset.qrPath,
            button.dataset.fileName,
          );
          message("QR画像をダウンロードしました。");
        } catch (downloadError) {
          failure(downloadError);
        } finally {
          button.disabled = false;
        }
      }),
  );
  root.querySelectorAll(".download-original").forEach(
    (button) =>
      (button.onclick = async () => {
        button.disabled = true;
        try {
          await downloadStorageFile(
            "exhibition-originals",
            button.dataset.originalPath,
            button.dataset.fileName,
          );
          message("原画像をダウンロードしました。");
        } catch (downloadError) {
          failure(downloadError);
        } finally {
          button.disabled = false;
        }
      }),
  );
  root.querySelectorAll(".update-work").forEach(
    (button) =>
      (button.onclick = async () => {
        const card = button.closest(".admin-work-card"),
          displayNo = card.querySelector(".display-no").value.trim(),
          status = card.querySelector(".review-status").value;
        if (
          !confirm(
            `作品番号を「${displayNo || "未採番"}」、確認状態を「${exhibitionWorkStatus(status)}」へ更新しますか？`,
          )
        )
          return;
        button.disabled = true;
        const { error: updateError } = await supabase.rpc(
          "admin_update_exhibition_work",
          {
            p_work_id: card.dataset.workId,
            p_display_no: displayNo,
            p_status: status,
          },
        );
        if (updateError) {
          button.disabled = false;
          failure(updateError);
          return;
        }
        await renderExhibitionParticipants(event);
        message("作品番号と確認状態を更新しました。");
      }),
  );
}

function setupReceiptForm() {
  const form = document.querySelector("#receiptForm"),
    result = document.querySelector("#receiptResult");
  form.fiscal_year.oninput = () =>
    (document.querySelector("#receiptYear").textContent =
      form.fiscal_year.value || "----");
  document.querySelector("#findMember").onclick = async () => {
    const email = form.email.value.trim().toLowerCase();
    if (!email) {
      failure("大学メールアドレスを入力してください。");
      return;
    }
    const { data, error } = await supabase
      .from("members")
      .select("*")
      .eq("email", email)
      .maybeSingle();
    if (error) {
      failure(error);
      return;
    }
    if (!data) {
      message("名簿に未登録です。新規部員として必要事項を入力してください。");
      return;
    }
    for (const name of [
      "name",
      "faculty",
      "grade",
      "department",
      "graduate_school",
      "major",
      "gender",
      "line_name",
      "previous_member",
    ])
      form.elements[name].value = data[name] || "";
    message(`${data.member_no} の部員情報を読み込みました。`);
  };
  form.onsubmit = async (event) => {
    event.preventDefault();
    const button = document.querySelector("#issueReceipt");
    if (
      !confirm(
        `${form.elements.name.value}さんの${form.elements.fiscal_year.value}年度部費 ${Number(form.elements.amount.value).toLocaleString()}円を記録しますか？`,
      )
    )
      return;
    button.disabled = true;
    result.classList.add("hidden");
    const values = Object.fromEntries(new FormData(form));
    values.fiscal_year = Number(values.fiscal_year);
    values.amount = Number(values.amount);
    const { data, error } = await supabase.rpc(
      "issue_membership_receipt",
      Object.fromEntries(
        Object.entries(values).map(([key, value]) => [`p_${key}`, value]),
      ),
    );
    button.disabled = false;
    if (error) {
      failure(error);
      return;
    }
    result.innerHTML = `<span class="tag">ISSUED</span><h3>領収証記録を保存しました</h3><dl><dt>部員ID</dt><dd>${esc(data.memberId)}</dd><dt>領収証ID</dt><dd>${esc(data.receiptId)}</dd><dt>但書</dt><dd>${esc(data.description)}</dd></dl>`;
    result.classList.remove("hidden");
    message("年度在籍登録と領収証発行が完了しました。");
    form.reset();
    form.fiscal_year.value = fiscalYear();
    form.amount.value = 6000;
    form.fiscal_year.oninput();
  };
}

function renderEditor(event) {
  const root = document.querySelector("#editor");
  root.classList.remove("hidden");
  root.innerHTML = `<h2>${event ? "予定を編集" : "新規予定"}</h2><form id="eventForm" class="form-grid"><label class="full">予定名（必須）<input name="title" value="${esc(event?.title || "")}" required></label><label>ジャンル<select name="genre"><option value="meeting">全体会</option><option value="camp">合宿</option><option value="exhibition">写真展</option></select></label><label id="subtypeField">全体会種別<select name="subtype"><option value="shooting">撮影会</option><option value="dining">お食事会</option></select></label><label>開始日時<input type="datetime-local" name="starts_at"></label><label>終了日時<input type="datetime-local" name="ends_at"></label><label>場所<input name="place" value="${esc(event?.place || "")}"></label><label>企画幹部の連絡先<input name="contact" value="${esc(event?.contact || "")}"></label><label class="full">必要事項<textarea name="details" rows="4">${esc(event?.details || "")}</textarea></label><section id="shootingFields" class="full conditional-fields"><label><input type="checkbox" name="camera_enabled">貸出カメラを受付（上限3台）</label><label><input type="checkbox" name="disposable_enabled">写るんですを受付</label></section><section id="feeFields" class="full conditional-fields"><label><input type="checkbox" name="fee_enabled">費用を表示する</label><div id="feeAmountFields" class="form-grid nested-fields hidden"><label>費用<input type="number" name="fee" min="0"></label><label><input type="checkbox" name="payment_deadline_enabled">支払期限を表示する</label><label id="paymentDeadlineField" class="hidden">支払期限<input type="datetime-local" name="payment_deadline"></label></div></section><section id="exhibitionFields" class="full form-grid conditional-fields"><label>写真展タイトル<input name="exhibition_title"></label><label>出展可能作品数<input type="number" name="max_works" min="1"></label><label>最低シフト人数<input type="number" name="min_shift_people" min="1"></label><label class="full">シフト枠（1行1枠）<textarea name="shift_slots_text" rows="5" placeholder="8月23日 15:00〜17:00"></textarea></label></section><div class="actions full"><button type="button" id="draft" class="secondary">一時保存</button><button type="submit" id="saveEvent">保存</button></div></form>`;
  const form = document.querySelector("#eventForm"),
    local = (value) =>
      value
        ? new Date(
            new Date(value) - new Date(value).getTimezoneOffset() * 60000,
          )
            .toISOString()
            .slice(0, 16)
        : "",
    asIso = (value) => (value ? new Date(value).toISOString() : null);
  form.genre.value = event?.genre || "meeting";
  form.subtype.value = event?.subtype || "shooting";
  form.starts_at.value = local(event?.starts_at);
  form.ends_at.value = local(event?.ends_at);
  form.payment_deadline.value = local(event?.payment_deadline);
  for (const name of [
    "exhibition_title",
    "fee",
    "max_works",
    "min_shift_people",
  ])
    form.elements[name].value = event?.[name] || "";
  form.camera_enabled.checked = Boolean(event?.camera_enabled);
  form.disposable_enabled.checked = Boolean(event?.disposable_enabled);
  form.fee_enabled.checked = Boolean(event?.fee_enabled);
  form.payment_deadline_enabled.checked = Boolean(
    event?.payment_deadline_enabled,
  );
  form.shift_slots_text.value = (event?.shift_slots || [])
    .map((slot) => (typeof slot === "string" ? slot : slot.label))
    .join("\n");
  const existingSlots = event?.shift_slots || [],
    conditions = () => {
      const genre = form.genre.value,
        shooting = genre === "meeting" && form.subtype.value === "shooting",
        feeCapable =
          genre === "camp" ||
          (genre === "meeting" && form.subtype.value === "dining"),
        feeEnabled = feeCapable && form.fee_enabled.checked,
        deadlineEnabled = feeEnabled && form.payment_deadline_enabled.checked;
      document
        .querySelector("#subtypeField")
        .classList.toggle("hidden", genre !== "meeting");
      document
        .querySelector("#shootingFields")
        .classList.toggle("hidden", !shooting);
      document
        .querySelector("#feeFields")
        .classList.toggle("hidden", !feeCapable);
      document
        .querySelector("#feeAmountFields")
        .classList.toggle("hidden", !feeEnabled);
      document
        .querySelector("#paymentDeadlineField")
        .classList.toggle("hidden", !deadlineEnabled);
      document
        .querySelector("#exhibitionFields")
        .classList.toggle("hidden", genre !== "exhibition");
    };
  const snapshot = () => JSON.stringify(Object.fromEntries(new FormData(form))),
    initial = { value: "" },
    updateButtons = () => {
      const unchanged = snapshot() === initial.value;
      document.querySelector("#draft").disabled = unchanged;
      document.querySelector("#saveEvent").disabled = unchanged;
    };
  conditions();
  initial.value = snapshot();
  updateButtons();
  form.addEventListener("input", updateButtons);
  form.addEventListener("change", () => {
    conditions();
    updateButtons();
  });
  const save = async (draft) => {
    try {
      const values = Object.fromEntries(new FormData(form));
      if (!values.title.trim()) throw new Error("予定名は必須です。");
      if (!draft) {
        if (!values.starts_at || !values.place.trim() || !values.contact.trim())
          throw new Error("保存には日時、場所、企画幹部の連絡先が必要です。");
        if (values.ends_at && values.ends_at < values.starts_at)
          throw new Error("終了日時は開始日時以降にしてください。");
        if (values.fee_enabled === "on" && values.fee === "")
          throw new Error("表示する費用を入力してください。");
        if (
          values.payment_deadline_enabled === "on" &&
          !values.payment_deadline
        )
          throw new Error("表示する支払期限を入力してください。");
        if (
          values.genre === "exhibition" &&
          (!values.exhibition_title.trim() ||
            !values.max_works ||
            !values.min_shift_people ||
            !values.shift_slots_text.trim())
        )
          throw new Error("写真展の必須項目を入力してください。");
      }
      const labels = values.shift_slots_text
          .split("\n")
          .map((value) => value.trim())
          .filter(Boolean),
        shift_slots = labels.map((label) => {
          const old = existingSlots.find(
            (slot) => (typeof slot === "string" ? slot : slot.label) === label,
          );
          return typeof old === "object"
            ? old
            : { id: crypto.randomUUID(), label };
        });
      const feeCapable =
          values.genre === "camp" ||
          (values.genre === "meeting" && values.subtype === "dining"),
        feeEnabled = feeCapable && form.fee_enabled.checked,
        deadlineEnabled = feeEnabled && form.payment_deadline_enabled.checked,
        payload = {
          title: values.title.trim(),
          genre: values.genre,
          subtype: values.genre === "meeting" ? values.subtype : "",
          starts_at: asIso(values.starts_at),
          ends_at: asIso(values.ends_at),
          place: values.place.trim(),
          contact: values.contact.trim(),
          details: values.details.trim(),
          fee_enabled: feeEnabled,
          fee: feeEnabled ? Number(values.fee || 0) : 0,
          payment_deadline_enabled: deadlineEnabled,
          payment_deadline: deadlineEnabled
            ? asIso(values.payment_deadline)
            : null,
          exhibition_title:
            values.genre === "exhibition" ? values.exhibition_title.trim() : "",
          max_works:
            values.genre === "exhibition" ? Number(values.max_works || 0) : 0,
          min_shift_people:
            values.genre === "exhibition"
              ? Number(values.min_shift_people || 0)
              : 0,
          shift_slots: values.genre === "exhibition" ? shift_slots : [],
          camera_enabled:
            values.genre === "meeting" &&
            values.subtype === "shooting" &&
            form.camera_enabled.checked,
          disposable_enabled:
            values.genre === "meeting" &&
            values.subtype === "shooting" &&
            form.disposable_enabled.checked,
          status: draft ? "draft" : "saved",
          updated_at: new Date().toISOString(),
          updated_by: session.user.email,
        };
      document.querySelector("#draft").disabled = true;
      document.querySelector("#saveEvent").disabled = true;
      const query = event
        ? supabase.from("events").update(payload).eq("id", event.id)
        : supabase.from("events").insert(payload);
      const { error } = await query;
      if (error) throw error;
      await renderAdmin();
      message(draft ? "下書きを保存しました。" : "予定を保存しました。");
    } catch (error) {
      failure(error);
      updateButtons();
    }
  };
  form.onsubmit = (e) => {
    e.preventDefault();
    save(false);
  };
  document.querySelector("#draft").onclick = () => save(true);
  root.scrollIntoView({ behavior: "smooth" });
}

window.addEventListener("hashchange", () => session && navigate());
boot();

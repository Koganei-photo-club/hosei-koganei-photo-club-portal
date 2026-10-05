import "./styles.css";
import { configured, googleClientId, supabase } from "./supabase.js";
import {
  ensurePortalAvailable,
  maintenanceLoginMarkup,
  maintenanceState,
  publicMaintenanceInfo,
  renderMaintenanceAdmin,
  renderMaintenanceBlock,
  startMaintenancePolling,
  stopMaintenancePolling,
} from "./maintenance.js";

const app = document.querySelector("#app");
let session = null;
let overdueChecked = false;
let adminGenreTab = "meeting";
let authRenderGeneration = 0;
let authRenderTask = null;

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
    const hadSession = Boolean(session);
    session = next;
    if (next) {
      authRenderGeneration += 1;
      authRenderTask = null;
    } else if (hadSession) {
      authRenderGeneration += 1;
      authRenderTask = null;
    }
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

function renderAuth() {
  if (authRenderTask) return authRenderTask;
  const generation = ++authRenderGeneration;
  authRenderTask = performAuthRender(generation);
  return authRenderTask;
}

async function performAuthRender(generation) {
  layout("活動ポータル");
  hideMessage();
  let maintenanceInfo = null;
  try {
    maintenanceInfo = await publicMaintenanceInfo(supabase);
  } catch (error) {
    console.error("public maintenance information unavailable", error);
  }
  if (generation !== authRenderGeneration || session) return;
  app.insertAdjacentHTML(
    "beforeend",
    `<section class="auth-layer"><div class="panel auth-card">${maintenanceLoginMarkup(maintenanceInfo)}<p class="eyebrow">SECURE SIGN IN</p><h2>Googleアカウントでログイン</h2><p class="copy">部員は大学のGoogleアカウント、幹部は管理者として登録されたGoogleアカウントを使用してください。</p><div id="googleSignIn"></div><p id="authMessage" class="muted">Googleログインを準備しています…</p><p class="muted">LINE内で開いている場合は、外部ブラウザで開いてください。</p></div></section>`,
  );
  const authLayer = app.querySelector(".auth-layer"),
    authMessage = authLayer.querySelector("#authMessage"),
    googleSignIn = authLayer.querySelector("#googleSignIn");
  if (!googleClientId) {
    authMessage.textContent = "Google Client IDが未設定です。";
    return;
  }
  try {
    await loadGoogleIdentity();
    if (
      generation !== authRenderGeneration ||
      session ||
      !authLayer.isConnected
    )
      return;
    const { nonce, hashed } = await createGoogleNonce();
    if (
      generation !== authRenderGeneration ||
      session ||
      !authLayer.isConnected
    )
      return;
    google.accounts.id.initialize({
      client_id: googleClientId,
      nonce: hashed,
      use_fedcm_for_prompt: true,
      itp_support: true,
      auto_select: false,
      callback: async (response) => {
        if (
          generation !== authRenderGeneration ||
          session ||
          !authLayer.isConnected
        )
          return;
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
    google.accounts.id.renderButton(googleSignIn, {
      type: "standard",
      shape: "rectangular",
      theme: "outline",
      text: "continue_with",
      size: "large",
      logo_alignment: "left",
      width: 300,
    });
    if (generation === authRenderGeneration && authLayer.isConnected)
      authMessage.textContent = "";
  } catch (error) {
    if (generation === authRenderGeneration && authLayer.isConnected)
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
  stopMaintenancePolling();
  try {
    const path = route();
    let maintenance;
    try {
      maintenance = await maintenanceState(supabase);
    } catch (error) {
      console.error("maintenance state unavailable", error);
      renderMaintenanceBlock({
        app,
        layout,
        hideMessage,
        supabase,
        state: { state: "state_unavailable" },
        retry: navigate,
      });
      return;
    }
    if (path === "/maintenance-admin") {
      if (!maintenance.isMaintenanceAdmin) {
        renderAccessDenied(session.user.email);
        return;
      }
      return renderMaintenanceAdmin({
        supabase,
        layout,
        hideMessage,
        message,
        failure,
      });
    }
    if (maintenance.state === "maintenance_state_error") {
      if (maintenance.isMaintenanceAdmin) {
        location.hash = "/maintenance-admin";
        return renderMaintenanceAdmin({
          supabase,
          layout,
          hideMessage,
          message,
          failure,
        });
      }
      renderMaintenanceBlock({ app, layout, hideMessage, supabase, state: maintenance, retry: navigate });
      return;
    }
    if (maintenance.state === "maintenance" && !maintenance.isMaintenanceAdmin) {
      renderMaintenanceBlock({ app, layout, hideMessage, supabase, state: maintenance, retry: navigate });
      return;
    }
    if (!overdueChecked) {
      overdueChecked = true;
      const { error } = await supabase.rpc(
        "apply_overdue_payment_cancellations",
      );
      if (error) console.warn("期限超過処理を実行できませんでした。", error);
    }
    const context = await getContext();
    if (!context.member && !context.admin && !maintenance.isMaintenanceAdmin) {
      renderAccessDenied(context.email);
      return;
    }
    startMaintenancePolling(supabase, () => navigate());
    if (path.startsWith("/event/"))
      return renderEvent(path.split("/")[2], context);
    if (path === "/admin") return renderAdmin(context, maintenance);
    return renderPortal(context, maintenance);
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

async function renderPortal(context, maintenance = null) {
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
    if (maintenance?.isMaintenanceAdmin)
      document
        .querySelector(".header-actions")
        .insertAdjacentHTML(
          "afterbegin",
          '<a class="button secondary" href="#/maintenance-admin">メンテナンス管理</a>',
        );
    const { data: events, error } = await supabase
      .from("events")
      .select("*,event_responses(*)")
      .is("deleted_at", null)
      .order("starts_at");
    if (error) throw error;
    console.debug("[response-debug][portal]", {
      authEmail: session?.user?.email,
      contextMemberId: context.member?.id,
      events: (events || []).map((event) => ({
        eventId: event.id,
        eventTitle: event.title,
        responseCount: event.event_responses?.length ?? 0,
        responseMemberIds:
        event.event_responses?.map((response) => response.member_id) ?? [],
      })),
    });
    let exhibitionEntries = {};
    let waitlistEntries = [], waitlistOffers = [];
    if (context.member) {
      const [{ data: entries, error: entryError }, { data: waiting, error: waitingError }, { data: offers, error: offersError }] = await Promise.all([
        supabase.from("exhibition_entries").select("event_id,status,exhibition_works(status,orientation,print_size,publication_consent)").eq("member_id", context.member.id),
        supabase.from("event_waitlist_entries").select("*").eq("member_id", context.member.id).order("created_at", { ascending: false }),
        supabase.from("event_waitlist_offers").select("*").eq("member_id", context.member.id).eq("status", "pending"),
      ]);
      if (entryError) throw entryError;
      if (waitingError) throw waitingError;
      if (offersError) throw offersError;
      waitlistEntries = waiting || [];
      waitlistOffers = offers || [];
      exhibitionEntries = Object.fromEntries(
        (entries || []).map((entry) => [entry.event_id, entry]),
      );
    }
    hideMessage();
    const view = document.querySelector("#view"),
      membership = context.member?.membership_years?.find(
        (y) => y.fiscal_year === fiscalYear() && y.active,
      );
    view.innerHTML = `<section class="panel"><span class="tag">MEMBER</span><h2>${esc(context.member?.name || context.email)}さん</h2>${context.member ? `<p>${esc([context.member.grade, context.member.faculty || context.member.graduate_school, context.member.department || context.member.major].filter(Boolean).join("・"))}</p><p>部員ID：${esc(context.member.member_no)}</p><p class="status">${membership ? `${fiscalYear()}年度 在籍中` : `${fiscalYear()}年度の在籍登録はありません`}</p>` : "<p>部員名簿に登録されていません。</p>"}</section><section id="eventSections"></section><div class="section-head"><p class="eyebrow">MY EXHIBITION</p><h2>写真展マイページ</h2></div><section id="archives" class="stack"></section>`;
    const now = new Date(),
      effectiveEnd = (event) => {
        if (event.ends_at) return new Date(event.ends_at);
        const parts = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Tokyo", year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date(event.starts_at)),
          part = (type) => parts.find((item) => item.type === type).value,
          firstDay = new Date(`${part("year")}-${part("month")}-${part("day")}T00:00:00+09:00`);
        return new Date(firstDay.getTime() + 3 * 86400000);
      },
      activeEvents = (events || []).filter((event) => effectiveEnd(event) > now),
      availabilityPairs = await Promise.all(activeEvents.filter((event) => event.genre !== "exhibition").map(async (event) => {
        const { data } = await supabase.rpc("get_event_availability", { p_event_id: event.id });
        return [event.id, data];
      })),
      availabilityByEvent = Object.fromEntries(availabilityPairs),
      latestWaitlist = Object.fromEntries(waitlistEntries.map((entry) => [entry.event_id, entry])),
      offerByEvent = Object.fromEntries(waitlistOffers.map((offer) => [offer.event_id, offer])),
      categories = { action: [], joined: [], available: [], past: [] };
    (events || []).forEach((event) => {
      const response = event.event_responses?.find(
        (r) => r.member_id === context.member?.id
      ),
        entry = exhibitionEntries[event.id],
        entryWorks = (entry?.exhibition_works || []).filter(
          (work) => work.status !== "withdrawn",
        ),
        state = entryWorks.some(
          (work) =>
            work.status === "rejected" ||
            !work.orientation ||
            !work.print_size ||
            work.publication_consent === null,
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
                  : "",
        past = effectiveEnd(event) <= now,
        joined = response?.attendance === "参加" && !response.cancelled_at,
        actionable = Boolean(offerByEvent[event.id]),
        waiting = latestWaitlist[event.id]?.status === "waiting",
        availability = availabilityByEvent[event.id],
        full = Boolean(availability?.isFull),
        card = { event, response, state, waiting, full };
      if (actionable) categories.action.push(card);
      else if (past && joined) categories.past.push(card);
      else if (!past && joined) categories.joined.push(card);
      else if (!past && (event.genre === "exhibition" || !response || waiting || response.cancelled_at)) categories.available.push(card);
    });
    categories.past.sort((a, b) => new Date(b.event.starts_at) - new Date(a.event.starts_at));
    const cardHtml = ({ event, response, state, waiting, full }) => `<a class="card" href="#/event/${event.id}"><div><span class="tag">${eventLabel(event)}</span><h3>${esc(event.title)}</h3><p>${fmt(event.starts_at)}・${esc(event.place)}</p>${full ? '<p class="capacity-warning">定員に達しました</p>' : ""}${waiting ? '<p class="status">キャンセル待ち登録済み</p>' : event.genre === "exhibition" && state ? `<p class="status">${state}</p>` : response ? `<p class="status">${response.cancelled_at ? "キャンセル済み・再参加可能" : `回答済み：${esc(response.attendance)}`}</p>` : ""}</div><strong>→</strong></a>`;
    const sectionRoot = document.querySelector("#eventSections"), sections = [
      ["action", "ACTION REQUIRED", "回答が必要です"], ["joined", "JOINED EVENTS", "参加申込済みのイベント"], ["available", "AVAILABLE EVENTS", "参加可能なイベント"], ["past", "PAST EVENTS", "過去に参加したイベント"],
    ];
    sections.forEach(([key, eyebrow, title]) => {
      const items = categories[key];
      sectionRoot.insertAdjacentHTML("beforeend", `<div class="section-head"><p class="eyebrow">${eyebrow}</p><h2>${title}</h2></div><section class="grid" data-category="${key}">${items.length ? items.map((item, index) => `<div class="event-card-wrap${index >= 2 ? ` hidden category-extra category-extra-${key}` : ""}">${cardHtml(item)}</div>`).join("") : `<div class="panel muted">${key === "available" ? "現在参加できる活動はありません。" : "該当する予定はありません。"}</div>`}</section>${items.length > 2 ? `<div class="actions"><button class="secondary toggle-category" data-target="${key}">もっと見る</button></div>` : ""}`);
    });
    document.querySelectorAll(".toggle-category").forEach((button) => button.onclick = () => {
      const extras = document.querySelectorAll(`.category-extra-${button.dataset.target}`), expanding = [...extras].some((item) => item.classList.contains("hidden"));
      extras.forEach((item) => item.classList.toggle("hidden", !expanding));
      button.textContent = expanding ? "表示数を減らす" : "もっと見る";
    });
    await renderArchives(context.member?.id);
  } catch (error) {
    failure(error);
  }
}

async function renderArchives(memberId) {
  const root = document.querySelector("#archives");
  if (!memberId) {
    root.innerHTML =
      '<div class="panel muted">部員名簿に登録されると、写真展の履歴を確認できます。</div>';
    return;
  }
  const { data: works, error } = await supabase
    .from("archive_works")
    .select("*,archive_exhibitions(*),archive_work_comments(*)")
    .eq("owner_member_id", memberId);
  if (error) throw error;
  if (!works?.length) {
    root.innerHTML =
      '<div class="panel muted">公開中の作品アーカイブはありません。</div>';
    return;
  }
  works.forEach((work) =>
    work.archive_work_comments.sort(
      (a, b) => new Date(a.submitted_at || 0) - new Date(b.submitted_at || 0),
    ),
  );
  const sortedWorks = [...works].sort(
      (a, b) => Number(a.display_no) - Number(b.display_no),
    ),
    grouped = sortedWorks.reduce((result, work) => {
      (result[work.exhibition_id] ??= []).push(work);
      return result;
    }, {});
  root.innerHTML = "";
  Object.values(grouped).forEach((items) =>
    root.insertAdjacentHTML(
      "beforeend",
      `<article class="panel"><span class="tag">EXHIBITION ARCHIVE</span><h3>${esc(items[0].archive_exhibitions.title)}</h3><div class="grid">${items.map((w) => `<section class="archive-work-card">${w.image_path && w.image_visible ? `<div class="archive-work-image" data-path="${esc(w.image_path)}"><span class="muted">作品画像を読み込んでいます…</span></div>` : '<div class="archive-work-image is-empty"><span class="muted">画像は未登録です</span></div>'}<p class="tag">No.${esc(w.display_no)}</p><h3>${esc(w.title)}</h3><p><strong>${w.favorite_count}票</strong>・${w.favorite_rate}%</p><details><summary>寄せられた感想（${w.archive_work_comments.length}件）</summary><ul>${w.archive_work_comments.map((c) => `<li>${esc(c.comment)}</li>`).join("")}</ul></details></section>`).join("")}</div></article>`,
    ),
  );
  root.querySelectorAll(".archive-work-image[data-path]").forEach(
    async (target) => {
      const { data, error } = await supabase.storage
        .from("exhibition-previews")
        .createSignedUrl(target.dataset.path, 900);
      if (error) {
        target.innerHTML =
          '<span class="muted">画像を表示できませんでした。</span>';
        return;
      }
      target.innerHTML = `<img src="${esc(data.signedUrl)}" alt="本人の出展作品" draggable="false">`;
      target.oncontextmenu = (event) => event.preventDefault();
    },
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
const publicImageExtension = (file) =>
  ({ "image/jpeg": "jpg", "image/png": "png", "image/webp": "webp" })[
    file.type
  ];
const exhibitionSiteStatusLabel = (status) =>
  status === "published"
    ? "写真展サイト公開中"
    : status === "ended"
      ? "写真展サイト終了"
      : "写真展サイト下書き";

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

async function createWatermarkedPublicImage(previewPath) {
  const { data, error } = await supabase.storage
    .from("exhibition-previews")
    .createSignedUrl(previewPath, 300);
  if (error) throw error;
  const [imageResponse, logoResponse] = await Promise.all([
    fetch(data.signedUrl),
    fetch(`${location.origin}/photo-exhibition-site/images/photoiconclubs.png`),
  ]);
  if (!imageResponse.ok || !logoResponse.ok)
    throw new Error("作品画像または透かしロゴを読み込めませんでした。");
  const source = await createImageBitmap(await imageResponse.blob()),
    logo = await createImageBitmap(await logoResponse.blob()),
    scale = Math.min(1, 2400 / Math.max(source.width, source.height)),
    canvas = document.createElement("canvas"),
    context = canvas.getContext("2d");
  canvas.width = Math.max(1, Math.round(source.width * scale));
  canvas.height = Math.max(1, Math.round(source.height * scale));
  context.drawImage(source, 0, 0, canvas.width, canvas.height);
  const shortEdge = Math.min(canvas.width, canvas.height),
    logoSize = Math.max(56, Math.round(shortEdge * 0.21)),
    step = Math.max(120, Math.round(shortEdge * 0.34));
  context.globalAlpha = 0.08;
  for (let y = -step; y < canvas.height + step; y += step) {
    for (let x = -step; x < canvas.width + step; x += step) {
      context.save();
      context.translate(x + step / 2, y + step / 2);
      context.rotate((-25 * Math.PI) / 180);
      context.drawImage(logo, -logoSize / 2, -logoSize / 2, logoSize, logoSize);
      context.restore();
    }
  }
  context.globalAlpha = 1;
  source.close?.();
  logo.close?.();
  const blob = await new Promise((resolve, reject) =>
    canvas.toBlob(
      (value) => value ? resolve(value) : reject(new Error("公開用画像を生成できませんでした。")),
      "image/webp",
      0.88,
    ),
  );
  return blob;
}

async function renderExhibitionApplicationV2(event, context) {
  layout(
    "写真展出展申込",
    '<a class="button secondary" href="#/">ポータルトップに戻る</a>',
  );
  try {
    if (!context.member)
      throw new Error("出展申込には部員名簿への登録が必要です。");
    const [{ data: entry, error: entryError }, { data: agreement, error: agreementError }] =
      await Promise.all([
        supabase
          .from("exhibition_entries")
          .select("*")
          .eq("event_id", event.id)
          .eq("member_id", context.member.id)
          .maybeSingle(),
        supabase.rpc("get_current_exhibition_agreement", {
          p_event_id: event.id,
        }),
      ]);
    if (entryError) throw entryError;
    if (agreementError) throw agreementError;
    if (!agreement) throw new Error("現在有効な申込同意文が設定されていません。");

    const now = Date.now(),
      applicationOpen =
        event.exhibition_application_deadline &&
        now < new Date(event.exhibition_application_deadline).getTime(),
      workingOpen =
        event.exhibition_work_submission_deadline &&
        now < new Date(event.exhibition_work_submission_deadline).getTime(),
      active = entry?.application_state === "active",
      withdrawn = entry?.application_state === "withdrawn",
      autoCancelled = entry?.application_state === "auto_cancelled",
      canEdit = autoCancelled ? false : active ? workingOpen : applicationOpen,
      stateLabel = active
        ? "申込済み"
        : autoCancelled
          ? "SYSTEM自動取消"
        : withdrawn
          ? "申込取消済み"
          : entry
            ? "入力中"
            : "未申込",
      initialType = entry?.display_name_type || "real_name",
      initialName =
        initialType === "pseudonym"
          ? entry?.display_name_value || ""
          : context.member.name,
      view = document.querySelector("#view");
    hideMessage();
    view.innerHTML = `<section class="panel"><span class="tag">EXHIBITION APPLICATION</span><h2>${esc(event.exhibition_title || event.title)}</h2><dl><dt>開催日時</dt><dd>${fmt(event.starts_at)}${event.ends_at ? ` 〜 ${fmt(event.ends_at)}` : ""}</dd><dt>出展申込締切</dt><dd>${fmt(event.exhibition_application_deadline)}</dd><dt>作品提出締切</dt><dd>${fmt(event.exhibition_work_submission_deadline)}</dd><dt>修正期限</dt><dd>${fmt(event.exhibition_revision_deadline)}</dd><dt>キャプション締切</dt><dd>${fmt(event.exhibition_caption_deadline)}</dd><dt>場所</dt><dd>${esc(event.place)}</dd><dt>出展上限</dt><dd>1人 ${event.max_works}作品</dd></dl><p class="copy">${esc(event.details)}</p></section><section class="panel exhibition-entry-panel"><div class="entry-heading"><div><span class="tag">YOUR APPLICATION</span><h2>出展申込</h2></div><span class="status">${stateLabel}</span></div>${autoCancelled ? '<div class="notice error">有効な作品がなくなったため申込はSYSTEMにより自動取消されました。復活が必要な場合は幹部へ連絡してください。</div>' : ""}${!applicationOpen && !active && !autoCancelled ? '<div class="notice error">出展申込受付は終了しました。</div>' : ""}${active ? '<div class="notice">出展申込は成立しています。作品は作品提出締切までに、後続の作品提出画面から登録します。</div>' : ""}${active && !workingOpen && !(entry?.revival_deadline && now < new Date(entry.revival_deadline).getTime()) ? '<div class="notice error">作品提出締切を過ぎたため、申込内容は変更できません。</div>' : ""}<form id="applicationForm" class="stack"><label>出展予定作品数<input type="number" name="planned_work_count" min="1" max="${event.max_works}" required value="${entry?.planned_work_count || 1}"><small>予定数です。最終的な提出作品数を固定するものではありません。</small></label><fieldset><legend>作者表示名</legend><label><input type="radio" name="display_name_type" value="real_name" ${initialType === "real_name" ? "checked" : ""}>本名（${esc(context.member.name)}）</label><label><input type="radio" name="display_name_type" value="pseudonym" ${initialType === "pseudonym" ? "checked" : ""}>ペンネーム</label><label id="pseudonymField" class="${initialType === "pseudonym" ? "" : "hidden"}">ペンネーム<input name="display_name_value" maxlength="100" value="${esc(initialType === "pseudonym" ? initialName : "")}"></label></fieldset><label>申込に関する備考（任意）<textarea name="note" maxlength="3000" rows="4">${esc(entry?.note || "")}</textarea></label>${active || autoCancelled ? "" : `<section class="notice agreement"><h3>Application Agreement</h3><p class="copy">${esc(agreement.content)}</p><p><strong>重要：</strong>作品提出締切時点で正式提出作品が0件の場合、申込はSYSTEMにより自動取消されます。</p><label><input type="checkbox" name="agreement_confirmed" required>同意内容と重要事項を確認し、同意します</label></section>`}<div class="actions">${active || autoCancelled ? "" : `<button type="button" id="saveApplicationDraft" class="secondary" ${canEdit ? "" : "disabled"}>下書き保存</button>`}<button type="submit" id="applicationPrimary" ${canEdit ? "" : "disabled"}>${active ? "変更を保存" : withdrawn ? "再申込内容を確認" : "申込内容を確認"}</button>${active && applicationOpen ? '<button type="button" id="withdrawApplication" class="danger">申込を取り消す</button>' : ""}</div></form><section id="applicationConfirmation" class="stack hidden"></section></section>`;

    const form = document.querySelector("#applicationForm"),
      confirmation = document.querySelector("#applicationConfirmation"),
      typeInputs = [...form.querySelectorAll('[name="display_name_type"]')],
      pseudonymField = document.querySelector("#pseudonymField");
    const updateNameField = () => {
      const type = form.querySelector('[name="display_name_type"]:checked')?.value;
      pseudonymField.classList.toggle("hidden", type !== "pseudonym");
      form.display_name_value.required = type === "pseudonym";
    };
    typeInputs.forEach((input) => (input.onchange = updateNameField));
    updateNameField();

    document.querySelector("#saveApplicationDraft")?.addEventListener("click", async () => {
      try {
        if (!(await ensurePortalAvailable(supabase))) return;
        const data = values(),
          { error } = await supabase.rpc("save_exhibition_application_draft_v2", {
            p_event_id: event.id,
            p_planned_work_count: data.plannedWorkCount,
            p_display_name_type: data.displayNameType,
            p_display_name_value: data.displayNameValue,
            p_note: data.note,
          });
        if (error) throw error;
        await renderExhibitionApplicationV2(event, context);
        message(withdrawn ? "再申込内容を下書き保存しました。" : "出展申込を下書き保存しました。");
      } catch (error) {
        failure(error);
      }
    });

    const values = () => {
      const displayNameType = form.querySelector(
          '[name="display_name_type"]:checked',
        )?.value,
        displayNameValue =
          displayNameType === "real_name"
            ? context.member.name
            : form.display_name_value.value.trim(),
        plannedWorkCount = Number(form.planned_work_count.value);
      if (!Number.isInteger(plannedWorkCount) || plannedWorkCount < 1 || plannedWorkCount > event.max_works)
        throw new Error(`出展予定作品数は1〜${event.max_works}点で入力してください。`);
      if (!displayNameValue) throw new Error("ペンネームを入力してください。");
      return {
        plannedWorkCount,
        displayNameType,
        displayNameValue,
        note: form.note.value.trim(),
      };
    };

    form.onsubmit = async (submit) => {
      submit.preventDefault();
      try {
        if (!(await ensurePortalAvailable(supabase))) return;
        const data = values();
        if (active) {
          const { error } = await supabase.rpc(
            "update_exhibition_application_working_data_v2",
            {
              p_event_id: event.id,
              p_planned_work_count: data.plannedWorkCount,
              p_display_name_type: data.displayNameType,
              p_display_name_value: data.displayNameValue,
              p_note: data.note,
            },
          );
          if (error) throw error;
          await renderExhibitionApplicationV2(event, context);
          message("申込内容を更新しました。正式申込時のSnapshotは保持されています。");
          return;
        }
        if (!form.querySelector('[name="agreement_confirmed"]')?.checked)
          throw new Error("Application Agreementへの同意が必要です。");
        form.classList.add("hidden");
        confirmation.classList.remove("hidden");
        confirmation.innerHTML = `<div><span class="tag">CONFIRM</span><h3>この内容で${withdrawn ? "再申込" : "申込"}しますか？</h3></div><dl><dt>出展予定作品数</dt><dd>${data.plannedWorkCount}点</dd><dt>作者表示名</dt><dd>${esc(data.displayNameValue)}（${data.displayNameType === "real_name" ? "本名" : "ペンネーム"}）</dd><dt>備考</dt><dd>${esc(data.note || "なし")}</dd><dt>同意文Version</dt><dd>${agreement.versionNo}／${esc(agreement.referenceKey)}</dd></dl><div class="notice">申込後、作品は作品提出締切までに別途提出します。</div><div class="actions"><button id="confirmApplication">${withdrawn ? "再申込を確定" : "出展申込を確定"}</button><button id="backToApplication" class="secondary">入力へ戻る</button></div>`;
        document.querySelector("#backToApplication").onclick = () => {
          confirmation.classList.add("hidden");
          form.classList.remove("hidden");
        };
        document.querySelector("#confirmApplication").onclick = async () => {
          const button = document.querySelector("#confirmApplication");
          button.disabled = true;
          try {
            const { error } = await supabase.rpc(
              "submit_exhibition_application_v2",
              {
                p_event_id: event.id,
                p_planned_work_count: data.plannedWorkCount,
                p_display_name_type: data.displayNameType,
                p_display_name_value: data.displayNameValue,
                p_note: data.note,
                p_expected_agreement_id: agreement.id,
                p_expected_agreement_hash: agreement.contentHash,
              },
            );
            if (error) throw error;
            await renderExhibitionApplicationV2(event, context);
            message(withdrawn ? "出展を再申込しました。" : "出展申込を確定しました。");
          } catch (error) {
            button.disabled = false;
            failure(error);
          }
        };
      } catch (error) {
        failure(error);
      }
    };
    document.querySelector("#withdrawApplication")?.addEventListener("click", async () => {
      if (!confirm("出展申込を取り消しますか？過去の申込Snapshotと作品データは削除されません。")) return;
      const reason = prompt("取消理由（任意）", "") ?? null;
      if (reason === null) return;
      try {
        const { error } = await supabase.rpc("withdraw_exhibition_application_v2", {
          p_event_id: event.id,
          p_reason: reason.trim(),
        });
        if (error) throw error;
        await renderExhibitionApplicationV2(event, context);
        message("出展申込を取り消しました。締切前であれば再申込できます。");
      } catch (error) {
        failure(error);
      }
    });
    if (active) await renderExhibitionWorksV2(event, context, entry);
  } catch (error) {
    failure(error);
  }
}

async function sha256Hex(file) {
  const hash = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return [...new Uint8Array(hash)]
    .map((value) => value.toString(16).padStart(2, "0"))
    .join("");
}

async function renderExhibitionWorksV2(event, context, entry) {
  const host = document.querySelector("#view");
  host.insertAdjacentHTML(
    "beforeend",
    '<section id="v2WorkManager" class="panel"><div class="entry-heading"><div><span class="tag">WORK SUBMISSION</span><h2>作品提出</h2></div><button id="newV2Work" class="secondary">作品Draftを作成</button></div><p class="muted">キャプション情報は次のPhaseで別途登録します。作品確認済みは最終的な「出展確定」ではありません。</p><div id="v2WorkSummary" class="summary-strip"></div><div id="v2WorkList" class="stack"></div><div class="actions"><button id="submitV2WorkBatch">提出可能な作品をまとめて正式提出</button></div></section>',
  );
  const root = document.querySelector("#v2WorkManager"),
    [{ data: works, error }, { data: cases, error: casesError }, { data: reviews, error: reviewsError }] =
      await Promise.all([
        supabase.from("exhibition_works").select("*").eq("entry_id", entry.id).order("sort_order"),
        supabase.from("exhibition_workflow_cases").select("*").eq("event_id", event.id).order("requested_at", { ascending: false }),
        supabase.from("exhibition_work_reviews").select("*").in("work_id", ["00000000-0000-0000-0000-000000000000"]),
      ]);
  if (error) throw error;
  if (casesError) throw casesError;
  if (reviewsError) throw reviewsError;
  const activeWorks = (works || []).filter((work) => work.workflow_state !== "withdrawn"),
    workIds = activeWorks.map((work) => work.id);
  let reviewRows = reviews || [];
  if (workIds.length) {
    const { data, error: reviewLoadError } = await supabase
      .from("exhibition_work_reviews")
      .select("*")
      .in("work_id", workIds)
      .order("reviewed_at", { ascending: false });
    if (reviewLoadError) throw reviewLoadError;
    reviewRows = data || [];
  }
  const editableStates = new Set(["draft", "rejected", "reedit_editing"]),
    ready = (work) =>
      editableStates.has(work.workflow_state) &&
      work.original_image_path &&
      work.original_sha256 &&
      work.title?.trim() &&
      ["portrait", "landscape"].includes(work.orientation) &&
      work.print_size &&
      (!["composite", "other"].includes(work.print_size) || work.print_size_detail?.trim()) &&
      Number(work.occupied_width_mm) > 0 &&
      Number(work.occupied_height_mm) > 0 &&
      work.publication_consent !== null,
    stateLabel = (work) =>
      work.workflow_state === "accepted"
        ? "作品確認済み（キャプション確認前）"
        : work.workflow_state === "rejected"
          ? "要修正"
          : work.workflow_state === "submitted"
            ? "確認待ち"
            : work.workflow_state === "reedit_pending"
              ? "再編集申請中"
              : work.workflow_state === "reedit_editing"
                ? "再編集中"
                : "Draft";
  root.querySelector("#v2WorkSummary").innerHTML = `<span>有効 ${activeWorks.length}点</span><span>提出可能 ${activeWorks.filter(ready).length}点</span><span>未完成 ${activeWorks.filter((work) => editableStates.has(work.workflow_state) && !ready(work)).length}点</span><span>確認待ち ${activeWorks.filter((work) => work.workflow_state === "submitted").length}点</span><span>作品確認済み ${activeWorks.filter((work) => work.workflow_state === "accepted").length}点</span>`;
  const list = root.querySelector("#v2WorkList");
  if (!activeWorks.length) list.innerHTML = '<p class="muted">作品Draftはまだありません。</p>';
  activeWorks.forEach((work) => {
    const editable = editableStates.has(work.workflow_state),
      latestReview = reviewRows.find((review) => review.work_id === work.id),
      openCase = (cases || []).find(
        (item) => item.work_id === work.id && ["pending", "open", "permitted"].includes(item.state),
      );
    list.insertAdjacentHTML(
      "beforeend",
      `<article class="work-editor v2-work-card" data-id="${work.id}"><div class="work-editor-head"><div><span class="tag">WORK ${work.sort_order}</span><h3>${stateLabel(work)}</h3></div><span class="status">${ready(work) ? "提出可能" : editable ? "未完成" : "ロック中"}</span></div>${latestReview?.result === "rejected" ? `<div class="notice error"><strong>要修正：</strong>${esc((latestReview.problem_fields || []).join("・"))}<br>${esc(latestReview.reason)}</div>` : ""}${openCase?.individual_deadline ? `<p class="notice">個別期限：${fmt(openCase.individual_deadline)}</p>` : ""}<div class="form-grid"><label>作品名<input name="title" value="${esc(work.title || "")}" ${editable ? "" : "disabled"}></label><label>原画像<input name="original" type="file" accept="image/jpeg,image/png,image/tiff,image/heic,image/heif,.jpg,.jpeg,.png,.tif,.tiff,.heic,.heif" ${editable ? "" : "disabled"}><small>${work.original_image_path ? `登録済み：${esc(work.original_image_path.split("/").pop())}` : "未登録"}</small></label><label>向き<select name="orientation" ${editable ? "" : "disabled"}><option value="">選択</option><option value="portrait" ${work.orientation === "portrait" ? "selected" : ""}>縦</option><option value="landscape" ${work.orientation === "landscape" ? "selected" : ""}>横</option></select></label><label>プリントサイズ<select name="print_size" ${editable ? "" : "disabled"}><option value="">選択</option>${["A4", "A3", "A2", "composite", "other"].map((value) => `<option value="${value}" ${work.print_size === value ? "selected" : ""}>${value === "composite" ? "組み写真" : value === "other" ? "その他" : value}</option>`).join("")}</select></label><label>サイズ詳細<input name="print_size_detail" value="${esc(work.print_size_detail || "")}" ${editable ? "" : "disabled"}></label><label>壁面占有幅（mm）<input name="occupied_width_mm" type="number" min="0.01" step="0.01" value="${work.occupied_width_mm || ""}" ${editable ? "" : "disabled"}></label><label>壁面占有高さ（mm）<input name="occupied_height_mm" type="number" min="0.01" step="0.01" value="${work.occupied_height_mm || ""}" ${editable ? "" : "disabled"}></label><fieldset class="full"><legend>写真展サイト掲載</legend><label><input type="radio" name="publication_consent_${work.id}" value="true" ${work.publication_consent === true ? "checked" : ""} ${editable ? "" : "disabled"}>同意する</label><label><input type="radio" name="publication_consent_${work.id}" value="false" ${work.publication_consent === false ? "checked" : ""} ${editable ? "" : "disabled"}>同意しない</label></fieldset></div><div class="actions">${editable ? '<button class="save-v2-work">Draft保存</button>' : ""}${work.workflow_state === "accepted" ? '<button class="request-reedit secondary">再編集を申請</button>' : ""}${work.workflow_state === "reedit_pending" && openCase ? '<button class="cancel-reedit secondary">再編集申請を取り消す</button>' : ""}${work.workflow_state === "reedit_editing" && openCase ? '<button class="restore-accepted secondary">変更を取りやめる</button>' : ""}${new Date() < new Date(event.exhibition_work_submission_deadline) && !work.replacement_for_work_id ? '<button class="start-replacement secondary">別作品へ差し替える</button>' : ""}${work.replacement_for_work_id && work.workflow_state === "draft" ? '<button class="cancel-replacement secondary">差し替えを取り消す</button>' : ""}<button class="withdraw-v2-work danger">作品を取り下げる</button></div></article>`,
    );
  });
  root.querySelector("#newV2Work").disabled = activeWorks.filter((work) => !work.replacement_for_work_id).length >= event.max_works;
  root.querySelector("#newV2Work").onclick = async () => {
    const { error } = await supabase.rpc("save_exhibition_work_draft_v2", {
      p_event_id: event.id, p_work_id: null, p_title: "", p_orientation: "", p_print_size: "",
      p_print_size_detail: "", p_occupied_width_mm: null, p_occupied_height_mm: null,
      p_publication_consent: null, p_original_image_path: null, p_original_sha256: null,
    });
    if (error) return failure(error);
    renderExhibitionApplicationV2(event, context);
  };
  root.querySelectorAll(".v2-work-card").forEach((card) => {
    const work = activeWorks.find((item) => item.id === card.dataset.id),
      openCase = (cases || []).find((item) => item.work_id === work.id && ["pending", "open", "permitted"].includes(item.state));
    card.querySelector(".save-v2-work")?.addEventListener("click", async () => {
      const file = card.querySelector('[name="original"]').files[0];
      let path = work.original_image_path, hash = work.original_sha256;
      try {
        if (file) {
          if (file.size > 52428800) throw new Error("原画像が50MBを超えています。");
          hash = await sha256Hex(file);
          path = `${event.id}/${context.member.id}/${work.id}/draft-${crypto.randomUUID()}.${originalExtension(file)}`;
          const { error: uploadError } = await supabase.storage.from("exhibition-originals").upload(path, file, { contentType: file.type });
          if (uploadError) throw uploadError;
        }
        const consent = card.querySelector(`[name="publication_consent_${work.id}"]:checked`)?.value;
        const { error } = await supabase.rpc("save_exhibition_work_draft_v2", {
          p_event_id: event.id, p_work_id: work.id, p_title: card.querySelector('[name="title"]').value,
          p_orientation: card.querySelector('[name="orientation"]').value,
          p_print_size: card.querySelector('[name="print_size"]').value,
          p_print_size_detail: card.querySelector('[name="print_size_detail"]').value,
          p_occupied_width_mm: Number(card.querySelector('[name="occupied_width_mm"]').value) || null,
          p_occupied_height_mm: Number(card.querySelector('[name="occupied_height_mm"]').value) || null,
          p_publication_consent: consent == null ? null : consent === "true",
          p_original_image_path: path, p_original_sha256: hash,
        });
        if (error) throw error;
        await renderExhibitionApplicationV2(event, context); message("作品Draftを保存しました。");
      } catch (saveError) { failure(saveError); }
    });
    card.querySelector(".withdraw-v2-work").onclick = async () => {
      const accepted = work.workflow_state === "accepted";
      if (!confirm(accepted ? "確認済み作品を取り下げます。正式履歴は残り、元に戻せません。本当に続けますか？" : "作品を取り下げますか？正式履歴は削除されません。")) return;
      const reason = accepted ? prompt("確認済み作品の取り下げ理由（必須）") : prompt("取り下げ理由（任意）", "");
      if (reason === null) return;
      const { error } = await supabase.rpc("withdraw_exhibition_work_v2", { p_work_id: work.id, p_reason: reason });
      if (error) return failure(error); renderExhibitionApplicationV2(event, context);
    };
    card.querySelector(".request-reedit")?.addEventListener("click", async () => {
      const reason = prompt("再編集が必要な理由（必須）"); if (!reason) return;
      const { error } = await supabase.rpc("request_exhibition_work_reedit_v2", { p_work_id: work.id, p_reason: reason });
      if (error) return failure(error); renderExhibitionApplicationV2(event, context);
    });
    card.querySelector(".cancel-reedit")?.addEventListener("click", async () => {
      const { error } = await supabase.rpc("cancel_exhibition_work_reedit_request_v2", { p_case_id: openCase.id });
      if (error) return failure(error); renderExhibitionApplicationV2(event, context);
    });
    card.querySelector(".restore-accepted")?.addEventListener("click", async () => {
      if (!confirm("変更を破棄し、最後に確認済みとなった内容へ戻しますか？")) return;
      const { error } = await supabase.rpc("cancel_permitted_exhibition_work_reedit_v2", { p_case_id: openCase.id, p_reason: "" });
      if (error) return failure(error); renderExhibitionApplicationV2(event, context);
    });
    card.querySelector(".start-replacement")?.addEventListener("click", async () => {
      if (!confirm("この作品のReplacement Draftを作成しますか？元作品は新作品の正式提出まで維持されます。")) return;
      const { error } = await supabase.rpc("start_exhibition_work_replacement_v2", { p_old_work_id: work.id });
      if (error) return failure(error); renderExhibitionApplicationV2(event, context);
    });
    card.querySelector(".cancel-replacement")?.addEventListener("click", async () => {
      const { error } = await supabase.rpc("cancel_exhibition_work_replacement_v2", { p_replacement_work_id: work.id });
      if (error) return failure(error); renderExhibitionApplicationV2(event, context);
    });
  });
  const readyIds = activeWorks.filter(ready).map((work) => work.id);
  root.querySelector("#submitV2WorkBatch").disabled = !readyIds.length;
  root.querySelector("#submitV2WorkBatch").onclick = async () => {
    if (!confirm(`提出可能な${readyIds.length}作品を正式提出しますか？未完成Draftは残ります。`)) return;
    const { data, error } = await supabase.rpc("submit_exhibition_work_batch_v2", { p_event_id: event.id, p_work_ids: readyIds });
    if (error) return failure(error);
    await renderExhibitionApplicationV2(event, context);
    message(`${data.submittedWorkIds?.length || 0}作品を正式提出しました。`);
  };
  await renderExhibitionCaptionsV2(event, context, entry, activeWorks);
}

async function renderExhibitionCaptionsV2(event, context, entry, works) {
  const eligible = works.filter((work) => work.workflow_state === "accepted");
  if (!eligible.length) return;
  const workIds = eligible.map((work) => work.id),
    [{ data: captions, error }, { data: reviews, error: reviewError }, { data: cases, error: caseError }] = await Promise.all([
      supabase.from("exhibition_caption_working_data").select("*,accepted_snapshot:exhibition_caption_submission_snapshots!exhibition_caption_current_accepted_fk(work_submission_snapshot_id)").in("work_id", workIds),
      supabase.from("exhibition_caption_reviews").select("*").in("work_id", workIds).order("reviewed_at", { ascending: false }),
      supabase.from("exhibition_caption_workflow_cases").select("*").in("work_id", workIds).order("requested_at", { ascending: false }),
    ]);
  if (error) throw error;
  if (reviewError) throw reviewError;
  if (caseError) throw caseError;
  document.querySelector("#view").insertAdjacentHTML("beforeend", '<section id="v2CaptionManager" class="panel"><div class="entry-heading"><div><span class="tag">CAPTION INFORMATION</span><h2>キャプション情報</h2></div></div><p class="muted">作品確認とは別の工程です。正式提出後の変更は再提出・再確認になります。</p><div id="v2CaptionList" class="stack"></div></section>');
  const list = document.querySelector("#v2CaptionList");
  eligible.forEach((work) => {
    const caption = (captions || []).find((item) => item.work_id === work.id) || {},
      openCase = (cases || []).find((item) => item.work_id === work.id && ["pending", "open", "permitted"].includes(item.state)),
      latestReview = (reviews || []).find((item) => item.work_id === work.id),
      editable = !caption.state || ["draft", "rejected", "reedit_editing"].includes(caption.state),
      stale = Boolean(caption.current_accepted_snapshot_id) && caption.accepted_snapshot?.work_submission_snapshot_id !== work.current_accepted_snapshot_id,
      state = caption.state || "draft";
    list.insertAdjacentHTML("beforeend", `<article class="work-editor v2-caption-card" data-work-id="${work.id}" data-case-id="${openCase?.id || ""}"><div class="work-editor-head"><div><span class="tag">${esc(work.title || `WORK ${work.sort_order}`)}</span><h3>${esc(stale ? "現在の作品内容に対する再確認が必要" : {draft:"下書き",submitted:"確認待ち",accepted:"確認済み",rejected:"要修正",reedit_pending:"再編集申請中",reedit_editing:"再編集中"}[state] || state)}</h3></div></div>${stale ? '<div class="notice error">以前のCaptionは履歴として保持されていますが、現在確認済みのWork Snapshotには対応していません。内容を確認して再提出してください。</div>' : ""}${latestReview?.result === "rejected" ? `<div class="notice error"><strong>要修正：</strong>${esc((latestReview.problem_fields || []).join("・"))}<br>${esc(latestReview.reason)}</div>` : ""}${openCase?.individual_deadline ? `<p class="notice">個別期限：${fmt(openCase.individual_deadline)}</p>` : ""}<div class="form-grid"><label>表示名<input name="display_name" maxlength="100" value="${esc(caption.display_name || entry.display_name_value || context.member.name || "")}" ${editable ? "" : "disabled"}></label><label>英語作品名の作成<select name="english_title_mode" ${editable ? "" : "disabled"}><option value="self" ${caption.english_title_mode === "self" ? "selected" : ""}>自分で入力する</option><option value="organizer" ${caption.english_title_mode !== "self" ? "selected" : ""}>主催者へ任せる</option></select></label><label class="full">英語作品名<input name="member_english_title" maxlength="500" value="${esc(caption.member_english_title || "")}" ${editable ? "" : "disabled"}></label><label>媒体<select name="medium" ${editable ? "" : "disabled"}>${[["","選択"],["digital","デジタル"],["film","フィルム"],["instant","インスタント"],["non_photographic","写真以外"],["other","その他"]].map(([v,l]) => `<option value="${v}" ${caption.medium === v ? "selected" : ""}>${l}</option>`).join("")}</select></label><label>媒体・機材補足<input name="medium_details" maxlength="500" value="${esc(caption.medium_details || "")}" ${editable ? "" : "disabled"}></label><label>Camera<input name="camera" maxlength="200" value="${esc(caption.camera || "")}" ${editable ? "" : "disabled"}></label><label>Lens<input name="lens" maxlength="500" value="${esc(caption.lens || "")}" ${editable ? "" : "disabled"}></label><label>Film<input name="film" maxlength="500" value="${esc(caption.film || "")}" ${editable ? "" : "disabled"}></label><label>Descriptionの扱い<select name="description_choice" ${editable ? "" : "disabled"}><option value="undecided" ${!caption.description_choice || caption.description_choice === "undecided" ? "selected" : ""}>未決定</option><option value="provided" ${caption.description_choice === "provided" ? "selected" : ""}>掲載する</option><option value="unnecessary" ${caption.description_choice === "unnecessary" ? "selected" : ""}>不要</option></select></label><label class="full">Description（日本語）<textarea name="description_ja" maxlength="3000" ${editable ? "" : "disabled"}>${esc(caption.description_ja || "")}</textarea></label><label class="full">Description（英語・任意）<textarea name="description_en" maxlength="3000" ${editable ? "" : "disabled"}>${esc(caption.description_en || "")}</textarea></label><label>Instagram QR<select name="instagram_qr_choice" ${editable ? "" : "disabled"}><option value="none" ${!caption.instagram_qr_choice || caption.instagram_qr_choice === "none" ? "selected" : ""}>不要</option><option value="request" ${caption.instagram_qr_choice === "request" ? "selected" : ""}>作成を希望</option><option value="provided" ${caption.instagram_qr_choice === "provided" ? "selected" : ""}>画像・情報を提供</option></select></label><label>Instagram情報<input name="instagram_qr_info" maxlength="1000" value="${esc(caption.instagram_qr_info || "")}" ${editable ? "" : "disabled"}></label></div><div class="actions">${stale ? '<button class="start-stale-caption">現在の作品向けに確認・再提出する</button>' : ""}${editable ? '<button class="save-caption secondary">下書き保存</button><button class="submit-caption">キャプションを正式提出</button>' : ""}${state === "accepted" && !stale ? '<button class="request-caption-reedit secondary">再編集を申請</button>' : ""}${["reedit_pending","reedit_editing"].includes(state) ? '<button class="cancel-caption-reedit secondary">再編集を取り消す</button>' : ""}</div></article>`);
  });
  const payload = (card, work) => ({ p_work_id: work.id, p_display_name: card.querySelector('[name="display_name"]').value, p_english_title_mode: card.querySelector('[name="english_title_mode"]').value, p_member_english_title: card.querySelector('[name="member_english_title"]').value, p_medium: card.querySelector('[name="medium"]').value, p_medium_details: card.querySelector('[name="medium_details"]').value, p_camera: card.querySelector('[name="camera"]').value, p_lens: card.querySelector('[name="lens"]').value, p_film: card.querySelector('[name="film"]').value, p_description_choice: card.querySelector('[name="description_choice"]').value, p_description_ja: card.querySelector('[name="description_ja"]').value, p_description_en: card.querySelector('[name="description_en"]').value, p_instagram_qr_choice: card.querySelector('[name="instagram_qr_choice"]').value, p_instagram_qr_info: card.querySelector('[name="instagram_qr_info"]').value, p_instagram_qr_path: work.instagram_qr_path || null });
  list.querySelectorAll(".v2-caption-card").forEach((card) => {
    const work = eligible.find((item) => item.id === card.dataset.workId);
    card.querySelector(".save-caption")?.addEventListener("click", async () => { const { error } = await supabase.rpc("save_exhibition_caption_draft_v2", payload(card, work)); if (error) return failure(error); await renderExhibitionApplicationV2(event, context); message("キャプション下書きを保存しました。"); });
    card.querySelector(".submit-caption")?.addEventListener("click", async () => { const saved = await supabase.rpc("save_exhibition_caption_draft_v2", payload(card, work)); if (saved.error) return failure(saved.error); if (!confirm("この内容を正式提出しますか？提出内容はSnapshotとして保存されます。")) return; const { error } = await supabase.rpc("submit_exhibition_caption_v2", { p_work_id: work.id }); if (error) return failure(error); await renderExhibitionApplicationV2(event, context); message("キャプションを正式提出しました。"); });
    card.querySelector(".request-caption-reedit")?.addEventListener("click", async () => { const reason = prompt("再編集理由（必須）"); if (!reason) return; const { error } = await supabase.rpc("request_exhibition_caption_reedit_v2", { p_work_id: work.id, p_reason: reason }); if (error) return failure(error); renderExhibitionApplicationV2(event, context); });
    card.querySelector(".start-stale-caption")?.addEventListener("click", async () => { if (!confirm("以前のCaption履歴を残したまま、現在の作品内容向けの再提出を開始しますか？")) return; const { error } = await supabase.rpc("start_stale_exhibition_caption_resubmission_v2", { p_work_id: work.id }); if (error) return failure(error); renderExhibitionApplicationV2(event, context); });
    card.querySelector(".cancel-caption-reedit")?.addEventListener("click", async () => { const { error } = await supabase.rpc("cancel_exhibition_caption_reedit_v2", { p_case_id: card.dataset.caseId, p_reason: "" }); if (error) return failure(error); renderExhibitionApplicationV2(event, context); });
  });
}

async function renderExhibitionEvent(event, context) {
  if (Number(event.exhibition_workflow_version) === 2)
    return renderExhibitionApplicationV2(event, context);
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
          work.status === "rejected" ||
          !work.orientation ||
          !work.print_size ||
          work.publication_consent === null,
      ),
      allAccepted =
        works.length > 0 &&
        works.every(
          (work) =>
            work.status === "accepted" &&
            work.orientation &&
            work.print_size &&
            work.publication_consent !== null,
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
    const registrationClosed =
      !event.registration_deadline ||
      new Date() > new Date(event.registration_deadline);
    view.innerHTML = `<section class="panel"><span class="tag">EXHIBITION ENTRY</span><h2>${esc(event.exhibition_title || event.title)}</h2><dl><dt>日時</dt><dd>${fmt(event.starts_at)}${event.ends_at ? ` 〜 ${fmt(event.ends_at)}` : ""}</dd><dt>申込締切</dt><dd>${event.registration_deadline ? fmt(event.registration_deadline) : "未設定"}</dd><dt>場所</dt><dd>${esc(event.place)}</dd><dt>連絡先</dt><dd>${esc(event.contact)}</dd><dt>出展上限</dt><dd>1人 ${event.max_works}作品</dd></dl><p class="copy">${esc(event.details)}</p></section><section class="panel exhibition-entry-panel"><div class="entry-heading"><div><span class="tag">YOUR ENTRY</span><h2>出展作品を登録</h2></div><span class="status">${entryState}</span></div>${registrationClosed ? '<div class="notice error">申込受付は終了しました。登録済みの内容は閲覧できます。</div>' : ""}${hasRejected ? '<div class="notice error">要修正になっている作品があります。該当作品を修正し、変更内容を再提出してください。</div>' : ""}<p class="muted">原画像は非公開で保存され、本人と管理者だけが閲覧できます。JPEG・PNG・TIFF・HEIC・HEIF、1作品50MBまでです。</p><form id="exhibitionEntryForm" class="stack"><div id="workEditors" class="stack"></div><div class="actions work-actions"><button type="button" id="addWork" class="secondary">作品を追加</button></div><label>出展全体に関する備考<textarea name="entry_note" rows="3">${esc(entry?.note || "")}</textarea></label><div class="notice">「下書き保存」では提出は完了しません。「出展申込を確定」を押すと、登録した全作品が提出済みになります。</div><div class="actions"><button type="button" id="saveEntryDraft" class="secondary">下書き保存</button><button type="submit" id="submitEntry">${entry?.status === "submitted" ? "申込済み" : "出展申込を確定"}</button></div></form></section>`;
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
          work?.status === "accepted" &&
          work?.orientation &&
          work?.print_size &&
          work?.publication_consent !== null,
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
      editor.querySelector(".caption-fields").insertAdjacentHTML(
        "beforebegin",
        `<fieldset class="full publication-fields"><legend>写真展サイトへの掲載（必須）</legend><p class="muted">同意した作品は、透かし入りの縮小画像として写真展サイトに掲載され、開催終了後も履歴ページに残る場合があります。不同意の場合は作品画像の代わりに「NO IMAGE」のロゴ画像を表示します。</p><label><input type="radio" name="publication_consent" value="consent" ${work?.publication_consent === true ? "checked" : ""} ${locked ? "disabled" : ""}>上記を確認し、掲載に同意する</label><label><input type="radio" name="publication_consent" value="decline" ${work?.publication_consent === false ? "checked" : ""} ${locked ? "disabled" : ""}>掲載に同意しない</label></fieldset>`,
      );
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
    if (registrationClosed)
      form.querySelectorAll("input, select, textarea, button").forEach((control) => {
        control.disabled = true;
      });
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
              publicationConsent:
                editor.querySelector("[name=publication_consent]:checked")
                  ?.value || "",
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
        if (registrationClosed) {
          draftButton.disabled = true;
          submitButton.disabled = true;
          return;
        }
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
        if (!(await ensurePortalAvailable(supabase))) return;
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
            publicationConsent = editor.querySelector(
              "[name=publication_consent]:checked",
            )?.value,
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
          if (submitted && !publicationConsent)
            throw new Error(
              `作品${index + 1}の写真展サイトへの掲載可否を選択してください。`,
            );
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
            publication_consent:
              editor.querySelector("[name=publication_consent]:checked")
                ?.value === "consent"
                ? true
                : editor.querySelector("[name=publication_consent]:checked")
                      ?.value === "decline"
                  ? false
                  : null,
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
    console.debug("[response-debug][event]", {
      authEmail: session?.user?.email,
      contextMemberId: context.member?.id,
      eventId: event.id,
      eventTitle: event.title,
      responseCount: event.event_responses?.length ?? 0,
      responses:
      event.event_responses?.map((response, index) => ({
        index,
        responseId: response.id,
        memberId: response.member_id,
        attendance: response.attendance,
        submittedAt: response.submitted_at,
      })) ?? [],
    });
    if (event.genre === "exhibition")
      return renderExhibitionEvent(event, context);
    hideMessage();
    const { data: myState, error: stateError } = await supabase.rpc(
      "get_my_event_state",
      { p_event_id: id },
    );
    if (stateError) throw stateError;
    const existing = myState?.response,
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
    const { data: availability, error: availabilityError } = await supabase.rpc(
      "get_event_availability",
      { p_event_id: id },
    );
    if (availabilityError) throw availabilityError;
    const gradeList = availability.eligibleGrades || [],
      capacityText = availability.participantLimit == null
        ? "制限なし"
        : `${availability.participantCount} / ${availability.participantLimit}名（残り${availability.remaining}名）`;
    view.innerHTML = `<section class="panel"><span class="tag">${eventLabel(event)}</span><h2>${esc(event.title)}</h2><dl><dt>日時</dt><dd>${fmt(event.starts_at)}${event.ends_at ? ` 〜 ${fmt(event.ends_at)}` : ""}</dd><dt>申込締切</dt><dd>${event.registration_deadline ? fmt(event.registration_deadline) : "未設定"}</dd><dt>場所</dt><dd>${esc(event.place)}</dd><dt>連絡先</dt><dd>${esc(event.contact)}</dd><dt>参加定員</dt><dd>${esc(capacityText)}</dd><dt>対象学年</dt><dd>${gradeList.length ? esc(gradeList.join("・")) : "全学年"}</dd>${event.fee_enabled ? `<dt>費用</dt><dd>${event.fee.toLocaleString()}円</dd>` : ""}${event.payment_deadline_enabled && event.payment_deadline ? `<dt>支払期限</dt><dd>${fmt(event.payment_deadline)}</dd>` : ""}</dl><p class="copy">${esc(event.details)}</p></section><section id="response" class="panel"></section>`;
    const { data: publishedGroups, error: groupsError } = await supabase.rpc("get_published_event_groups", { p_event_id: id });
    if (groupsError) throw groupsError;
    if (publishedGroups?.groups) view.insertAdjacentHTML("beforeend", `<section class="panel"><span class="tag">GROUPS</span><h2>班分け</h2><p class="muted">最終公開：${fmt(publishedGroups.publishedAt)}</p><div class="group-grid">${publishedGroups.groups.map((group) => `<article class="group-card"><h3>${esc(group.name)}</h3><ul>${group.members.map((m) => `<li class="${m.memberId === member.id ? "my-group-member" : ""}">${m.memberId === group.leaderId ? "班長：" : ""}${esc(m.name)}（${esc([m.grade, m.faculty, m.department].filter(Boolean).join("・"))}）</li>`).join("")}</ul></article>`).join("")}</div></section>`);
    const root = document.querySelector("#response");
    const joinWaitlist = async () => {
      if (!confirm("キャンセル待ちに登録しますか？繰上げは保証されません。")) return;
      const needsAllergy = event.genre === "camp" || event.subtype === "dining",
        allergies = needsAllergy ? prompt("アレルギー情報を入力してください（ない場合は「なし」）", "なし") : "";
      if (needsAllergy && allergies === null) return;
      if (event.genre === "camp" && !confirm("繰上げ後の参加取消条件と支払期限を確認し、同意しますか？")) return;
      const { error } = await supabase.rpc("join_event_waitlist", {
        p_event_id: id,
        p_registration_data: { lineName: member.line_name || "", allergies, agreement: event.genre === "camp" },
      });
      if (error) return failure(error);
      renderEvent(id);
    };
    if (myState?.offer) {
      root.innerHTML = `<span class="tag">ACTION REQUIRED</span><h2>空席を仮確保しています</h2><p>回答期限：${fmt(myState.offer.response_deadline)}</p><p>期限までに参加可否を回答してください。</p><div class="actions"><button id="declineOffer" class="danger">辞退する</button><button id="acceptOffer">参加する</button></div>`;
      const respond = async (accept) => {
        if (!confirm(accept ? "繰上げ参加を確定しますか？" : "繰上げを辞退しますか？")) return;
        const { error } = await supabase.rpc("respond_waitlist_offer", { p_offer_id: myState.offer.id, p_accept: accept });
        if (error) return failure(error);
        renderEvent(id);
      };
      root.querySelector("#acceptOffer").onclick = () => respond(true);
      root.querySelector("#declineOffer").onclick = () => respond(false);
      return;
    }
    if (myState?.waitlist?.status === "waiting") {
      root.innerHTML = `<span class="tag">WAITLIST</span><h2>キャンセル待ち登録済み</h2><p>登録順に案内します。繰上げは保証されません。案内は当面、幹部から個別に行います。</p><div class="actions"><button id="withdrawWaitlist" class="danger">キャンセル待ちを取り消す</button></div>`;
      root.querySelector("#withdrawWaitlist").onclick = async () => {
        if (!confirm("キャンセル待ちを取り消しますか？再登録時は最後尾になります。")) return;
        const { error } = await supabase.rpc("withdraw_event_waitlist", { p_event_id: id });
        if (error) return failure(error);
        renderEvent(id);
      };
      return;
    }
    if (existing) {
      const canCancel = !existing.cancelled_at && existing.attendance === "参加" && event.self_cancellation_enabled && event.registration_deadline && new Date() <= new Date(event.registration_deadline);
      const canRejoin = existing.cancelled_at && existing.payment_updated_by !== "system:payment-deadline" && event.waitlist_registration_deadline && new Date() <= new Date(event.waitlist_registration_deadline);
      root.innerHTML = `<span class="tag">YOUR RESPONSE</span><h2>回答済みです</h2><dl><dt>回答</dt><dd class="status">${existing.cancelled_at ? "キャンセル済み" : esc(existing.attendance)}</dd><dt>回答日時</dt><dd>${fmt(existing.submitted_at)}</dd>${existing.attendance === "参加" && existing.camera ? "<dt>貸出カメラ</dt><dd>希望する</dd>" : ""}${existing.attendance === "参加" && existing.disposable_camera ? "<dt>写るんです</dt><dd>希望する</dd>" : ""}${existing.allergies ? `<dt>アレルギー</dt><dd>${esc([existing.allergies, existing.other_allergy].filter(Boolean).join("・"))}</dd>` : ""}${existing.payment_status !== "not_required" ? `<dt>支払い状況</dt><dd>${esc(paymentLabel(existing.payment_status))}</dd>` : ""}${existing.individual_payment_deadline ? `<dt>個別支払期限</dt><dd>${fmt(existing.individual_payment_deadline)}</dd>` : ""}${existing.note ? `<dt>備考</dt><dd>${esc(existing.note)}</dd>` : ""}</dl>${canCancel ? '<div class="notice">キャンセルした枠は直ちにキャンセル待ちの方へ割り当てられる場合があり、再参加は保証されません。</div><div class="actions"><button id="cancelParticipation" class="danger">参加をキャンセル</button></div>' : ""}${canRejoin ? '<div class="actions"><button id="rejoinParticipation">再参加を希望する</button></div>' : ""}${existing.cancelled_at && existing.payment_updated_by === "system:payment-deadline" ? '<p class="notice error">支払期限超過によるキャンセル後の再参加は、幹部へご連絡ください。</p>' : ""}`;
      if (canCancel) root.querySelector("#cancelParticipation").onclick = async () => {
        if (!confirm("参加をキャンセルしますか？この操作後に同じ枠へ戻れる保証はありません。")) return;
        const { error } = await supabase.rpc("cancel_my_event_participation", { p_event_id: id });
        if (error) return failure(error);
        renderEvent(id);
      };
      if (canRejoin) root.querySelector("#rejoinParticipation").onclick = async () => {
        if (!confirm("再参加を希望しますか？満員の場合はキャンセル待ちの最後尾に登録されます。")) return;
        const { error } = await supabase.rpc("request_event_rejoin", { p_event_id: id });
        if (error) return failure(error);
        renderEvent(id);
      };
      return;
    }
    if (!availability.registrationOpen && !availability.canJoinWaitlist) {
      root.innerHTML = '<span class="tag">CLOSED</span><h2>申込受付は終了しました</h2><p>締切後の回答は受け付けていません。必要な場合は企画幹部へお問い合わせください。</p>';
      return;
    }
    if (!availability.registrationOpen && availability.canJoinWaitlist) {
      root.innerHTML = '<span class="tag">WAITLIST</span><h2>通常申込は終了しました</h2><p>キャンセル待ちは引き続き受け付けています。繰上げは保証されません。</p><div class="actions"><button id="joinWaitlist">キャンセル待ちに登録</button></div>';
      root.querySelector("#joinWaitlist").onclick = joinWaitlist;
      return;
    }
    const allergyFields =
      event.genre === "camp" || event.subtype === "dining"
        ? '<fieldset><legend>アレルギー（参加者必須）</legend><label>主要項目<select name="allergies" required><option value="">選択してください</option><option>なし</option><option>卵</option><option>乳</option><option>小麦</option><option>えび</option><option>かに</option><option>そば</option><option>落花生</option><option>その他</option></select></label><label>その他・詳細<input name="other_allergy"></label></fieldset>'
        : "";
    const restrictionMessage = !availability.gradeEligible
      ? `この予定は${member.grade}を参加対象としていません。不参加の回答は送信できます。`
      : availability.participantLimit != null && availability.remaining === 0
        ? "この予定は定員に達しています。不参加の回答は送信できます。"
        : "";
    const canWaitlist = availability.canJoinWaitlist;
    root.innerHTML = `<h2>出欠を回答</h2>${restrictionMessage ? `<div class="notice error">${esc(restrictionMessage)}</div>` : ""}${canWaitlist ? '<div class="actions"><button id="joinWaitlist" type="button">キャンセル待ちに登録</button></div>' : ""}<form id="responseForm" class="stack"><section class="member-summary"><strong>${esc(member.name)}さん</strong><span>${esc([member.grade, member.faculty || member.graduate_school, member.department || member.major].filter(Boolean).join("・"))}</span></section><fieldset><legend>出欠</legend><label><input type="radio" name="attendance" value="参加" required ${availability.canParticipate ? "" : "disabled"}>参加</label><label><input type="radio" name="attendance" value="不参加" required>不参加</label></fieldset><label>LINEの名前<input name="line_name" value="${esc(member?.line_name || "")}" required></label><div id="joinFields" class="stack hidden">${allergyFields}${event.camera_enabled ? `<label><input type="checkbox" name="camera" ${cameraRemaining === 0 ? "disabled" : ""}>貸出カメラを希望（残り ${cameraRemaining}台）</label>` : ""}${event.disposable_enabled ? '<label><input type="checkbox" name="disposable_camera">写るんですを希望</label>' : ""}${event.genre === "camp" ? '<div class="notice agreement"><p>本申込みの送信後は、疾病その他やむを得ない事情を除き、参加者都合による取消しは原則として認められません。また、支払期限までに費用全額の入金が確認できない場合、申込みは通知なく自動的に取り消されます。</p><label><input type="checkbox" name="agreement" required>上記条件を確認し、同意します</label></div>' : ""}</div><label>備考<textarea name="note" rows="4"></textarea></label><div class="actions"><button>この内容で回答</button></div></form>`;
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
      if (!(await ensurePortalAvailable(supabase))) return;
      const values = Object.fromEntries(new FormData(form)),
        button = form.querySelector("button");
      button.disabled = true;
      const attendance = values.attendance;
      const { error: insertError } = await supabase.rpc("submit_event_response", {
        p_event_id: id, p_attendance: attendance, p_line_name: values.line_name,
        p_camera: attendance === "参加" && values.camera === "on",
        p_disposable_camera: attendance === "参加" && values.disposable_camera === "on",
        p_allergies: attendance === "参加" ? values.allergies || "" : "",
        p_other_allergy: attendance === "参加" ? values.other_allergy || "" : "",
        p_note: values.note || "", p_agreement: attendance === "参加" && values.agreement === "on",
      });
      if (insertError) {
        button.disabled = false;
        failure(insertError);
        return;
      }
      renderEvent(id);
    };
    root.querySelector("#joinWaitlist")?.addEventListener("click", joinWaitlist);
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

async function renderAdmin(context, maintenance = null) {
  context ??= await getContext();
  layout(
    "予定管理",
    '<a class="button secondary" href="#/">ポータルトップに戻る</a><button id="logout" class="secondary">ログアウト</button>',
  );
  document.querySelector("#logout").onclick = () => supabase.auth.signOut();
  try {
    if (!context.admin) throw new Error("管理者権限がありません。");
    maintenance ??= await maintenanceState(supabase);
    if (maintenance.isMaintenanceAdmin)
      document
        .querySelector(".header-actions")
        .insertAdjacentHTML(
          "afterbegin",
          '<a class="button secondary" href="#/maintenance-admin">メンテナンス管理</a>',
        );
    const { data: events, error } = await supabase
      .from("events")
      .select("*")
      .is("deleted_at", null)
      .order("updated_at", { ascending: false });
    if (error) throw error;
    hideMessage();
    const view = document.querySelector("#view");
    view.innerHTML = `<div class="admin-nav"><button id="showEvents" class="secondary">予定管理</button><button id="showActionCenter" class="secondary">写真展 Action Center</button><button id="showReceipt" class="secondary">領収証発行</button></div><section id="eventAdmin"><div class="event-genre-tabs" role="tablist" aria-label="予定ジャンル"><button type="button" data-genre="meeting">全体会</button><button type="button" data-genre="camp">合宿</button><button type="button" data-genre="exhibition">写真展</button></div><div class="event-list-heading"><div><p class="eyebrow">EVENT MANAGEMENT</p><h2 id="eventGenreTitle"></h2></div><button id="newEvent">新規予定を作成</button></div><section class="panel"><div id="adminList"></div><p id="emptyGenre" class="muted hidden">このジャンルの予定はまだありません。</p></section><section id="editor" class="panel hidden"></section><section id="participantAdmin" class="panel hidden"></section></section><section id="actionCenterAdmin" class="panel hidden"></section><section id="receiptAdmin" class="panel hidden"><span class="tag">MEMBERSHIP RECEIPT</span><h2>部費領収証を発行</h2><p class="muted">既存部員は大学メールから情報を呼び出せます。登録と同時に年度在籍が有効になります。</p><form id="receiptForm" class="form-grid"><label class="full">大学メールアドレス<div class="inline-field"><input type="email" name="email" required autocomplete="off"><button type="button" id="findMember" class="secondary">名簿から検索</button></div></label><label>氏名<input name="name" required></label><label>学年<input name="grade" required placeholder="B1 / M1"></label><label>学部（学部生）<input name="faculty"></label><label>学科（学部生）<input name="department"></label><label>研究科（院生）<input name="graduate_school"></label><label>専攻（院生）<input name="major"></label><label>性別<select name="gender"><option value=""></option><option>男性</option><option>女性</option><option>その他</option><option>回答しない</option></select></label><label>LINEの名前<input name="line_name" required></label><label>前年度在籍状況<select name="previous_member"><option value=""></option><option>在籍</option><option>未在籍</option><option>不明</option></select></label><label>年度<input type="number" name="fiscal_year" min="2000" max="2200" required value="${fiscalYear()}"></label><label>金額<input type="number" name="amount" min="0" required value="6000"></label><div class="full notice">但書は「<strong><span id="receiptYear">${fiscalYear()}</span>年度部費として</strong>」で記録されます。</div><div class="actions full"><button id="issueReceipt">年度在籍登録・領収証発行</button></div></form><section id="receiptResult" class="receipt-result hidden"></section></section>`;
    document
      .querySelector(".admin-nav")
      .insertAdjacentHTML(
        "beforeend",
        '<button id="showArchiveImages" class="secondary">過去写真展画像</button>',
      );
    view.insertAdjacentHTML(
      "beforeend",
      '<section id="archiveImageAdmin" class="panel hidden"></section>',
    );
    const list = document.querySelector("#adminList");
    events.forEach((event) =>
      list.insertAdjacentHTML(
        "beforeend",
        `<article class="admin-row" data-id="${event.id}"><div><span class="tag">${event.status === "draft" ? "下書き" : event.published ? "募集公開中" : "募集非公開"}</span>${event.genre === "exhibition" ? `<span class="tag site-status-tag">${exhibitionSiteStatusLabel(event.site_status)}</span>` : ""}<h3>${esc(event.title)}</h3><p>${fmt(event.starts_at)}</p></div><div class="actions"><button class="secondary participants">${event.genre === "exhibition" ? "出展者・作品管理" : "参加者・支払い"}</button>${event.genre === "exhibition" ? `<button class="secondary simulator">展示シミュレータ</button><button class="secondary exhibition-site">${Number(event.exhibition_workflow_version) === 2 ? "Publication管理" : event.site_status === "published" ? "写真展サイトを終了" : "写真展サイトを公開"}</button>` : ""}<button class="secondary edit">編集</button><button class="secondary publish">${event.published ? "募集を非公開にする" : "募集を公開する"}</button><button class="danger delete">削除</button></div></article>`,
      ),
    );
    list.querySelectorAll(".admin-row").forEach((row) => {
      const event = events.find((e) => e.id === row.dataset.id);
      row.dataset.genre = event.genre;
      row.querySelector(".participants").onclick = () =>
        renderParticipants(event);
      row.querySelector(".simulator")?.addEventListener("click", () =>
        renderExhibitionSimulator(event),
      );
      row.querySelector(".exhibition-site")?.addEventListener(
        "click",
        async () => {
          if (Number(event.exhibition_workflow_version) === 2) {
            await renderExhibitionParticipants(event);
            document.querySelector("#showV2Export")?.click();
            return;
          }
          const ending = event.site_status === "published",
            prompt = ending
              ? `「${event.title}」の一般向け写真展サイトを終了しますか？\n終了後も写真展情報は履歴として残りますが、作品一覧は一般公開されません。`
              : `「${event.title}」の一般向け写真展サイトを公開しますか？\n掲載同意済みの作品画像と、掲載不同意作品の情報が一般公開されます。`;
          if (!confirm(prompt)) return;
          const button = row.querySelector(".exhibition-site");
          button.disabled = true;
          const { error } = await supabase.rpc(
            ending
              ? "admin_end_exhibition_site"
              : "admin_publish_exhibition_site",
            { p_event_id: event.id },
          );
          if (error) {
            failure(error);
            button.disabled = false;
            return;
          }
          await renderAdmin();
          message(
            ending
              ? "写真展サイトの公開を終了しました。"
              : "写真展サイトを公開しました。",
          );
        },
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
    const genreLabels = {
        meeting: "全体会",
        camp: "合宿",
        exhibition: "写真展",
      },
      genreButtons = document.querySelectorAll(".event-genre-tabs button"),
      applyGenreTab = () => {
        document.querySelector("#eventGenreTitle").textContent =
          `${genreLabels[adminGenreTab]}の予定`;
        genreButtons.forEach((button) => {
          const active = button.dataset.genre === adminGenreTab;
          button.classList.toggle("is-active", active);
          button.setAttribute("aria-selected", String(active));
        });
        let visibleCount = 0;
        list.querySelectorAll(".admin-row").forEach((row) => {
          const visible = row.dataset.genre === adminGenreTab;
          row.classList.toggle("hidden", !visible);
          if (visible) visibleCount += 1;
        });
        document
          .querySelector("#emptyGenre")
          .classList.toggle("hidden", visibleCount > 0);
      };
    genreButtons.forEach((button) => {
      button.onclick = () => {
        adminGenreTab = button.dataset.genre;
        document.querySelector("#editor").classList.add("hidden");
        document.querySelector("#participantAdmin").classList.add("hidden");
        applyGenreTab();
      };
    });
    applyGenreTab();
    document.querySelector("#newEvent").onclick = () =>
      renderEditor(null, adminGenreTab);
    const eventAdmin = document.querySelector("#eventAdmin"),
      actionCenterAdmin = document.querySelector("#actionCenterAdmin"),
      receiptAdmin = document.querySelector("#receiptAdmin"),
      archiveImageAdmin = document.querySelector("#archiveImageAdmin"),
      hideAdminSections = () => {
        eventAdmin.classList.add("hidden");
        actionCenterAdmin.classList.add("hidden");
        receiptAdmin.classList.add("hidden");
        archiveImageAdmin.classList.add("hidden");
      };
    document.querySelector("#showEvents").onclick = () => {
      hideAdminSections();
      eventAdmin.classList.remove("hidden");
    };
    document.querySelector("#showReceipt").onclick = () => {
      hideAdminSections();
      receiptAdmin.classList.remove("hidden");
    };
    document.querySelector("#showActionCenter").onclick = () => {
      hideAdminSections();
      actionCenterAdmin.classList.remove("hidden");
      renderExhibitionActionCenterV2(events, actionCenterAdmin);
    };
    document.querySelector("#showArchiveImages").onclick = () => {
      hideAdminSections();
      archiveImageAdmin.classList.remove("hidden");
      renderArchiveImageImport();
    };
    setupReceiptForm();
  } catch (error) {
    failure(error);
  }
}

async function renderExhibitionActionCenterV2(events, root) {
  root.innerHTML = '<p class="muted">Action Centerを読み込んでいます…</p>';
  const [{ data: workflowActions, error }, { data: layoutActions, error: layoutError }, { data: exportActions, error: exportError }, { data: publicationActions, error: publicationError }, { data: actualActions, error: actualError }, { data: archiveActions, error: archiveError }] = await Promise.all([
    supabase.rpc("admin_get_exhibition_action_center_v2", { p_event_id: null }),
    supabase.rpc("admin_get_exhibition_layout_actions_v2", { p_event_id: null }),
    supabase.rpc("admin_get_exhibition_export_actions_v2", { p_event_id: null }),
    supabase.rpc("admin_get_exhibition_publication_actions_v2", { p_event_id: null }),
    supabase.rpc("admin_get_exhibition_actual_actions_v2", { p_event_id: null }),
    supabase.rpc("admin_get_exhibition_archive_actions_v2", { p_event_id: null }),
  ]);
  if (error) return failure(error);
  if (layoutError) return failure(layoutError);
  if (exportError) return failure(exportError);
  if (publicationError) return failure(publicationError);
  if (actualError) return failure(actualError);
  if (archiveError) return failure(archiveError);
  const actions = [...(workflowActions || []), ...(layoutActions || []), ...(exportActions || []), ...(publicationActions || []), ...(actualActions || []), ...(archiveActions || [])].sort((a, b) => Number(a.priority) - Number(b.priority));
  const groups = [
    ["review_required", "確認が必要"],
    ["decision_required", "管理者の判断が必要"],
    ["deadline_attention", "期限・例外対応"],
    ["organizer_task", "主催者作業"],
    ["member_action_pending", "部員の対応待ち"],
  ];
  root.innerHTML = `<div class="entry-heading"><div><span class="tag">WORKFLOW V2</span><h2>写真展 Action Center</h2><p class="muted">管理者が現在処理・確認すべき項目をDB判定から表示します。</p></div><button id="processAllV2Deadlines" class="secondary">期限処理を実行</button></div><div id="actionCenterGroups"></div>`;
  const host = root.querySelector("#actionCenterGroups");
  groups.forEach(([key, title]) => {
    const items = (actions || []).filter((item) => item.category === key);
    host.insertAdjacentHTML("beforeend", `<section class="action-center-group"><div class="section-head"><h3>${title}</h3><span class="status">${items.length}件</span></div><div class="stack">${items.length ? items.map((item) => `<article class="admin-row"><div><span class="tag">${esc(item.action_type)}</span><h4>${esc(item.event_title)}｜${esc(item.member_name || "")}</h4><p>${esc(item.context?.label || item.reason || "対応状況を確認してください")}</p>${item.relevant_deadline ? `<p class="muted">期限：${fmt(item.relevant_deadline)}</p>` : ""}</div><button class="open-action-detail secondary" data-event-id="${item.event_id}" data-action-type="${esc(item.action_type)}">詳細を開く</button></article>`).join("") : '<p class="muted">該当項目はありません。</p>'}</div></section>`);
  });
  root.querySelectorAll(".open-action-detail").forEach((button) => button.onclick = () => {
    const event = events.find((item) => item.id === button.dataset.eventId);
    if (event) {
      root.classList.add("hidden");
      document.querySelector("#eventAdmin").classList.remove("hidden");
      if (button.dataset.actionType.startsWith("layout_"))
        renderExhibitionSimulator(event);
      else if (button.dataset.actionType.startsWith("actual_"))
        renderExhibitionParticipants(event).then(() =>
          document.querySelector("#showV2Actual")?.click(),
        );
      else if (button.dataset.actionType.startsWith("archive_"))
        renderExhibitionParticipants(event).then(() =>
          document.querySelector("#showV2Archive")?.click(),
        );
      else renderExhibitionParticipants(event);
    }
  });
  root.querySelector("#processAllV2Deadlines").onclick = async () => {
    if (!confirm("すべてのWorkflow v2写真展について、期限到達済みのSYSTEM処理を実行しますか？繰り返し実行しても同じ遷移は重複しません。")) return;
    const button = root.querySelector("#processAllV2Deadlines");
    button.disabled = true;
    const { data, error } = await supabase.rpc("admin_process_due_exhibition_workflows_v2", { p_event_id: null });
    if (error) { button.disabled = false; return failure(error); }
    await renderExhibitionActionCenterV2(events, root);
    const eventResults = data?.events || [], work = eventResults.reduce((sum, item) => sum + Number(item.work?.draftWorksWithdrawn || 0) + Number(item.work?.casesExpired || 0) + Number(item.work?.entriesAutoCancelled || 0), 0), caption = eventResults.reduce((sum, item) => sum + Number(item.caption?.casesExpired || 0), 0);
    message(`期限処理を完了しました。対象${eventResults.length}件／Work遷移${work}件／Caption遷移${caption}件`);
  };
}

async function renderArchiveImageImport() {
  const root = document.querySelector("#archiveImageAdmin");
  root.innerHTML = "<p>過去写真展の画像情報を読み込んでいます…</p>";
  const { data: works, error } = await supabase
    .from("archive_works")
    .select(
      "id,legacy_work_uuid,display_no,title,source_file_name,image_path,archive_exhibitions!inner(exhibition_key,title)",
    );
  if (error) return failure(error);
  const grouped = (works || []).reduce((result, work) => {
      const key = work.archive_exhibitions.exhibition_key;
      (result[key] ??= {
        title: work.archive_exhibitions.title,
        works: [],
      }).works.push(work);
      return result;
    }, {}),
    keys = Object.keys(grouped).sort().reverse();
  if (!keys.length) {
    root.innerHTML = '<p class="muted">過去写真展が登録されていません。</p>';
    return;
  }
  root.innerHTML = `<span class="tag">ARCHIVE IMAGE IMPORT</span><h2>過去写真展画像を一括登録</h2><p class="muted">Google DriveからダウンロードしたZIPを展開し、中の画像をすべて選択してください。ファイル名を作品UUIDへ自動照合し、非公開Storageへ保存します。</p><div class="form-grid"><label>写真展<select id="archiveImageExhibition">${keys.map((key) => `<option value="${esc(key)}">${esc(grouped[key].title)}</option>`).join("")}</select></label><label>表示用画像（複数選択）<input id="archiveImageFiles" type="file" accept="image/jpeg,image/png,image/webp,.jpg,.jpeg,.png,.webp" multiple></label></div><div id="archiveImageCheck" class="notice">画像を選択すると照合結果を表示します。</div><div class="actions"><button id="uploadArchiveImages" disabled>照合済み画像をアップロード</button></div>`;
  const exhibitionSelect = root.querySelector("#archiveImageExhibition"),
    fileInput = root.querySelector("#archiveImageFiles"),
    check = root.querySelector("#archiveImageCheck"),
    uploadButton = root.querySelector("#uploadArchiveImages"),
    normalized = (value) => String(value || "").normalize("NFC"),
    extension = (file) => {
      if (file.type === "image/png") return "png";
      if (file.type === "image/webp") return "webp";
      return "jpg";
    };
  let matched = [];
  const inspectFiles = () => {
    const target = grouped[exhibitionSelect.value],
      byName = new Map(
        target.works
          .filter((work) => work.source_file_name)
          .map((work) => [normalized(work.source_file_name), work]),
      ),
      selectedNames = new Set(),
      duplicates = [],
      unmatched = [];
    matched = [];
    [...fileInput.files].forEach((file) => {
      const name = normalized(file.name),
        work = byName.get(name);
      if (selectedNames.has(name)) duplicates.push(file.name);
      selectedNames.add(name);
      if (!work) unmatched.push(file.name);
      else matched.push({ file, work });
    });
    const missing = target.works.filter(
        (work) =>
          work.source_file_name &&
          !selectedNames.has(normalized(work.source_file_name)),
      ),
      invalid = matched.filter(
        ({ file }) =>
          !["image/jpeg", "image/png", "image/webp"].includes(file.type) ||
          file.size > 10485760,
      );
    uploadButton.disabled =
      !matched.length ||
      duplicates.length > 0 ||
      unmatched.length > 0 ||
      missing.length > 0 ||
      invalid.length > 0;
    check.classList.toggle("error", uploadButton.disabled);
    check.innerHTML = `<strong>照合 ${matched.length} / ${target.works.length}点</strong><br>${missing.length ? `不足 ${missing.length}点` : "不足なし"}／${unmatched.length ? `未対応 ${unmatched.length}点` : "未対応なし"}／${duplicates.length ? `重複 ${duplicates.length}点` : "重複なし"}${invalid.length ? `／形式・容量エラー ${invalid.length}点` : ""}`;
  };
  exhibitionSelect.onchange = inspectFiles;
  fileInput.onchange = inspectFiles;
  uploadButton.onclick = async () => {
    if (uploadButton.disabled) return;
    if (
      !confirm(
        `${grouped[exhibitionSelect.value].title}の表示画像${matched.length}点を非公開Storageへ登録しますか？`,
      )
    )
      return;
    uploadButton.disabled = true;
    try {
      for (let index = 0; index < matched.length; index += 1) {
        const { file, work } = matched[index],
          path = `archive/${exhibitionSelect.value}/${work.legacy_work_uuid}/preview.${extension(file)}`;
        check.innerHTML = `<strong>${index + 1} / ${matched.length}点をアップロード中…</strong><br>No.${esc(work.display_no)} ${esc(work.title)}`;
        const { error: uploadError } = await supabase.storage
          .from("exhibition-previews")
          .upload(path, file, { upsert: true, contentType: file.type });
        if (uploadError) throw uploadError;
        const { error: updateError } = await supabase
          .from("archive_works")
          .update({ image_path: path, image_visible: true })
          .eq("id", work.id);
        if (updateError) throw updateError;
      }
      check.classList.remove("error");
      check.innerHTML = `<strong>${matched.length}点の登録が完了しました。</strong><br>部員画面で本人の作品画像を確認できます。`;
      message("過去写真展の表示画像を登録しました。");
    } catch (uploadError) {
      uploadButton.disabled = false;
      failure(uploadError);
      check.classList.add("error");
      check.textContent = `画像登録を中断しました：${uploadError.message || uploadError}`;
    }
  };
}

async function renderParticipants(event) {
  if (event.genre === "exhibition") return renderExhibitionParticipants(event);
  const root = document.querySelector("#participantAdmin");
  document.querySelector("#editor").classList.add("hidden");
  root.classList.remove("hidden");
  root.innerHTML = "<p>参加者情報を読み込んでいます…</p>";
  root.scrollIntoView({ behavior: "smooth" });
  const [{ data: responses, error }, { data: offers, error: offersError }] = await Promise.all([
    supabase.from("event_responses").select("*,members(id,member_no,name,email,grade,gender,faculty,department,graduate_school,major)").eq("event_id", event.id).order("submitted_at"),
    supabase.from("event_waitlist_offers").select("*,members(name,email)").eq("event_id", event.id).eq("status", "pending").order("offered_at"),
  ]);
  if (error) {
    failure(error);
    root.classList.add("hidden");
    return;
  }
  if (offersError) return failure(offersError);
  const joined = responses.filter(
      (response) => response.attendance === "参加" && !response.cancelled_at,
    ).length,
    paid = responses.filter(
      (response) => response.payment_status === "paid",
    ).length,
    unpaid = responses.filter(
      (response) => response.payment_status === "unpaid",
    ).length;
  root.innerHTML = `<div class="entry-heading"><div><span class="tag">PARTICIPANTS</span><h2>${esc(event.title)}｜参加者・支払い管理</h2></div><div class="actions admin-work-actions"><button id="exportParticipants" class="secondary" ${responses.length ? "" : "disabled"}>参加者CSVを出力</button></div></div><div class="summary-strip"><span>回答 ${responses.length}名</span><span>参加 ${joined}名</span><span>仮確保 ${offers.length}名</span>${event.fee_enabled && event.fee > 0 ? `<span>支払い済み ${paid}名</span><span>未払い ${unpaid}名</span>` : ""}</div><section id="manualNotifications" class="manual-notifications"></section><div id="participantList" class="participant-list"></div><section id="groupManager" class="group-manager"></section>`;
  const notificationRoot = root.querySelector("#manualNotifications");
  notificationRoot.innerHTML = offers.length ? `<h3>手動通知が必要な繰上げ案内</h3>${offers.map((offer) => `<article class="notice" data-offer="${offer.id}"><strong>${esc(offer.members?.name || "部員")}さん</strong><p>${esc(offer.members?.email || "")}／回答期限 ${fmt(offer.response_deadline)}</p><div class="actions"><button class="secondary copy-offer">連絡文をコピー</button><button class="notified" ${offer.notification_status === "manual_done" ? "disabled" : ""}>${offer.notification_status === "manual_done" ? "通知済み" : "通知済みにする"}</button></div></article>`).join("")}` : "";
  notificationRoot.querySelectorAll("article").forEach((item) => {
    const offer = offers.find((value) => value.id === item.dataset.offer);
    item.querySelector(".copy-offer").onclick = () => copyText(`${offer.members?.name || ""}さん\n「${event.title}」に空席が発生したため、1枠を仮確保しています。\n回答期限：${fmt(offer.response_deadline)}\n期限までに活動ポータルから「参加する」または「辞退する」を選択してください。`);
    item.querySelector(".notified").onclick = async () => { const { error } = await supabase.rpc("mark_waitlist_offer_notified", { p_offer_id: offer.id }); if (error) return failure(error); renderParticipants(event); };
  });
  root.querySelector("#exportParticipants").onclick = () => {
    const headers = [
        "MemberId",
        "氏名",
        "学年",
        "学部",
        "学科",
        "研究科",
        "専攻",
        "LINE名",
        "出欠",
        "貸出カメラ",
        "写るんです",
        "アレルギー",
        "アレルギー詳細",
        "備考",
        "支払い状況",
        "回答日時",
        "キャンセル日時",
        "キャンセル理由",
      ],
      rows = responses.map((response) => {
        const member = response.members || {};
        return [
          member.member_no,
          member.name,
          member.grade,
          member.faculty,
          member.department,
          member.graduate_school,
          member.major,
          response.line_name,
          response.cancelled_at ? "キャンセル済み" : response.attendance,
          response.camera ? "希望する" : "",
          response.disposable_camera ? "希望する" : "",
          response.allergies,
          response.other_allergy,
          response.note,
          paymentLabel(response.payment_status),
          response.submitted_at,
          response.cancelled_at,
          response.payment_updated_by === "system:payment-deadline"
            ? "支払期限超過による自動キャンセル"
            : "",
        ];
      }),
      eventName = safeStorageFileName(event.title, "event");
    downloadCsv(`${eventName}_参加者一覧.csv`, headers, rows);
    message("メールアドレスを含まない参加者CSVを出力しました。");
  };
  const list = root.querySelector("#participantList");
  if (!responses.length) {
    list.innerHTML = '<p class="muted">回答はまだありません。</p>';
    return renderGroupManager(event, [], root.querySelector("#groupManager"));
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
      `<article class="participant-row" data-id="${response.id}"><div><strong>${esc(member.name || "部員情報なし")}</strong><p>${esc(member.member_no || "")} ${esc(affiliation)}</p><p class="muted">${esc(member.email || "")}／回答 ${fmt(response.submitted_at)}</p></div><div><span class="status">${response.cancelled_at ? "キャンセル済み" : esc(response.attendance)}</span></div><div>${paymentTarget ? `<label>支払い状況<select class="payment-status"><option value="unpaid" ${response.payment_status === "unpaid" ? "selected" : ""}>未払い</option><option value="paid" ${response.payment_status === "paid" ? "selected" : ""}>支払い済み</option></select></label>${response.payment_updated_at ? `<small class="muted">${fmt(response.payment_updated_at)}<br>${esc(response.payment_updated_by)}</small>` : ""}` : '<span class="muted">支払い対象外</span>'}${response.attendance === "参加" && !response.cancelled_at ? '<button class="danger admin-cancel">参加取消</button>' : ""}</div></article>`,
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
  list.querySelectorAll(".admin-cancel").forEach((button) => button.onclick = async () => {
    const row = button.closest(".participant-row"), reason = prompt("取消理由（任意）", "");
    if (reason === null) return;
    const { error } = await supabase.rpc("admin_cancel_event_participation", { p_response_id: row.dataset.id, p_reason: reason });
    if (error) return failure(error);
    renderParticipants(event);
  });
  await renderGroupManager(event, responses.filter((r) => r.attendance === "参加" && !r.cancelled_at), root.querySelector("#groupManager"));
}

async function renderGroupManager(event, participants, root) {
  if (event.genre === "exhibition") return;
  let workspace = [];
  const draw = () => {
    const gradeOrder = { D3: 9, D2: 8, D1: 7, M2: 6, M1: 5, B4: 4, B3: 3, B2: 2, B1: 1 };
    workspace.forEach((group) => group.members.sort((a, b) => Number(b.memberId === group.leaderId) - Number(a.memberId === group.leaderId) || (gradeOrder[b.grade] || 0) - (gradeOrder[a.grade] || 0) || a.name.localeCompare(b.name, "ja")));
    const cards = workspace.map((group, index) => `<article class="group-card"><h4>${index + 1}班</h4><label>班長<select data-leader="${index}"><option value="">未設定</option>${group.members.map((m) => `<option value="${m.memberId}" ${group.leaderId === m.memberId ? "selected" : ""}>${esc(m.name)}</option>`).join("")}</select></label><ul>${group.members.map((m) => `<li>${esc(m.name)}（${esc(m.grade)}）<select aria-label="${esc(m.name)}さんの移動先" data-move-from="${index}" data-member="${m.memberId}">${workspace.map((_, target) => `<option value="${target}" ${target === index ? "selected" : ""}>${target + 1}班</option>`).join("")}</select></li>`).join("")}</ul></article>`).join("");
    root.querySelector("#groupWorkspace").innerHTML = cards;
    root.querySelectorAll("[data-leader]").forEach((select) => select.onchange = () => { workspace[Number(select.dataset.leader)].leaderId = select.value || null; draw(); });
    root.querySelectorAll("[data-move-from]").forEach((select) => select.onchange = () => {
      const from = Number(select.dataset.moveFrom), to = Number(select.value), source = workspace[from], memberIndex = source.members.findIndex((m) => m.memberId === select.dataset.member);
      if (from === to || memberIndex < 0) return;
      const [member] = source.members.splice(memberIndex, 1);
      if (source.leaderId === member.memberId) source.leaderId = null;
      workspace[to].members.push(member);
      draw();
    });
  };
  root.innerHTML = `<div class="section-head compact"><p class="eyebrow">GROUPING</p><h3>班分け</h3><p id="groupStatus" class="muted"></p></div><p class="muted">写真展以外の正式参加者だけが対象です。公開には各班の班長設定が必要です。</p><div class="inline-field"><label>班数<input id="groupCount" type="number" min="1" max="${Math.max(1, participants.length)}" value="${Math.min(3, Math.max(1, participants.length))}"></label><button id="generateGroups">自動生成</button></div><div id="groupWorkspace" class="group-grid"></div><div class="actions"><button id="unpublishGroups" class="danger hidden">非公開にする</button><button id="draftGroups" class="secondary" disabled>一時保存</button><button id="saveGroups" disabled>保存</button><button id="publishGroups" disabled>保存して公開</button></div>`;
  root.querySelector("#generateGroups").onclick = () => {
    const count = Number(root.querySelector("#groupCount").value);
    if (!participants.length || count < 1 || count > participants.length) return failure("参加者数以内の班数を指定してください。");
    const members = participants.map((r) => ({ memberId: r.member_id, name: r.members.name, grade: r.members.grade, gender: r.members.gender || "", faculty: r.members.faculty || "", department: r.members.department || "" }))
      .sort((a, b) => a.gender.localeCompare(b.gender) || a.faculty.localeCompare(b.faculty) || Math.random() - .5);
    workspace = Array.from({ length: count }, (_, i) => ({ name: `${i + 1}班`, leaderId: null, members: [] }));
    members.forEach((member, index) => workspace[index % count].members.push(member));
    const leaderOrder = (m) => m.grade === "B3" ? 0 : m.grade === "B4" ? 1 : m.grade === "B2" ? 2 : 9;
    workspace.forEach((group) => { group.members.sort((a, b) => leaderOrder(a) - leaderOrder(b)); group.leaderId = group.members[0]?.memberId || null; });
    draw(); root.querySelectorAll("#draftGroups,#saveGroups,#publishGroups").forEach((b) => b.disabled = false);
  };
  const save = async (type, publish) => {
    const { data, error } = await supabase.rpc("save_event_group_version", { p_event_id: event.id, p_save_type: type, p_groups: workspace });
    if (error) return failure(error);
    if (publish) { const result = await supabase.rpc("publish_event_group_version", { p_version_id: data.versionId }); if (result.error) return failure(result.error); }
    message(publish ? `班分けv${data.versionNumber}を公開しました。` : `班分けv${data.versionNumber}を保存しました。`);
  };
  root.querySelector("#draftGroups").onclick = () => save("draft", false);
  root.querySelector("#saveGroups").onclick = () => save("saved", false);
  root.querySelector("#publishGroups").onclick = () => save("saved", true);
  const { data: assignment, error: assignmentError } = await supabase.from("event_group_assignments").select("*").eq("event_id", event.id).maybeSingle();
  if (assignmentError) return failure(assignmentError);
  if (assignment?.current_version_id) {
    const { data: version, error } = await supabase.from("event_group_versions").select("*").eq("id", assignment.current_version_id).single();
    if (error) return failure(error);
    workspace = version.groups || [];
    root.querySelector("#groupCount").value = version.group_count;
    root.querySelector("#groupStatus").textContent = `最新保存版 v${version.version_number}（${version.save_type === "saved" ? "保存済み" : "下書き"}）${assignment.is_published ? "／公開中" : ""}`;
    draw();
    root.querySelectorAll("#draftGroups,#saveGroups,#publishGroups").forEach((b) => b.disabled = false);
  }
  if (assignment?.is_published) {
    const button = root.querySelector("#unpublishGroups");
    button.classList.remove("hidden");
    button.onclick = async () => { if (!confirm("公開中の班分けを非公開にしますか？")) return; const { error } = await supabase.rpc("unpublish_event_groups", { p_event_id: event.id }); if (error) return failure(error); renderParticipants(event); };
  }
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
        .select("*,current_accepted_snapshot:exhibition_work_submission_snapshots!exhibition_works_current_accepted_fk(*),exhibition_entries!inner(event_id,members(member_no,name))")
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
      works = (workResult.data || [])
        .filter((work) => Number(event.exhibition_workflow_version) !== 2 || work.workflow_state === "accepted")
        .map((work) => Number(event.exhibition_workflow_version) === 2 && work.current_accepted_snapshot ? ({ ...work, orientation: work.current_accepted_snapshot.orientation, print_size: work.current_accepted_snapshot.print_size, print_size_detail: work.current_accepted_snapshot.print_size_detail, occupied_width_mm: work.current_accepted_snapshot.occupied_width_mm, occupied_height_mm: work.current_accepted_snapshot.occupied_height_mm }) : work),
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
    root.innerHTML = `<div class="entry-heading"><div><span class="tag">EXHIBITION LAYOUT PLAN</span><h2>${esc(event.exhibition_title || event.title)}｜展示シミュレータ</h2><p class="muted">会場：${esc(venue.name)}／これは展示予定です。実際の展示記録ではありません。</p></div></div><section class="simulator-section"><div class="section-head compact"><h3>1. 壁面</h3></div><div class="wall-summary">${walls.length ? walls.map((wall) => `<span>${esc(wall.name)}：${wall.width_mm} × ${wall.height_mm} mm</span>`).join("") : '<span class="muted">壁面が未登録です。</span>'}</div><form id="wallForm" class="form-grid compact-form"><label>壁面名<input name="name" required placeholder="例：正面壁面"></label><label>表示順<input type="number" name="display_order" min="1" required value="${walls.length + 1}"></label><label>幅（mm）<input type="number" name="width_mm" min="1" step="0.01" required></label><label>高さ（mm）<input type="number" name="height_mm" min="1" step="0.01" required></label><label>壁面色<input type="color" name="background_color" value="#FFFFFF"></label><label class="full">注意事項<input name="notes" placeholder="例：右端500mmは配電盤"></label><div class="actions full"><button>壁面を追加</button></div></form></section><section class="simulator-section"><div class="section-head compact"><h3>2. 作品の物理仕様</h3><p>${Number(event.exhibition_workflow_version) === 2 ? "確認済みWork Snapshotの物理仕様です。変更はWork再編集から行ってください。" : "単写真は用紙寸法が初期入力されています。額装・組み写真は実際に壁を占有する外寸へ修正してください。"}</p></div><div class="dimension-list">${works.length ? works.map((work) => `<form class="dimension-row" data-work-id="${work.id}"><div><strong>${work.display_no ? `No.${esc(work.display_no)}` : `作品${work.sort_order}`} ${esc(work.title || "作品名未入力")}</strong><small>${esc(work.exhibition_entries?.members?.name || "")}／${esc(printSizeLabel(work.print_size, work.print_size_detail))}${work.current_accepted_snapshot_id ? `／Snapshot ${esc(work.current_accepted_snapshot_id.slice(0, 8))}` : ""}</small></div><label>幅<input type="number" name="width" min="1" step="0.01" value="${work.occupied_width_mm || ""}" required ${Number(event.exhibition_workflow_version) === 2 ? "disabled" : ""}></label><label>高さ<input type="number" name="height" min="1" step="0.01" value="${work.occupied_height_mm || ""}" required ${Number(event.exhibition_workflow_version) === 2 ? "disabled" : ""}></label>${Number(event.exhibition_workflow_version) === 2 ? "" : '<button class="secondary">外寸を保存</button>'}</form>`).join("") : '<p class="muted">配置可能な確認済み作品がありません。</p>'}</div></section><section class="simulator-section"><div class="section-head compact"><h3>3. Layout Plan</h3></div><div class="layout-toolbar"><select id="layoutSelect"><option value="">配置案を選択</option>${layouts.map((layout) => `<option value="${layout.id}" ${layout.id === currentLayout?.id ? "selected" : ""}>${esc(layout.name)} v${layout.version_no}${layout.is_current ? "（現在案）" : ""}</option>`).join("")}</select><form id="layoutForm" class="inline-field"><input name="name" required placeholder="例：第1案"><button>新しい配置案を作成</button></form></div>${currentLayout ? `<div class="layout-status"><strong>${esc(currentLayout.name)} v${currentLayout.version_no}</strong><span>${currentLayout.status === "approved" ? "確定済みPlan" : currentLayout.status === "review" ? "確認中" : currentLayout.status === "archived" ? "保管" : "下書き"}</span></div><div class="unplaced-works"><h4>未配置作品（${unplaced.length}点）</h4>${unplaced.length ? unplaced.map((work) => `<div class="unplaced-work"><span>${work.display_no ? `No.${esc(work.display_no)}` : `作品${work.sort_order}`} ${esc(work.title || "作品名未入力")}</span>${work.occupied_width_mm && walls.length ? `<select data-wall-choice><option value="">配置先の壁面</option>${walls.filter((wall) => wall.usable).map((wall) => `<option value="${wall.id}">${esc(wall.name)}</option>`).join("")}</select><button class="place-work secondary" data-work-id="${work.id}">配置</button>` : '<small class="muted">占有外寸または壁面が未設定です。</small>'}</div>`).join("") : '<p class="muted">すべての作品が配置されています。</p>'}</div><div class="wall-canvases">${walls.map((wall) => renderWallCanvas(wall, placements.filter((item) => item.wall_id === wall.id), workById)).join("")}</div>` : '<div class="notice">配置案を作成すると、作品を壁面へ配置できます。</div>'}</section>`;

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
      if (Number(event.exhibition_workflow_version) === 2) return;
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
          viewing_order: placements.length + 1,
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
    const overlapCount = markPlacementOverlaps(root, placements, workById);
    if (currentLayout) {
      const statusBox = root.querySelector(".layout-status"),
        readOnly = ["approved", "archived"].includes(currentLayout.status);
      statusBox.insertAdjacentHTML(
        "afterend",
        `<div class="actions layout-actions"><button id="cloneLayout" class="secondary">次の版へ複製</button>${Number(event.exhibition_workflow_version) === 2 ? (currentLayout.status === "draft" || currentLayout.status === "review" ? '<button id="finalizeLayoutV2">Layout Planを確定</button>' : "") : `${currentLayout.status !== "review" ? '<button id="reviewLayout" class="secondary">確認中にする</button>' : ""}${currentLayout.status !== "approved" ? '<button id="approveLayout">この案を承認</button>' : ""}${currentLayout.status !== "draft" ? '<button id="draftLayout" class="secondary">下書きへ戻す</button>' : ""}${currentLayout.status !== "archived" ? '<button id="archiveLayout" class="secondary">保管する</button>' : ""}`}<button id="printLayout" class="secondary">配置図を印刷・PDF保存</button></div>${overlapCount ? `<div class="notice error overlap-notice">作品の重なりを${overlapCount}組検出しました。赤枠の作品と座標を確認してください。</div>` : '<div class="notice overlap-notice">作品同士の重なりは検出されていません。</div>'}`,
      );
      if (readOnly) {
        root
          .querySelectorAll(
            ".unplaced-work select,.place-work,.placement-row input,.placement-row button",
          )
          .forEach((control) => (control.disabled = true));
      }
      root.querySelector("#cloneLayout").onclick = async () => {
        if (
          !confirm(
            `「${currentLayout.name} v${currentLayout.version_no}」の配置を次の版へ複製しますか？`,
          )
        )
          return;
        const { data, error } = await supabase.rpc(
          "admin_clone_exhibition_layout",
          { p_layout_id: currentLayout.id },
        );
        if (error) return failure(error);
        await renderExhibitionSimulator(event, data.layoutId);
        message(
          `${data.name} v${data.versionNo}を作成し、${data.copiedPlacements}件の配置を複製しました。`,
        );
      };
      const setStatus = async (status, prompt, success) => {
        if (!confirm(prompt)) return;
        const { error } = await supabase.rpc(
          "admin_set_exhibition_layout_status",
          { p_layout_id: currentLayout.id, p_status: status },
        );
        if (error) return failure(error);
        await renderExhibitionSimulator(event, currentLayout.id);
        message(success);
      };
      root.querySelector("#reviewLayout")?.addEventListener("click", () =>
        setStatus(
          "review",
          "この配置案を確認中にしますか？",
          "配置案を確認中にしました。",
        ),
      );
      root.querySelector("#approveLayout")?.addEventListener("click", () =>
        setStatus(
          "approved",
          "この配置案を承認し、写真展の現在案に設定しますか？承認後は編集できません。",
          "配置案を承認し、現在案に設定しました。",
        ),
      );
      root.querySelector("#finalizeLayoutV2")?.addEventListener("click", async () => {
        if (!confirm("鑑賞順に基づいてLayout Planを確定し、未採番Workへdisplay_noを付与しますか？確定履歴と番号は変更できません。")) return;
        const reason = layouts.some((item) => item.current_finalization_id) ? prompt("再確定理由（必須）") : "初回確定";
        if (reason === null || !reason.trim()) return;
        const { data, error } = await supabase.rpc("admin_finalize_exhibition_layout_v2", { p_layout_id: currentLayout.id, p_reason: reason.trim() });
        if (error) return failure(error);
        await renderExhibitionSimulator(event, currentLayout.id);
        message(`Layout Plan v${data.version}を確定しました。新規採番 ${data.assignedDisplayNumbers}点`);
      });
      root.querySelector("#draftLayout")?.addEventListener("click", () =>
        setStatus(
          "draft",
          "この配置案を下書きへ戻しますか？現在案の指定は解除されます。",
          "配置案を下書きへ戻しました。",
        ),
      );
      root.querySelector("#archiveLayout")?.addEventListener("click", () =>
        setStatus(
          "archived",
          "この配置案を保管しますか？保管後は編集できません。",
          "配置案を保管しました。",
        ),
      );
      root.querySelector("#printLayout").onclick = () => {
        document.body.classList.add("printing-layout");
        window.addEventListener(
          "afterprint",
          () => document.body.classList.remove("printing-layout"),
          { once: true },
        );
        window.print();
        setTimeout(() => document.body.classList.remove("printing-layout"), 1500);
      };
    }
  } catch (error) {
    failure(error);
  }
}

function renderWallCanvas(wall, placements, workById) {
  return `<section class="wall-panel"><div class="wall-panel-head"><h4>${esc(wall.name)}</h4><span>${wall.width_mm} × ${wall.height_mm} mm</span></div><div class="wall-canvas" data-wall-id="${wall.id}" data-wall-width="${wall.width_mm}" data-wall-height="${wall.height_mm}" style="--wall-ratio:${wall.width_mm}/${wall.height_mm};background:${esc(wall.background_color)}">${placements.map((placement) => { const work = workById[placement.work_id]; if (!work) return ""; const left = Number(placement.x_mm) / Number(wall.width_mm) * 100, top = (Number(wall.height_mm) - Number(placement.top_from_floor_mm)) / Number(wall.height_mm) * 100, width = Number(work.occupied_width_mm) / Number(wall.width_mm) * 100, height = Number(work.occupied_height_mm) / Number(wall.height_mm) * 100; return `<button type="button" class="placed-work ${placement.locked ? "is-locked" : ""}" data-placement-id="${placement.id}" ${work.preview_image_path ? `data-preview-path="${esc(work.preview_image_path)}"` : ""} style="left:${left}%;top:${top}%;width:${width}%;height:${height}%;z-index:${placement.z_order}" title="${esc(work.title)}"><strong>${placement.viewing_order ? `${placement.viewing_order}. ` : ""}${work.display_no ? `No.${esc(work.display_no)}` : `作品${work.sort_order}`}</strong><span>${esc(work.title || "")}</span></button>`; }).join("")}</div><div class="placement-list">${placements.map((placement) => { const work = workById[placement.work_id]; return work ? `<form class="placement-row" data-placement-id="${placement.id}" data-work-id="${work.id}"><strong>${work.display_no ? `No.${esc(work.display_no)}` : `作品${work.sort_order}`} ${esc(work.title || "")}</strong>${placement.accepted_work_snapshot_id && placement.accepted_work_snapshot_id !== work.current_accepted_snapshot_id ? '<span class="notice error">Work Snapshotが更新されています</span>' : ""}<label>鑑賞順<input type="number" name="viewing_order" min="1" step="1" value="${placement.viewing_order || ""}" required></label><label>左端 x<input type="number" name="x_mm" min="0" step="1" value="${placement.x_mm}"></label><label>床から上端<input type="number" name="top_from_floor_mm" min="0" step="1" value="${placement.top_from_floor_mm}"></label><label class="lock-label"><input type="checkbox" name="locked" ${placement.locked ? "checked" : ""}>固定</label>${placement.accepted_work_snapshot_id !== work.current_accepted_snapshot_id ? '<button type="button" class="secondary refresh-placement-snapshot">現在の物理仕様を再確認</button>' : ""}<button class="secondary save-placement">保存</button><button type="button" class="danger remove-placement">配置解除</button></form>` : ""; }).join("")}</div></section>`;
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

function markPlacementOverlaps(root, placements, workById) {
  let count = 0;
  for (let firstIndex = 0; firstIndex < placements.length; firstIndex += 1) {
    const first = placements[firstIndex],
      firstWork = workById[first.work_id];
    if (!firstWork) continue;
    for (
      let secondIndex = firstIndex + 1;
      secondIndex < placements.length;
      secondIndex += 1
    ) {
      const second = placements[secondIndex],
        secondWork = workById[second.work_id];
      if (!secondWork || first.wall_id !== second.wall_id) continue;
      const horizontal =
          Number(first.x_mm) <
            Number(second.x_mm) + Number(secondWork.occupied_width_mm) &&
          Number(second.x_mm) <
            Number(first.x_mm) + Number(firstWork.occupied_width_mm),
        firstBottom =
          Number(first.top_from_floor_mm) -
          Number(firstWork.occupied_height_mm),
        secondBottom =
          Number(second.top_from_floor_mm) -
          Number(secondWork.occupied_height_mm),
        vertical =
          firstBottom < Number(second.top_from_floor_mm) &&
          secondBottom < Number(first.top_from_floor_mm);
      if (!horizontal || !vertical) continue;
      count += 1;
      for (const placement of [first, second]) {
        const item = root.querySelector(
          `.placed-work[data-placement-id="${placement.id}"]`,
        );
        item?.classList.add("has-overlap");
        if (item)
          item.title = `${item.title}（別作品と重なっています）`;
      }
    }
  }
  return count;
}

function setupPlacementControls(root, event, layout, walls, workById) {
  if (!layout) return;
  const readOnly = ["approved", "archived"].includes(layout.status);
  const savePlacement = async (form, quiet = false) => {
    const work = workById[form.dataset.workId],
      wall = walls.find((item) => item.id === form.closest(".wall-panel").querySelector(".wall-canvas").dataset.wallId),
      x = Number(form.elements.x_mm.value),
      top = Number(form.elements.top_from_floor_mm.value);
    if (x < 0 || x + Number(work.occupied_width_mm) > Number(wall.width_mm)) throw new Error("作品が壁面の左右端を超えています。");
    if (top > Number(wall.height_mm) || top - Number(work.occupied_height_mm) < 0) throw new Error("作品が壁面の上下端を超えています。");
    const { error } = await supabase.from("exhibition_placements").update({ x_mm: x, top_from_floor_mm: top, viewing_order: Number(form.elements.viewing_order.value), locked: form.elements.locked.checked }).eq("id", form.dataset.placementId);
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
    if (readOnly) return;
    form.onsubmit = async (submit) => { submit.preventDefault(); try { await savePlacement(form); await renderExhibitionSimulator(event, layout.id); } catch (error) { failure(error); } };
    form.querySelector(".remove-placement").onclick = async () => {
      if (!confirm("この作品を壁面から外しますか？作品登録自体は削除されません。")) return;
      const { error } = await supabase.from("exhibition_placements").update({ status: "removed" }).eq("id", form.dataset.placementId);
      if (error) return failure(error);
      await renderExhibitionSimulator(event, layout.id);
      message("作品を配置から外しました。");
    };
    form.querySelector(".refresh-placement-snapshot")?.addEventListener("click", async () => {
      const { error } = await supabase.rpc("admin_refresh_exhibition_placement_snapshot_v2", { p_placement_id: form.dataset.placementId });
      if (error) return failure(error);
      await renderExhibitionSimulator(event, layout.id);
      message("Placementを現在のAccepted Work Snapshotへ更新しました。");
    });
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
      message(locked ? "配置を固定しました。" : "配置の固定を解除しました。");
    };
  });
  root.querySelectorAll(".placed-work").forEach((item) => {
    const form = root.querySelector(`.placement-row[data-placement-id="${item.dataset.placementId}"]`);
    if (!form || readOnly) return;
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
      item.onpointerup = async () => { item.onpointermove = null; try { await savePlacement(form, true); await renderExhibitionSimulator(event, layout.id); message("ドラッグ後の配置座標を保存しました。"); } catch (error) { failure(error); await renderExhibitionSimulator(event, layout.id); } };
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
  let v2Cases = [];
  if (Number(event.exhibition_workflow_version) === 2) {
    const { data, error: casesError } = await supabase
      .from("exhibition_workflow_cases")
      .select("*")
      .eq("event_id", event.id)
      .order("requested_at", { ascending: false });
    if (casesError) return failure(casesError);
    v2Cases = data || [];
  }
  const visibleWorks = (entries || []).flatMap((entry) =>
      (entry.exhibition_works || [])
        .filter((work) => work.status !== "withdrawn")
        .map((work) => ({ entry, work })),
    ),
    submitted = entries.filter((entry) => entry.status === "submitted").length;
  root.innerHTML = `<div class="entry-heading"><div><span class="tag">EXHIBITORS & WORKS</span><h2>${esc(event.exhibition_title || event.title)}｜出展者・作品管理</h2></div><div class="actions admin-work-actions"><button id="assignDisplayNumbers" class="secondary" ${visibleWorks.some((item) => !item.work.display_no) ? "" : "disabled"}>未採番作品へ連番を付与</button><button id="exportExhibitionManifest" class="secondary" ${visibleWorks.length ? "" : "disabled"}>連携用CSVを出力</button><button id="copyExhibitionCaptions" class="secondary" ${visibleWorks.length ? "" : "disabled"}>タイトル・キャプションを一括コピー</button></div></div><div class="summary-strip"><span>申込 ${entries.length}名</span><span>確定 ${submitted}名</span><span>作品 ${visibleWorks.length}点</span><span>未採番 ${visibleWorks.filter((item) => !item.work.display_no).length}点</span><span>確認済み ${visibleWorks.filter((item) => item.work.status === "accepted").length}点</span><span>要修正 ${visibleWorks.filter((item) => item.work.status === "rejected").length}点</span><span>QR登録 ${visibleWorks.filter((item) => item.work.instagram_qr_path).length}点</span></div><div id="exhibitorList" class="exhibitor-list"></div>`;
  if (Number(event.exhibition_workflow_version) === 2) {
    root.querySelector(".admin-work-actions").insertAdjacentHTML(
      "afterbegin",
      '<button id="processV2Deadlines" class="secondary">期限処理を実行</button><button id="showV2Export" class="secondary">Master Export / Publication</button><button id="showV2Actual" class="secondary">Actual実展示記録</button><button id="showV2Archive" class="secondary">Archive</button>',
    );
    root.querySelector("#assignDisplayNumbers").disabled = true;
    root.querySelector("#exportExhibitionManifest").disabled = true;
    root.querySelector("#exportExhibitionManifest").title = "Workflow v2では不変Master Exportを使用してください。";
    root.querySelector("#copyExhibitionCaptions").disabled = true;
    root.querySelector("#copyExhibitionCaptions").title = "Workflow v2では不変Master Exportを使用してください。";
    root.querySelector("#processV2Deadlines").onclick = async () => {
      if (!confirm("Work提出期限・個別期限・Revival期限のSYSTEM処理を実行しますか？")) return;
      const { data, error } = await supabase.rpc("admin_process_exhibition_work_deadlines_v2", { p_event_id: event.id });
      if (error) return failure(error);
      await renderExhibitionParticipants(event); message(`期限処理が完了しました（Draft取下げ ${data.draftWorksWithdrawn || 0}件）。`);
    };
  }
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
      `<article class="exhibitor-card" data-entry-id="${entry.id}"><div class="exhibitor-head"><div><span class="tag">${entry.application_state === "auto_cancelled" ? "自動取消" : entry.status === "submitted" ? "申込済み" : entry.status === "withdrawn" ? "取り下げ" : "下書き"}</span><h3>${esc(member.name || "部員情報なし")}</h3><p>${esc(member.member_no || "")} ${esc(affiliation)}</p>${Number(event.exhibition_workflow_version) === 2 ? `<p class="muted">表示名：${esc(entry.display_name_value || "未設定")}／予定 ${entry.planned_work_count || 0}作品</p>${entry.application_state === "auto_cancelled" && Number(entry.revival_count || 0) < 1 ? '<button type="button" class="secondary revive-v2-entry">例外的に復活</button>' : ""}` : ""}</div><span class="status">${works.length}作品</span></div>${entry.note ? `<p class="muted">出展備考：${esc(entry.note)}</p>` : ""}<div class="admin-work-list">${works.length ? works.map((work) => `<section class="admin-work-card" data-work-id="${work.id}"><div class="admin-work-image">${work.preview_image_path ? `<span class="storage-image" data-storage-path="${esc(work.preview_image_path)}" data-alt="${esc(work.title || "作品プレビュー")}">プレビュー読込中…</span>` : '<span class="muted">プレビューなし</span>'}${work.original_image_path ? `<button type="button" class="secondary download-original" data-original-path="${esc(work.original_image_path)}" data-file-name="${esc(managedOriginalFileName(member, work))}">原画像をダウンロード</button>` : ""}</div><div class="admin-work-copy"><div class="work-meta"><span class="tag">${work.display_no ? `No.${esc(work.display_no)}` : `WORK ${work.sort_order}`}</span><span>${esc(exhibitionWorkStatus(work.status))}</span></div><h3>${esc(work.title || "作品名未入力")}</h3><dl class="caption-details"><dt>向き</dt><dd>${esc(orientationLabel(work.orientation))}</dd><dt>出展サイズ</dt><dd>${esc(printSizeLabel(work.print_size, work.print_size_detail))}</dd><dt>作者</dt><dd>${work.artist_name ? esc(work.artist_name) : '<span class="muted">未入力</span>'}</dd><dt>Camera</dt><dd>${work.camera_name ? esc(work.camera_name) : '<span class="muted">未入力</span>'}</dd><dt>Lens, other</dt><dd>${work.lens_other ? esc(work.lens_other) : '<span class="muted">未入力</span>'}</dd><dt>Description</dt><dd class="caption-text">${work.description ? esc(work.description) : '<span class="muted">未入力</span>'}</dd></dl><p class="muted">アップロード元：${esc(work.original_file_name || "不明")}</p><p class="muted">管理ファイル名：${esc(managedOriginalFileName(member, work))}</p>${work.note ? `<p class="muted">作品備考：${esc(work.note)}</p>` : ""}<div class="work-admin-controls"><label>作品番号<input class="display-no" value="${esc(work.display_no || "")}" placeholder="例：01"></label><label>確認状態<select class="review-status"><option value="submitted" ${work.status === "submitted" || work.status === "draft" ? "selected" : ""}>提出済み</option><option value="accepted" ${work.status === "accepted" ? "selected" : ""}>確認済み</option><option value="rejected" ${work.status === "rejected" ? "selected" : ""}>要修正</option></select></label><button type="button" class="update-work">作品情報を更新</button></div></div><div class="admin-work-qr"><strong>Instagram QR</strong>${work.instagram_qr_path ? `<span class="storage-image qr-image" data-storage-path="${esc(work.instagram_qr_path)}" data-alt="${esc(`${work.title || "作品"}のInstagram QRコード`)}">QR読込中…</span><small>${esc(work.instagram_qr_file_name || "登録済み")}</small><button type="button" class="secondary download-qr" data-qr-path="${esc(work.instagram_qr_path)}" data-file-name="${esc(work.instagram_qr_file_name || "instagram-qr")}">QR画像をダウンロード</button>` : '<span class="muted">未登録</span>'}</div></section>`).join("") : '<p class="muted">作品はまだ登録されていません。</p>'}</div></article>`,
    );
  });
  root.querySelectorAll(".revive-v2-entry").forEach((button) => {
    button.onclick = async () => {
      const card = button.closest(".exhibitor-card"), reason = prompt("復活理由（必須）");
      if (!reason) return;
      const deadline = prompt("例外作品提出期限をISO形式で入力してください（未来時刻）。");
      if (!deadline) return;
      const parsed = new Date(deadline);
      if (Number.isNaN(parsed.getTime())) return failure(new Error("期限の形式が不正です。"));
      const { error } = await supabase.rpc("admin_revive_exhibition_entry_v2", {
        p_entry_id: card.dataset.entryId, p_reason: reason, p_exception_deadline: parsed.toISOString(),
      });
      if (error) return failure(error);
      renderExhibitionParticipants(event);
    };
  });
  root
    .querySelector(".summary-strip")
    .insertAdjacentHTML(
      "beforeend",
      `<span>掲載同意 ${visibleWorks.filter((item) => item.work.publication_consent === true).length}点</span><span>掲載不同意 ${visibleWorks.filter((item) => item.work.publication_consent === false).length}点</span><span>掲載未回答 ${visibleWorks.filter((item) => item.work.publication_consent === null).length}点</span>`,
    );
  root.querySelectorAll(".admin-work-card").forEach((card) => {
    const work = visibleWorks.find(
      (item) => item.work.id === card.dataset.workId,
    )?.work;
    if (!work) return;
    card.querySelector(".caption-details").insertAdjacentHTML(
      "beforeend",
      `<dt>サイト掲載</dt><dd>${
        work.publication_consent === true
          ? "同意"
          : work.publication_consent === false
            ? "不同意（NO IMAGE）"
            : '<span class="muted">未回答</span>'
      }</dd>`,
    );
    card.querySelector(".work-admin-controls").insertAdjacentHTML(
      "beforebegin",
      `<fieldset class="work-translation-fields"><legend>English（任意）</legend><label>Title<input class="title-en" maxlength="500" value="${esc(work.title_en || "")}" placeholder="空欄の場合は日本語作品名を表示"></label><label>Description<textarea class="description-en" maxlength="3000" rows="3" placeholder="空欄の場合は日本語Descriptionを表示">${esc(work.description_en || "")}</textarea></label></fieldset>`,
    );
    card.querySelector(".work-admin-controls").insertAdjacentHTML(
      "beforebegin",
      `<div class="public-image-controls"><span>${work.public_release && work.public_image_path ? "透かし入り公開画像：生成済み" : work.publication_consent === false ? "掲載不同意：NO IMAGEで公開" : "透かし入り公開画像：未生成"}</span><button type="button" class="secondary generate-public-image" ${work.publication_consent === true && work.preview_image_path ? "" : "disabled"}>${work.public_release ? "公開画像を再生成" : "公開画像を生成"}</button></div>`,
    );
    if (Number(event.exhibition_workflow_version) === 2) {
      card.querySelector(".work-translation-fields")?.remove();
      const controls = card.querySelector(".work-admin-controls"),
        pendingCase = v2Cases.find((item) => item.work_id === work.id && item.case_type === "reedit" && item.state === "pending");
      controls.innerHTML = work.workflow_state === "submitted" && work.current_submission_snapshot_id
        ? '<button type="button" class="accept-v2-work">作品を確認済みにする</button><button type="button" class="reject-v2-work danger">要修正にする</button>'
        : pendingCase
          ? '<button type="button" class="permit-v2-reedit">再編集を許可</button><button type="button" class="reject-v2-reedit danger">再編集を却下</button>'
          : `<span class="status">${esc(work.workflow_state || work.status)}</span>`;
      controls.insertAdjacentHTML("beforeend", '<button type="button" class="withdraw-v2-work-admin danger">管理者として取り下げる</button>');
      controls.querySelector(".accept-v2-work")?.addEventListener("click", async () => {
        if (!confirm("このSubmission Snapshotを作品確認済みにしますか？キャプション確認は別工程です。")) return;
        const { error } = await supabase.rpc("admin_review_exhibition_work_v2", {
          p_submission_snapshot_id: work.current_submission_snapshot_id, p_result: "accepted",
          p_problem_fields: [], p_reason: "", p_individual_deadline: null,
        });
        if (error) return failure(error); renderExhibitionParticipants(event);
      });
      controls.querySelector(".reject-v2-work")?.addEventListener("click", async () => {
        const fields = prompt("問題項目をカンマ区切りで入力してください（original,title,orientation,print_size,physical_dimensions,publication_consent,other）", "other");
        if (!fields) return; const reason = prompt("要修正理由（必須）"); if (!reason) return;
        let deadline = null;
        if (Date.now() >= new Date(event.exhibition_revision_deadline).getTime()) {
          const value = prompt("Global修正期限後です。個別期限をISO形式で入力してください。", ""); if (!value) return;
          deadline = new Date(value).toISOString();
        }
        const { error } = await supabase.rpc("admin_review_exhibition_work_v2", {
          p_submission_snapshot_id: work.current_submission_snapshot_id, p_result: "rejected",
          p_problem_fields: fields.split(",").map((value) => value.trim()).filter(Boolean), p_reason: reason,
          p_individual_deadline: deadline,
        });
        if (error) return failure(error); renderExhibitionParticipants(event);
      });
      const decide = async (permit) => {
        const reason = prompt(permit ? "再編集を許可する理由（必須）" : "再編集を却下する理由（必須）"); if (!reason) return;
        let deadline = null;
        if (permit) { const value = prompt("再編集の個別期限をISO形式で入力してください。"); if (!value) return; deadline = new Date(value).toISOString(); }
        const { error } = await supabase.rpc("admin_decide_exhibition_work_reedit_v2", {
          p_case_id: pendingCase.id, p_permit: permit, p_reason: reason, p_individual_deadline: deadline,
        });
        if (error) return failure(error); renderExhibitionParticipants(event);
      };
      controls.querySelector(".permit-v2-reedit")?.addEventListener("click", () => decide(true));
      controls.querySelector(".reject-v2-reedit")?.addEventListener("click", () => decide(false));
      controls.querySelector(".withdraw-v2-work-admin")?.addEventListener("click", async () => {
        const reason = prompt("管理者取り下げ理由（必須）");
        if (!reason) return;
        const { error } = await supabase.rpc("admin_withdraw_exhibition_work_v2", { p_work_id: work.id, p_reason: reason });
        if (error) return failure(error);
        renderExhibitionParticipants(event);
      });
    }
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
        "TitleEn",
        "Artist",
        "Camera",
        "LensOther",
        "Description",
        "DescriptionEn",
        "PublicationConsent",
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
          work.title_en,
          work.artist_name,
          work.camera_name,
          work.lens_other,
          work.description,
          work.description_en,
          work.publication_consent === true
            ? "consent"
            : work.publication_consent === false
              ? "decline"
              : "",
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
          `Title：${work.title_en || ""}`,
          `向き：${orientationLabel(work.orientation)}`,
          `出展サイズ：${printSizeLabel(work.print_size, work.print_size_detail)}`,
          `作者：${work.artist_name || ""}`,
          `Camera：${work.camera_name || ""}`,
          `Lens, other：${work.lens_other || ""}`,
          `Description：${work.description || ""}`,
          `Description (English)：${work.description_en || ""}`,
          `写真展サイト掲載：${work.publication_consent === true ? "同意" : work.publication_consent === false ? "不同意（NO IMAGE）" : "未回答"}`,
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
  root.querySelectorAll(".generate-public-image").forEach((button) => {
    button.onclick = async () => {
      const card = button.closest(".admin-work-card"),
        item = visibleWorks.find(({ work }) => work.id === card.dataset.workId),
        work = item?.work;
      if (!work?.preview_image_path || work.publication_consent !== true) return;
      if (
        !confirm(
          `「${work.title || `作品${work.sort_order}`}」のプレビューから、写真部ロゴ入り公開画像を生成しますか？`,
        )
      )
        return;
      button.disabled = true;
      try {
        const workflowV2 = Number(event.exhibition_workflow_version) === 2,
          blob = await createWatermarkedPublicImage(work.preview_image_path),
          path = workflowV2
            ? `${event.id}/${work.owner_member_id}/${work.id}/public-${crypto.randomUUID()}.webp`
            : `${event.id}/${work.owner_member_id}/${work.id}/public.webp`,
          { error: uploadError } = await supabase.storage
            .from("exhibition-public")
            .upload(path, blob, {
              upsert: !workflowV2,
              contentType: "image/webp",
              cacheControl: "3600",
            });
        if (uploadError) throw uploadError;
        const { error: workError } = workflowV2
          ? await supabase.rpc("admin_set_exhibition_public_image_v2", { p_work_id: work.id, p_public_image_path: path })
          : await supabase.from("exhibition_works").update({ public_image_path: path, public_release: true }).eq("id", work.id);
        if (workError) throw workError;
        if (!workflowV2 && event.site_status !== "draft") {
          const { error: draftError } = await supabase
            .from("events")
            .update({ site_status: "draft", updated_at: new Date().toISOString() })
            .eq("id", event.id);
          if (draftError) throw draftError;
          event.site_status = "draft";
        }
        await renderExhibitionParticipants(event);
        message("透かし入り公開画像を生成しました。写真展サイトは下書き状態です。");
      } catch (imageError) {
        failure(imageError);
        button.disabled = false;
      }
    };
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
          status = card.querySelector(".review-status").value,
          titleEn = card.querySelector(".title-en").value.trim(),
          descriptionEn = card.querySelector(".description-en").value.trim();
        if (
          !confirm(
            `作品番号、確認状態、英語版情報を更新しますか？\n作品番号：${displayNo || "未採番"}\n確認状態：${exhibitionWorkStatus(status)}`,
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
        const { error: translationError } = await supabase
          .from("exhibition_works")
          .update({ title_en: titleEn, description_en: descriptionEn })
          .eq("id", card.dataset.workId);
        if (translationError) {
          button.disabled = false;
          failure(translationError);
          return;
        }
        if (event.site_status !== "draft") {
          const { error: draftError } = await supabase
            .from("events")
            .update({ site_status: "draft", updated_at: new Date().toISOString() })
            .eq("id", event.id);
          if (draftError) {
            button.disabled = false;
            failure(draftError);
            return;
          }
          event.site_status = "draft";
        }
        await renderExhibitionParticipants(event);
        message(
          "作品番号、確認状態、英語版情報を更新しました。写真展サイトは下書き状態です。",
        );
      }),
  );
  if (Number(event.exhibition_workflow_version) === 2) {
    await renderAdminCaptionsV2(event, root, visibleWorks);
    root.querySelector("#showV2Export")?.addEventListener("click", () =>
      renderAdminExhibitionExportV2(event, root),
    );
    root.querySelector("#showV2Actual")?.addEventListener("click", () =>
      renderAdminExhibitionActualV2(event, root),
    );
    root.querySelector("#showV2Archive")?.addEventListener("click", () =>
      renderAdminExhibitionArchiveV2(event, root),
    );
  }
}

async function renderAdminCaptionsV2(event, root, visibleWorks) {
  const ids = visibleWorks.map(({ work }) => work.id);
  if (!ids.length) return;
  const [{ data: captions, error }, { data: cases, error: caseError }, { data: derivations, error: derivationError }] = await Promise.all([
    supabase.from("exhibition_caption_working_data").select("*,exhibition_caption_submission_snapshots!exhibition_caption_current_submission_fk(*)").in("work_id", ids),
    supabase.from("exhibition_caption_workflow_cases").select("*").eq("event_id", event.id).order("requested_at", { ascending: false }),
    supabase.from("exhibition_caption_english_title_derivations").select("*").in("work_id", ids).order("version_no", { ascending: false }),
  ]);
  if (error) return failure(error);
  if (caseError) return failure(caseError);
  if (derivationError) return failure(derivationError);
  root.querySelectorAll(".admin-work-card").forEach((card) => {
    const caption = (captions || []).find((item) => item.work_id === card.dataset.workId),
      pending = (cases || []).find((item) => item.work_id === card.dataset.workId && item.case_type === "reedit" && item.state === "pending"),
      derived = (derivations || []).find((item) => item.work_id === card.dataset.workId);
    if (!caption) {
      card.insertAdjacentHTML("beforeend", '<div class="notice">キャプション未提出</div>');
      return;
    }
    const snap = caption.exhibition_caption_submission_snapshots,
      detail = snap || caption;
    card.insertAdjacentHTML("beforeend", `<section class="caption-admin-panel"><h4>Caption｜${esc(caption.state)}</h4><dl class="caption-details"><dt>表示名</dt><dd>${esc(detail.display_name || "")}</dd><dt>英語作品名</dt><dd>${esc(detail.english_title_mode === "self" ? detail.member_english_title : derived?.english_title || "主催者作成待ち")}</dd><dt>媒体</dt><dd>${esc(detail.medium || "")}</dd><dt>Camera / Lens / Film</dt><dd>${esc([detail.camera,detail.lens,detail.film].filter(Boolean).join(" / "))}</dd><dt>Description</dt><dd>${esc(detail.description_choice === "unnecessary" ? "不要" : detail.description_ja || "")}</dd><dt>Instagram QR</dt><dd>${esc(detail.instagram_qr_choice || "none")}</dd></dl><div class="actions">${caption.state === "submitted" ? '<button class="accept-caption">Captionを確認済みにする</button><button class="reject-caption danger">要修正にする</button>' : ""}${pending ? '<button class="permit-caption-reedit">再編集を許可</button><button class="reject-caption-reedit danger">再編集を却下</button>' : ""}${snap?.english_title_mode === "organizer" ? '<button class="derive-caption-title secondary">主催者英語作品名を登録</button>' : ""}</div></section>`);
    card.querySelector(".accept-caption")?.addEventListener("click", async () => { if (!confirm("表示中のCaption Snapshotを確認済みにしますか？")) return; const { error } = await supabase.rpc("admin_review_exhibition_caption_v2", { p_caption_snapshot_id: caption.current_submission_snapshot_id, p_result: "accepted", p_problem_fields: [], p_reason: "", p_individual_deadline: null }); if (error) return failure(error); renderExhibitionParticipants(event); });
    card.querySelector(".reject-caption")?.addEventListener("click", async () => { const fields = prompt("問題項目（カンマ区切り）", "other"), reason = prompt("要修正理由（必須）"); if (!fields || !reason) return; let deadline = null; if (Date.now() >= new Date(event.exhibition_caption_deadline).getTime()) { const value = prompt("個別期限をISO形式で入力してください。"); if (!value) return; deadline = new Date(value).toISOString(); } const { error } = await supabase.rpc("admin_review_exhibition_caption_v2", { p_caption_snapshot_id: caption.current_submission_snapshot_id, p_result: "rejected", p_problem_fields: fields.split(",").map((v) => v.trim()).filter(Boolean), p_reason: reason, p_individual_deadline: deadline }); if (error) return failure(error); renderExhibitionParticipants(event); });
    const decide = async (permit) => { const reason = prompt("判断理由（必須）"); if (!reason) return; let deadline = null; if (permit) { const value = prompt("再編集個別期限をISO形式で入力してください。"); if (!value) return; deadline = new Date(value).toISOString(); } const { error } = await supabase.rpc("admin_decide_exhibition_caption_reedit_v2", { p_case_id: pending.id, p_permit: permit, p_reason: reason, p_individual_deadline: deadline }); if (error) return failure(error); renderExhibitionParticipants(event); };
    card.querySelector(".permit-caption-reedit")?.addEventListener("click", () => decide(true));
    card.querySelector(".reject-caption-reedit")?.addEventListener("click", () => decide(false));
    card.querySelector(".derive-caption-title")?.addEventListener("click", async () => { const title = prompt("主催者作成の英語作品名（必須）"); if (!title) return; const reason = prompt("作成・変更理由（任意）", "") ?? null; if (reason === null) return; const { error } = await supabase.rpc("admin_set_exhibition_caption_organizer_title_v2", { p_caption_snapshot_id: caption.current_submission_snapshot_id, p_english_title: title, p_reason: reason }); if (error) return failure(error); renderExhibitionParticipants(event); });
  });
}

async function renderAdminExhibitionExportV2(event, root) {
  let panel = root.querySelector("#v2ExportAdmin");
  if (!panel) {
    root.insertAdjacentHTML("beforeend", '<section id="v2ExportAdmin" class="panel"></section>');
    panel = root.querySelector("#v2ExportAdmin");
  }
  panel.innerHTML = '<p class="muted">Export readinessを読み込んでいます…</p>';
  panel.scrollIntoView({ behavior: "smooth" });
  const [{ data: readiness, error }, { data: versions, error: historyError }, { data: publications, error: publicationError }, { data: publicationItems, error: publicationItemsError }, { data: publicationState, error: stateError }] = await Promise.all([
    supabase.rpc("admin_get_exhibition_export_readiness_v2", { p_event_id: event.id }),
    supabase.from("exhibition_export_versions").select("*").eq("event_id", event.id).order("version_no", { ascending: false }),
    supabase.from("exhibition_publication_versions").select("*").eq("event_id", event.id).order("version_no", { ascending: false }),
    supabase.from("exhibition_publication_items").select("publication_version_id,display_no,title_ja,publication_consent,image_state").eq("event_id", event.id).order("public_order"),
    supabase.from("events").select("current_publication_version_id,site_status,survey_enabled,survey_opens_at,survey_closes_at").eq("id", event.id).single(),
  ]);
  if (error) return failure(error);
  if (historyError) return failure(historyError);
  if (publicationError) return failure(publicationError);
  if (publicationItemsError) return failure(publicationItemsError);
  if (stateError) return failure(stateError);
  const rows = readiness || [], blocked = rows.filter((item) => !item.ready), latest = rows[0];
  panel.innerHTML = `<div class="entry-heading"><div><span class="tag">WORKFLOW V2 MASTER EXPORT</span><h2>キャプション・展示運営用Export</h2><p class="muted">Previewは履歴を作成しません。FINAL Exportだけが現在のLayout・Work・Captionを不変履歴として固定します。</p></div></div><div class="summary-strip"><span>対象 ${rows.length}点</span><span>Ready ${rows.length - blocked.length}点</span><span>Block ${blocked.length}点</span><span>Layout Finalization ${latest ? `v${latest.layout_finalization_version}` : "なし"}</span></div>${blocked.length ? `<div class="notice error"><strong>FINAL Exportを作成できません。</strong>${blocked.map((item) => `<p>Work ${esc(item.work_id)}：${esc((item.reasons || []).join("／"))}</p>`).join("")}</div>` : '<div class="notice">すべての対象WorkがExport可能です。</div>'}<div class="actions"><button id="finalizeV2Export" ${!rows.length || blocked.length ? "disabled" : ""}>FINAL Exportを作成</button></div><section><h3>不変Export履歴</h3><div class="stack">${(versions || []).length ? versions.map((version) => `<article class="admin-row"><div><strong>Export v${version.version_no}</strong><p class="muted">${fmt(version.created_at)}／Layout v${version.layout_finalization_version}／${esc(version.created_by)}</p><p>${esc(version.note || "")}</p></div><div class="actions"><button class="secondary inspect-v2-export" data-export-id="${version.id}">内容確認</button><button class="secondary download-v2-export" data-export-id="${version.id}" data-version="${version.version_no}">Master CSV</button><button class="secondary create-v2-publication" data-export-id="${version.id}" data-version="${version.version_no}">Publicationを作成</button></div></article>`).join("") : '<p class="muted">FINAL Exportはまだありません。</p>'}</div></section><section><h3>Public Publication履歴</h3><p class="muted">公開サイトとアンケートはCurrentに指定した不変Versionを参照します。Work UUIDが回答Identityです。</p><div class="stack">${(publications || []).length ? publications.map((publication) => { const items = (publicationItems || []).filter((item) => item.publication_version_id === publication.id), noImages = items.filter((item) => item.image_state === "no_image"); return `<article class="admin-row"><div><strong>Publication v${publication.version_no}${publication.id === publicationState.current_publication_version_id ? "（CURRENT）" : ""}</strong><p class="muted">Export ${esc(publication.source_export_version_id)}／${fmt(publication.created_at)}／全${items.length}点・NO IMAGE ${noImages.length}点</p>${noImages.length ? `<p>NO IMAGE：${noImages.map((item) => `No.${item.display_no} ${esc(item.title_ja)}`).join("／")}</p>` : ""}</div><button class="secondary set-current-publication" data-publication-id="${publication.id}" ${publication.id === publicationState.current_publication_version_id ? "disabled" : ""}>Currentに設定</button></article>`; }).join("") : '<p class="muted">Publicationはまだありません。</p>'}</div><div class="notice">公開状態：${esc(publicationState.site_status)}／Survey：${publicationState.survey_enabled ? `有効（${fmt(publicationState.survey_opens_at)}〜${fmt(publicationState.survey_closes_at)}）` : "無効"}</div>${publicationState.site_status === "published" ? '<div class="actions"><button id="endV2PublicSite" class="danger">一般公開を終了</button></div>' : ""}</section><div id="v2ExportDetail"></div>`;
  panel.querySelector("#finalizeV2Export")?.addEventListener("click", async () => {
    if (!confirm("現在のFINAL Layout・Work Snapshot・Caption Snapshotを新しい不変Export Versionとして固定しますか？")) return;
    const note = prompt("Exportメモ（任意）", "");
    if (note === null) return;
    const { data, error } = await supabase.rpc("admin_finalize_exhibition_export_v2", { p_event_id: event.id, p_note: note.trim() });
    if (error) return failure(error);
    await renderAdminExhibitionExportV2(event, root);
    message(`FINAL Export v${data.versionNo}を作成しました（${data.itemCount}点）。`);
  });
  const loadVersion = async (id) => {
    const { data, error } = await supabase.rpc("admin_get_exhibition_export_v2", { p_export_version_id: id });
    if (error) throw error;
    return data;
  };
  panel.querySelectorAll(".inspect-v2-export").forEach((button) => button.onclick = async () => {
    try {
      const data = await loadVersion(button.dataset.exportId), detail = panel.querySelector("#v2ExportDetail");
      detail.innerHTML = `<section><h3>Export v${data.version.version_no} の固定内容</h3><p class="muted">Layout Finalization ${esc(data.version.layout_finalization_id)}</p><div class="stack">${data.items.map((item) => `<article class="admin-row"><div><strong>No.${item.display_no} ${esc(item.title_ja)}</strong><p>${esc(item.display_name)}／${esc(item.effective_english_title)}</p><small>Work ${esc(item.work_id)}<br>Work Snapshot ${esc(item.work_submission_snapshot_id)}<br>Caption Snapshot ${esc(item.caption_submission_snapshot_id)}</small></div></article>`).join("")}</div></section>`;
    } catch (error) { failure(error); }
  });
  panel.querySelectorAll(".download-v2-export").forEach((button) => button.onclick = async () => {
    try {
      const { data: csv, error } = await supabase.rpc("admin_get_exhibition_export_csv_v2", { p_export_version_id: button.dataset.exportId });
      if (error) throw error;
      const url = URL.createObjectURL(new Blob([csv], { type: "text/csv;charset=utf-8" })), link = document.createElement("a");
      link.href = url;
      link.download = `${safeStorageFileName(event.exhibition_title || event.title, "exhibition")}_MasterExport_v${button.dataset.version}.csv`;
      document.body.appendChild(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 1000);
      message(`不変Export v${button.dataset.version}からMaster CSVを出力しました。`);
    } catch (error) { failure(error); }
  });
  panel.querySelectorAll(".create-v2-publication").forEach((button) => button.onclick = async () => {
    const { data: publicationReadiness, error } = await supabase.rpc("admin_get_exhibition_publication_readiness_v2", { p_export_version_id: button.dataset.exportId });
    if (error) return failure(error);
    const problems = (publicationReadiness || []).filter((item) => !item.ready);
    if (problems.length) return failure(new Error(problems.map((item) => `No.${item.display_no}: ${(item.reasons || []).join("／")}`).join("\n")));
    if (!confirm(`Export v${button.dataset.version}から不変Public Publicationを作成しますか？作成だけではCurrent公開されません。`)) return;
    const note = prompt("Publicationメモ（任意）", ""); if (note === null) return;
    const { data, error: createError } = await supabase.rpc("admin_finalize_exhibition_publication_v2", { p_export_version_id: button.dataset.exportId, p_note: note.trim() });
    if (createError) return failure(createError);
    await renderAdminExhibitionExportV2(event, root); message(`Publication v${data.versionNo}を作成しました。`);
  });
  panel.querySelectorAll(".set-current-publication").forEach((button) => button.onclick = async () => {
    if (!confirm("この不変Publication Versionを現在の一般公開・Survey表示に切り替えますか？")) return;
    const reason = prompt("切替理由（任意）", ""); if (reason === null) return;
    const { error } = await supabase.rpc("admin_set_current_exhibition_publication_v2", { p_publication_version_id: button.dataset.publicationId, p_reason: reason.trim() });
    if (error) return failure(error);
    await renderAdminExhibitionExportV2(event, root); message("Current Publicationを切り替えました。");
  });
  panel.querySelector("#endV2PublicSite")?.addEventListener("click", async () => {
    if (!confirm("一般公開とSurvey受付を終了しますか？不変Publicationと回答履歴は保持されます。")) return;
    const { error } = await supabase.rpc("admin_end_exhibition_site", { p_event_id: event.id });
    if (error) return failure(error);
    await renderAdminExhibitionExportV2(event, root); message("一般公開を終了しました。");
  });
}

async function renderAdminExhibitionActualV2(event, root) {
  let panel = root.querySelector("#v2ActualAdmin");
  if (!panel) {
    root.insertAdjacentHTML("beforeend", '<section id="v2ActualAdmin" class="panel"></section>');
    panel = root.querySelector("#v2ActualAdmin");
  }
  panel.innerHTML = '<p class="muted">Actual Exhibition Recordを読み込んでいます…</p>';
  panel.scrollIntoView({ behavior: "smooth" });
  const [finalsResult, versionsResult, itemsResult, wallsResult, worksResult, workSnapshotsResult, workReviewsResult, captionSnapshotsResult, captionReviewsResult] = await Promise.all([
    supabase.from("exhibition_layout_finalizations").select("*").eq("event_id", event.id).order("finalization_version", { ascending: false }),
    supabase.from("exhibition_actual_versions").select("*").eq("event_id", event.id).order("version_no", { ascending: false }),
    supabase.from("exhibition_actual_items").select("*").eq("event_id", event.id).order("display_no"),
    supabase.from("exhibition_walls").select("*").eq("venue_id", event.exhibition_venue_id).order("display_order"),
    supabase.from("exhibition_works").select("id,title").eq("event_id", event.id),
    supabase.from("exhibition_work_submission_snapshots").select("id,work_id,version_no").eq("event_id", event.id),
    supabase.from("exhibition_work_reviews").select("submission_snapshot_id,result").eq("result", "accepted"),
    supabase.from("exhibition_caption_submission_snapshots").select("id,work_id,version_no,work_submission_snapshot_id").eq("event_id", event.id),
    supabase.from("exhibition_caption_reviews").select("caption_snapshot_id,result").eq("result", "accepted"),
  ]);
  const failed = [finalsResult, versionsResult, itemsResult, wallsResult, worksResult, workSnapshotsResult, workReviewsResult, captionSnapshotsResult, captionReviewsResult].find((result) => result.error);
  if (failed) return failure(failed.error);
  const finals = finalsResult.data || [], versions = versionsResult.data || [], items = itemsResult.data || [], walls = wallsResult.data || [],
    works = Object.fromEntries((worksResult.data || []).map((work) => [work.id, work])),
    acceptedWorkSnapshots = new Set((workReviewsResult.data || []).map((review) => review.submission_snapshot_id)),
    acceptedCaptionSnapshots = new Set((captionReviewsResult.data || []).map((review) => review.caption_snapshot_id)),
    workSnapshots = workSnapshotsResult.data || [], captionSnapshots = captionSnapshotsResult.data || [],
    draft = versions.find((version) => version.state === "draft"), draftItems = draft ? items.filter((item) => item.actual_version_id === draft.id) : [];
  let actualBlockers = [];
  if (draft) {
    const { data, error } = await supabase.rpc("admin_get_exhibition_actual_readiness_v2", { p_actual_version_id: draft.id });
    if (error) return failure(error);
    actualBlockers = (data || []).filter((item) => !item.ready);
  }
  panel.innerHTML = `<div class="entry-heading"><div><span class="tag">WORKFLOW V2 ACTUAL</span><h2>Actual Exhibition Record</h2><p class="muted"><strong>Plan</strong>は展示予定、<strong>Actual</strong>は会場で実際に展示した事実です。自動確定されません。</p></div></div>${!draft ? `<section><h3>Actual Draftを作成</h3><label>基準となる確定Layout<select id="actualSourceFinal"><option value="">選択してください</option>${finals.map((finalization) => `<option value="${finalization.id}">Layout Finalization v${finalization.finalization_version}（${fmt(finalization.finalized_at)}）</option>`).join("")}</select></label><div class="actions"><button id="initializeActual" ${finals.length ? "" : "disabled"}>PlanからActual Draftを作成</button></div></section>` : `<section><div class="section-head"><h3>Actual Draft v${draft.version_no}</h3><span class="status">未確認 ${draftItems.filter((item) => item.actual_state === "unconfirmed").length}点</span></div><p class="muted">Source Plan：${esc(draft.source_layout_finalization_id)}${draft.correction_of_id ? `／訂正元：${esc(draft.correction_of_id)}` : ""}</p><div class="stack">${draftItems.map((item) => { const work = works[item.work_id] || {}, plannedWall = walls.find((wall) => wall.id === item.planned_wall_id), availableWorkSnapshots = workSnapshots.filter((snapshot) => snapshot.work_id === item.work_id && (snapshot.id === item.work_submission_snapshot_id || acceptedWorkSnapshots.has(snapshot.id))), compatibleCaptions = captionSnapshots.filter((snapshot) => snapshot.work_id === item.work_id && acceptedCaptionSnapshots.has(snapshot.id)); return `<form class="actual-item-card admin-row" data-item-id="${item.id}"><div><strong>No.${item.display_no} ${esc(work.title || "")}</strong><p><span class="tag">PLAN</span> ${esc(plannedWall?.name || item.planned_wall_id)}／左 ${item.planned_x_mm}mm／床から上端 ${item.planned_top_from_floor_mm}mm</p><label>Actual状態<select name="actual_state"><option value="unconfirmed" ${item.actual_state === "unconfirmed" ? "selected" : ""}>未確認</option><option value="exhibited" ${item.actual_state === "exhibited" ? "selected" : ""}>実際に展示</option><option value="not_exhibited" ${item.actual_state === "not_exhibited" ? "selected" : ""}>展示しなかった</option></select></label><label>実展示Work Snapshot<select name="work_snapshot">${availableWorkSnapshots.map((snapshot) => `<option value="${snapshot.id}" ${snapshot.id === item.work_submission_snapshot_id ? "selected" : ""}>Work Snapshot v${snapshot.version_no}｜${snapshot.id.slice(0, 8)}</option>`).join("")}</select></label><label>対応Caption Snapshot<select name="caption_snapshot"><option value="">なし（例外理由が必要）</option>${compatibleCaptions.map((snapshot) => `<option value="${snapshot.id}" data-work-snapshot="${snapshot.work_submission_snapshot_id}" ${snapshot.id === item.caption_submission_snapshot_id ? "selected" : ""}>Caption v${snapshot.version_no}｜${snapshot.id.slice(0, 8)}</option>`).join("")}</select></label></div><div class="form-grid"><label>Actual壁面<select name="wall_id"><option value="">選択</option>${walls.map((wall) => `<option value="${wall.id}" ${wall.id === item.actual_wall_id ? "selected" : ""}>${esc(wall.name)}</option>`).join("")}</select></label><label>左端 mm<input name="x_mm" type="number" min="0" step="0.01" value="${item.actual_x_mm ?? ""}"></label><label>床から上端 mm<input name="top_mm" type="number" min="0" step="0.01" value="${item.actual_top_from_floor_mm ?? ""}"></label><label>重なり順<input name="z_order" type="number" min="0" value="${item.actual_z_order ?? 0}"></label><label class="full"><input name="caption_exception" type="checkbox" ${item.caption_exception ? "checked" : ""}>Captionなしの例外として記録</label><label class="full">理由・現場メモ<textarea name="note" rows="2">${esc(item.note || "")}</textarea></label><button>Actualを保存</button></div></form>`; }).join("")}</div><div class="actions"><button id="finalizeActual" ${draftItems.some((item) => item.actual_state === "unconfirmed") ? "disabled" : ""}>ActualをFINAL確定</button></div></section>`}<section><h3>確定済みActual履歴</h3><div class="stack">${versions.filter((version) => version.state === "finalized").map((version) => { const versionItems = items.filter((item) => item.actual_version_id === version.id); return `<article class="admin-row"><div><strong>Actual v${version.version_no}</strong><p>実展示 ${versionItems.filter((item) => item.actual_state === "exhibited").length}点／非展示 ${versionItems.filter((item) => item.actual_state === "not_exhibited").length}点</p><small>Source Plan ${esc(version.source_layout_finalization_id)}／${fmt(version.finalized_at)}</small></div><button class="secondary correct-actual" data-version-id="${version.id}" data-final-id="${version.source_layout_finalization_id}">訂正版を作成</button></article>`; }).join("") || '<p class="muted">確定済みActualはありません。</p>'}</div></section>`;
  if (actualBlockers.length) {
    panel.querySelector(".entry-heading").insertAdjacentHTML("afterend", `<div class="notice error"><strong>FINAL確定できません。</strong>${actualBlockers.map((item) => `<p>No.${item.display_no}：${esc((item.reasons || []).join("／"))}</p>`).join("")}</div>`);
    panel.querySelector("#finalizeActual")?.setAttribute("disabled", "");
  }
  panel.querySelector("#initializeActual")?.addEventListener("click", async () => {
    const finalizationId = panel.querySelector("#actualSourceFinal").value;
    if (!finalizationId || !confirm("PlanをActual Draftへ取り込みますか？全作品は未確認のまま作成されます。")) return;
    const { error } = await supabase.rpc("admin_initialize_exhibition_actual_v2", { p_layout_finalization_id: finalizationId, p_correction_of_id: null, p_reason: "", p_note: "" });
    if (error) return failure(error); await renderAdminExhibitionActualV2(event, root); message("Actual Draftを作成しました。各作品の実展示状態を確認してください。");
  });
  panel.querySelectorAll(".actual-item-card").forEach((form) => {
    const updateCaptions = () => { const workSnapshot = form.work_snapshot.value; [...form.caption_snapshot.options].forEach((option) => { if (option.value) option.hidden = option.dataset.workSnapshot !== workSnapshot; }); if (form.caption_snapshot.selectedOptions[0]?.hidden) form.caption_snapshot.value = ""; };
    form.work_snapshot.onchange = updateCaptions; updateCaptions();
    form.onsubmit = async (submit) => { submit.preventDefault(); const state = form.actual_state.value, exhibited = state === "exhibited";
      const { error } = await supabase.rpc("admin_update_exhibition_actual_item_v2", { p_item_id: form.dataset.itemId, p_actual_state: state,
        p_actual_wall_id: exhibited ? form.wall_id.value || null : null, p_actual_x_mm: exhibited ? Number(form.x_mm.value) : null,
        p_actual_top_from_floor_mm: exhibited ? Number(form.top_mm.value) : null, p_actual_z_order: exhibited ? Number(form.z_order.value) : null,
        p_work_snapshot_id: form.work_snapshot.value, p_caption_snapshot_id: form.caption_snapshot.value || null,
        p_caption_exception: exhibited && form.caption_exception.checked, p_note: form.note.value.trim() });
      if (error) return failure(error); await renderAdminExhibitionActualV2(event, root); message("Actual Itemを保存しました。"); };
  });
  panel.querySelector("#finalizeActual")?.addEventListener("click", async () => { if (!confirm("このActualをFINAL確定しますか？確定後は編集できません。")) return; const reason = prompt("確定メモ（任意）", ""); if (reason === null) return; const { error } = await supabase.rpc("admin_finalize_exhibition_actual_v2", { p_actual_version_id: draft.id, p_reason: reason.trim() }); if (error) return failure(error); await renderAdminExhibitionActualV2(event, root); message("Actual Exhibition Recordを確定しました。"); });
  panel.querySelectorAll(".correct-actual").forEach((button) => button.onclick = async () => { const reason = prompt("事実訂正理由（必須）"); if (!reason) return; const { error } = await supabase.rpc("admin_initialize_exhibition_actual_v2", { p_layout_finalization_id: button.dataset.finalId, p_correction_of_id: button.dataset.versionId, p_reason: reason, p_note: "" }); if (error) return failure(error); await renderAdminExhibitionActualV2(event, root); message("訂正用Actual Draftを作成しました。元Versionは保持されています。"); });
}

async function renderAdminExhibitionArchiveV2(event, root) {
  let panel = root.querySelector("#v2ArchiveAdmin");
  if (!panel) { root.insertAdjacentHTML("beforeend", '<section id="v2ArchiveAdmin" class="panel"></section>'); panel = root.querySelector("#v2ArchiveAdmin"); }
  panel.innerHTML = '<p class="muted">Archiveを読み込んでいます…</p>'; panel.scrollIntoView({ behavior: "smooth" });
  const [actualResult, versionsResult, itemsResult, stateResult] = await Promise.all([
    supabase.from("exhibition_actual_versions").select("*").eq("event_id", event.id).eq("state", "finalized").order("version_no", { ascending: false }),
    supabase.from("exhibition_archive_versions").select("*").eq("event_id", event.id).order("version_no", { ascending: false }),
    supabase.from("exhibition_archive_items").select("*").eq("event_id", event.id).order("display_no"),
    supabase.from("events").select("current_archive_version_id").eq("id", event.id).single(),
  ]);
  const failed = [actualResult, versionsResult, itemsResult, stateResult].find((result) => result.error); if (failed) return failure(failed.error);
  const actuals = actualResult.data || [], versions = versionsResult.data || [], items = itemsResult.data || [], currentId = stateResult.data.current_archive_version_id;
  panel.innerHTML = `<div class="entry-heading"><div><span class="tag">WORKFLOW V2 ARCHIVE</span><h2>不変Exhibition Archive</h2><p class="muted">確定Actualで「実際に展示」と記録された作品だけをArchiveします。Plan・Publication・Surveyは所属根拠にしません。</p></div></div><section><h3>確定ActualからArchiveを作成</h3><div class="stack">${actuals.map((actual) => { const archived = versions.some((version) => version.source_actual_version_id === actual.id); return `<article class="admin-row"><div><strong>Actual v${actual.version_no}</strong><small>${fmt(actual.finalized_at)}</small></div><button class="create-archive" data-actual-id="${actual.id}" ${archived ? "disabled" : ""}>${archived ? "Archive作成済み" : "readiness確認・FINAL作成"}</button></article>`; }).join("") || '<p class="muted">確定Actualがありません。</p>'}</div></section><section><h3>Archive履歴</h3><div class="stack">${versions.map((version) => { const list = items.filter((item) => item.archive_version_id === version.id); return `<article class="admin-row"><div><strong>Archive v${version.version_no}${version.id === currentId ? "（CURRENT）" : ""}</strong><p>実展示作品 ${list.length}点：${list.map((item) => `No.${item.display_no}`).join("、")}</p><small>Actual ${esc(version.source_actual_version_id)}／${fmt(version.finalized_at)}</small></div><button class="set-current-archive secondary" data-id="${version.id}" ${version.id === currentId ? "disabled" : ""}>Currentに設定</button></article>`; }).join("") || '<p class="muted">Archiveはまだありません。</p>'}</div></section>`;
  panel.querySelectorAll(".create-archive").forEach((button) => button.onclick = async () => { const { data: readiness, error } = await supabase.rpc("admin_get_exhibition_archive_readiness_v2", { p_actual_version_id: button.dataset.actualId }); if (error) return failure(error); const blocked = (readiness || []).filter((item) => !item.ready); if (blocked.length) return failure(new Error(blocked.map((item) => `No.${item.display_no}: ${(item.reasons || []).join("／")}`).join("\n"))); if (!confirm(`${readiness.length}点を不変ArchiveとしてFINAL作成しますか？`)) return; const note = prompt("Archiveメモ（任意）", ""); if (note === null) return; const result = await supabase.rpc("admin_finalize_exhibition_archive_v2", { p_actual_version_id: button.dataset.actualId, p_note: note.trim() }); if (result.error) return failure(result.error); await renderAdminExhibitionArchiveV2(event, root); message(`Archive v${result.data.versionNo}を作成しました。`); });
  panel.querySelectorAll(".set-current-archive").forEach((button) => button.onclick = async () => { if (!confirm("このArchive VersionをCurrentにしますか？")) return; const reason = prompt("切替理由（任意）", ""); if (reason === null) return; const { error } = await supabase.rpc("admin_set_current_exhibition_archive_v2", { p_archive_version_id: button.dataset.id, p_reason: reason.trim() }); if (error) return failure(error); await renderAdminExhibitionArchiveV2(event, root); message("Current Archiveを切り替えました。"); });
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

function renderEditor(event, initialGenre = "meeting") {
  const root = document.querySelector("#editor");
  root.classList.remove("hidden");
  root.innerHTML = `<h2>${event ? "予定を編集" : "新規予定"}</h2><form id="eventForm" class="form-grid">
    <label class="full">予定名（必須）<input name="title" value="${esc(event?.title || "")}" required></label>
    <label>ジャンル<select name="genre"><option value="meeting">全体会</option><option value="camp">合宿</option><option value="exhibition">写真展</option></select></label>
    <label id="subtypeField">全体会種別<select name="subtype"><option value="shooting">撮影会</option><option value="dining">お食事会</option></select></label>
    <label>開始日時<input type="datetime-local" name="starts_at"></label><label>終了日時<input type="datetime-local" name="ends_at"></label>
    <label>申込締切（保存時必須）<input type="datetime-local" name="registration_deadline"></label>
    <label>場所<input name="place" value="${esc(event?.place || "")}"></label><label>企画幹部の連絡先<input name="contact" value="${esc(event?.contact || "")}"></label>
    <label class="full">必要事項<textarea name="details" rows="4">${esc(event?.details || "")}</textarea></label>
    <section id="participationLimitFields" class="full conditional-fields"><h3>参加条件（任意）</h3><label><input type="checkbox" name="participant_limit_enabled">参加人数に上限を設ける</label><label id="participantLimitInput" class="hidden">参加上限人数<input type="number" name="participant_limit" min="1" step="1"></label><fieldset><legend>参加可能学年</legend><p class="muted">何も選択しない場合は全学年が対象です。</p><div class="grade-options">${["B1", "B2", "B3", "B4", "M1", "M2", "D1", "D2", "D3"].map((grade) => `<label><input type="checkbox" name="eligible_grades" value="${grade}">${grade}</label>`).join("")}</div></fieldset></section>
    <section id="cancellationFields" class="full conditional-fields"><h3>キャンセル・キャンセル待ち</h3><label><input type="checkbox" name="self_cancellation_enabled">申込締切まで本人キャンセルを許可</label><label><input type="checkbox" name="waitlist_enabled">定員到達後にキャンセル待ちを受け付ける</label><div id="waitlistDeadlineFields" class="form-grid nested-fields"><label>キャンセル待ち受付期限<input type="datetime-local" name="waitlist_registration_deadline"></label><label>新規繰上げ期限<input type="datetime-local" name="waitlist_promotion_deadline"></label><label>繰上げ回答最終期限<input type="datetime-local" name="waitlist_response_final_deadline"></label><label>回答猶予（時間）<input type="number" name="waitlist_response_hours" min="1" max="168" value="24"></label></div></section>
    <section id="shootingFields" class="full conditional-fields"><label><input type="checkbox" name="camera_enabled">貸出カメラを受付（上限3台）</label><label><input type="checkbox" name="disposable_enabled">写るんですを受付</label></section>
    <section id="feeFields" class="full conditional-fields"><label><input type="checkbox" name="fee_enabled">費用を表示する</label><div id="feeAmountFields" class="form-grid nested-fields hidden"><label>費用<input type="number" name="fee" min="0"></label><label><input type="checkbox" name="payment_deadline_enabled">支払期限を表示する</label><label id="paymentDeadlineField" class="hidden">支払期限<input type="datetime-local" name="payment_deadline"></label></div></section>
    <section id="exhibitionFields" class="full form-grid conditional-fields">
      <label>写真展タイトル<input name="exhibition_title"></label><label>出展可能作品数<input type="number" name="max_works" min="1"></label>
      <label>最低シフト人数<input type="number" name="min_shift_people" min="1"></label><label class="full">シフト枠（1行1枠）<textarea name="shift_slots_text" rows="5" placeholder="8月23日 15:00〜17:00"></textarea></label>
      <fieldset class="full public-site-fields"><legend>一般向け写真展サイト</legend><p class="muted">ここで保存した内容は「写真展サイトを公開」を押すまで一般公開されません。保存し直すと安全のためサイトは下書きへ戻ります。</p><div class="form-grid">
        <label class="full">写真展キー<input name="exhibition_key" maxlength="100" placeholder="例：2026-winter"><small>半角数字・小文字・ハイフン。公開URLの識別子になります。</small></label>
        <h4 class="full language-field-heading">日本語</h4><label>サイト用タイトル<input name="site_title" maxlength="200"></label><label>サイト用会場補足（任意）<input name="site_additional_info" maxlength="3000" placeholder="例：EAST館 2階 202"></label>
        <label class="full">キャッチコピー（任意）<input name="site_catchphrase" maxlength="300"></label><label class="full">紹介文<textarea name="site_description" maxlength="5000" rows="6"></textarea></label>
        <h4 class="full language-field-heading">English（すべて任意・空欄は日本語を表示）</h4><label>Title<input name="site_title_en" maxlength="200"></label><label>Venue<input name="place_en" maxlength="500"></label>
        <label class="full">Additional venue information<input name="site_additional_info_en" maxlength="3000"></label><label class="full">Catchphrase<input name="site_catchphrase_en" maxlength="300"></label><label class="full">Description<textarea name="site_description_en" maxlength="5000" rows="6"></textarea></label>
        <label class="full"><input type="checkbox" name="survey_enabled">アンケート付き作品一覧で回答を受け付ける</label><div id="surveyPeriodFields" class="form-grid full nested-fields hidden"><label>アンケート受付開始<input type="datetime-local" name="survey_opens_at"></label><label>アンケート受付終了<input type="datetime-local" name="survey_closes_at"></label></div>
        <label class="full">DM画像（JPEG・PNG・WebP、10MBまで）<input type="file" name="dm_image" accept="image/jpeg,image/png,image/webp"><small id="registeredDmImage"></small></label>
      </div></fieldset>
    </section>
    <div class="actions full"><button type="button" id="draft" class="secondary">一時保存</button><button type="submit" id="saveEvent">保存</button></div>
  </form>`;
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
  form.genre.value = event?.genre || initialGenre;
  form.subtype.value = event?.subtype || "shooting";
  form.starts_at.value = local(event?.starts_at);
  form.ends_at.value = local(event?.ends_at);
  form.registration_deadline.value = local(event?.registration_deadline);
  form.waitlist_registration_deadline.value = local(event?.waitlist_registration_deadline);
  form.waitlist_promotion_deadline.value = local(event?.waitlist_promotion_deadline);
  form.waitlist_response_final_deadline.value = local(event?.waitlist_response_final_deadline);
  form.waitlist_response_hours.value = event?.waitlist_response_hours || 24;
  form.payment_deadline.value = local(event?.payment_deadline);
  form.survey_opens_at.value = local(event?.survey_opens_at);
  form.survey_closes_at.value = local(event?.survey_closes_at);
  for (const name of [
    "exhibition_title",
    "exhibition_key",
    "site_title",
    "site_catchphrase",
    "site_description",
    "site_title_en",
    "site_catchphrase_en",
    "site_description_en",
    "place_en",
    "site_additional_info",
    "site_additional_info_en",
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
  form.survey_enabled.checked = Boolean(event?.survey_enabled);
  form.participant_limit_enabled.checked = event?.participant_limit != null;
  form.participant_limit.value = event?.participant_limit || "";
  form.self_cancellation_enabled.checked = event?.self_cancellation_enabled ?? true;
  form.waitlist_enabled.checked = event?.waitlist_enabled ?? true;
  for (const checkbox of form.querySelectorAll("[name=eligible_grades]"))
    checkbox.checked = (event?.eligible_grades || []).includes(checkbox.value);
  form.shift_slots_text.value = (event?.shift_slots || [])
    .map((slot) => (typeof slot === "string" ? slot : slot.label))
    .join("\n");
  document.querySelector("#registeredDmImage").textContent = event?.dm_image_path
    ? `登録済み：${event.dm_image_path.split("/").pop()}`
    : "未登録";
  const existingSlots = event?.shift_slots || [],
    conditions = () => {
      const genre = form.genre.value,
        shooting = genre === "meeting" && form.subtype.value === "shooting",
        feeCapable =
          genre === "camp" ||
          (genre === "meeting" && form.subtype.value === "dining"),
        feeEnabled = feeCapable && form.fee_enabled.checked,
        deadlineEnabled = feeEnabled && form.payment_deadline_enabled.checked,
        surveyEnabled = genre === "exhibition" && form.survey_enabled.checked;
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
      document
        .querySelector("#surveyPeriodFields")
        .classList.toggle("hidden", !surveyEnabled);
      document
        .querySelector("#participationLimitFields")
        .classList.toggle("hidden", genre === "exhibition");
      document
        .querySelector("#participantLimitInput")
        .classList.toggle(
          "hidden",
          genre === "exhibition" || !form.participant_limit_enabled.checked,
        );
      const waitlistActive = genre !== "exhibition" && form.participant_limit_enabled.checked && form.waitlist_enabled.checked;
      document.querySelector("#cancellationFields").classList.toggle("hidden", genre === "exhibition");
      document.querySelector("#waitlistDeadlineFields").classList.toggle("hidden", !waitlistActive);
    };
  const snapshot = () =>
      JSON.stringify({
        ...Object.fromEntries(new FormData(form)),
        dm_image: form.dm_image.files[0]?.name || "",
      }),
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
      const dmFile = form.dm_image.files[0],
        exhibitionKey = values.exhibition_key.trim();
      if (
        values.genre !== "exhibition" &&
        form.participant_limit_enabled.checked &&
        (!values.participant_limit || Number(values.participant_limit) < 1)
      )
        throw new Error("参加上限人数は1名以上で入力してください。");
      if (
        values.genre === "exhibition" &&
        exhibitionKey &&
        !/^[0-9]{4}-[a-z0-9]+(?:-[a-z0-9]+)*$/.test(exhibitionKey)
      )
        throw new Error(
          "写真展キーは、2026-winter のように半角数字・小文字・ハイフンで入力してください。",
        );
      if (dmFile && !exhibitionKey)
        throw new Error("DM画像を登録する場合は写真展キーが必要です。");
      if (
        values.genre === "exhibition" &&
        event?.exhibition_key &&
        event.exhibition_key !== exhibitionKey &&
        event.dm_image_path &&
        !dmFile
      )
        throw new Error(
          "写真展キーを変更する場合は、DM画像も選択し直してください。",
        );
      if (dmFile && (!publicImageExtension(dmFile) || dmFile.size > 10 * 1024 * 1024))
        throw new Error("DM画像はJPEG・PNG・WebPのいずれか、10MB以下にしてください。");
      if (
        values.survey_opens_at &&
        values.survey_closes_at &&
        values.survey_closes_at <= values.survey_opens_at
      )
        throw new Error("アンケート受付終了は受付開始より後にしてください。");
      if (
        values.genre === "exhibition" &&
        form.survey_enabled.checked &&
        (!values.survey_opens_at || !values.survey_closes_at)
      )
        throw new Error(
          "アンケートを受け付ける場合は、受付開始と受付終了を入力してください。",
        );
      if (!draft) {
        if (!values.starts_at || !values.place.trim() || !values.contact.trim())
          throw new Error("保存には日時、場所、企画幹部の連絡先が必要です。");
        if (!values.registration_deadline)
          throw new Error("保存には申込締切が必要です。");
        if (values.registration_deadline > values.starts_at)
          throw new Error("申込締切は開始日時以前にしてください。");
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
          registration_deadline: asIso(values.registration_deadline),
          place: values.place.trim(),
          contact: values.contact.trim(),
          details: values.details.trim(),
          participant_limit:
            values.genre !== "exhibition" &&
            form.participant_limit_enabled.checked
              ? Number(values.participant_limit)
              : null,
          eligible_grades:
            values.genre !== "exhibition"
              ? [...form.querySelectorAll("[name=eligible_grades]:checked")].map(
                  (checkbox) => checkbox.value,
                )
              : [],
          self_cancellation_enabled: values.genre !== "exhibition" && form.self_cancellation_enabled.checked,
          waitlist_enabled: values.genre !== "exhibition" && form.participant_limit_enabled.checked && form.waitlist_enabled.checked,
          waitlist_registration_deadline: values.genre !== "exhibition" && form.participant_limit_enabled.checked && form.waitlist_enabled.checked ? asIso(values.waitlist_registration_deadline) : null,
          waitlist_promotion_deadline: values.genre !== "exhibition" && form.participant_limit_enabled.checked && form.waitlist_enabled.checked ? asIso(values.waitlist_promotion_deadline) : null,
          waitlist_response_final_deadline: values.genre !== "exhibition" && form.participant_limit_enabled.checked && form.waitlist_enabled.checked ? asIso(values.waitlist_response_final_deadline) : null,
          waitlist_response_hours: Number(values.waitlist_response_hours || 24),
          fee_enabled: feeEnabled,
          fee: feeEnabled ? Number(values.fee || 0) : 0,
          payment_deadline_enabled: deadlineEnabled,
          payment_deadline: deadlineEnabled
            ? asIso(values.payment_deadline)
            : null,
          exhibition_title:
            values.genre === "exhibition" ? values.exhibition_title.trim() : "",
          exhibition_key:
            values.genre === "exhibition" ? exhibitionKey || null : null,
          site_title:
            values.genre === "exhibition" ? values.site_title.trim() : "",
          site_catchphrase:
            values.genre === "exhibition" ? values.site_catchphrase.trim() : "",
          site_description:
            values.genre === "exhibition" ? values.site_description.trim() : "",
          site_title_en:
            values.genre === "exhibition" ? values.site_title_en.trim() : "",
          site_catchphrase_en:
            values.genre === "exhibition"
              ? values.site_catchphrase_en.trim()
              : "",
          site_description_en:
            values.genre === "exhibition"
              ? values.site_description_en.trim()
              : "",
          place_en:
            values.genre === "exhibition" ? values.place_en.trim() : "",
          site_additional_info:
            values.genre === "exhibition"
              ? values.site_additional_info.trim()
              : "",
          site_additional_info_en:
            values.genre === "exhibition"
              ? values.site_additional_info_en.trim()
              : "",
          survey_opens_at:
            values.genre === "exhibition" ? asIso(values.survey_opens_at) : null,
          survey_closes_at:
            values.genre === "exhibition" ? asIso(values.survey_closes_at) : null,
          survey_enabled:
            values.genre === "exhibition" && form.survey_enabled.checked,
          site_status:
            values.genre === "exhibition" ? "draft" : event?.site_status || "draft",
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
      const { data: savedEvent, error } = await query.select("id").single();
      if (error) throw new Error(`予定を保存できませんでした：${error.message}`);
      if (dmFile) {
        const workflowV2 = Number(event?.exhibition_workflow_version) === 2,
          dmPath = workflowV2
            ? `${exhibitionKey}/dm-${crypto.randomUUID()}.${publicImageExtension(dmFile)}`
            : `${exhibitionKey}/dm.${publicImageExtension(dmFile)}`,
          { error: uploadError } = await supabase.storage
            .from("exhibition-public")
            .upload(dmPath, dmFile, {
              upsert: !workflowV2,
              contentType: dmFile.type,
              cacheControl: "3600",
            });
        if (uploadError)
          throw new Error(`DM画像を保存できませんでした：${uploadError.message}`);
        const { error: pathError } = await supabase
          .from("events")
          .update({ dm_image_path: dmPath })
          .eq("id", savedEvent.id);
        if (pathError)
          throw new Error(`DM画像の登録情報を保存できませんでした：${pathError.message}`);
      }
      adminGenreTab = values.genre;
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

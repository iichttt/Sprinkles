const SERVER = "https://localhost:3133";
const minimumBuildNumber = 132;

const CHECK_THROTTLE_MS = 1000; // Only check once per second

const API = browser;

let lastChecksum = null;
let lastCheckTime = 0;

// host -> CSS for that host, cleared whenever the user's files change.
const cssByHost = new Map();
// "tabId:frameId" -> { host, css } currently injected there, so it can be removed again.
// Mirrored into storage.session because this worker is torn down after ~30s idle: without it a
// restarted worker forgets what it injected, can never removeCSS it, and every later edit stacks
// another copy onto long-lived tabs.
const injected = new Map();
// "tabId:frameId" -> promise, so two applyStyles for the same frame cannot interleave across
// their awaits and both insert.
const inFlight = new Map();

const injectedReady = (async () => {
  try {
    const stored = await API.storage.session.get("injected");
    for (const [key, value] of Object.entries(stored.injected || {})) {
      if (!injected.has(key)) injected.set(key, value);
    }
  } catch (e) {
    // storage.session is unavailable; fall back to in-memory only.
  }
})();

let pendingPersist = null;

function persistInjected() {
  // One write per tick, not one per mutation: applyStylesNow persists up to three times per
  // frame and refreshStyles runs over every frame at once, so writing each time would restringify
  // every sheet's full CSS on every step. The snapshot is taken after the caller mutated the map,
  // so joining a pending write still records that mutation. Never rejects - applyStylesNow awaits
  // this between forgetting a sheet and removing it, and a failed write must not abort the
  // cleanup half-done.
  if (!pendingPersist) {
    pendingPersist = Promise.resolve().then(() => {
      pendingPersist = null;
      try {
        return Promise.resolve(
          API.storage.session.set({ injected: Object.fromEntries(injected) }),
        ).catch(() => {});
      } catch (e) {
        return undefined;
      }
    });
  }

  return pendingPersist;
}

API.runtime.onInstalled.addListener(async () => {
  await reload();
});

API.action.onClicked.addListener(async () => {
  await reload();
});

API.permissions.onAdded.addListener(async (permissions) => {
  if (permissions.permissions.includes("userScripts")) {
    await reload();
  }
});

API.permissions.onRemoved.addListener(async (permissions) => {
  if (permissions.permissions.includes("userScripts")) {
    await API.userScripts.unregister();
  }
});

API.webNavigation.onCommitted.addListener(async (details) => {
  // A commit means a brand new document, so nothing we injected before is still there. The
  // clearing happens inside applyStyles' per-frame chain rather than here, so it cannot land in
  // the middle of a refresh that is already running for the same frame.
  await applyStyles(details.tabId, details.frameId, details.url, { fresh: true });
});

API.webNavigation.onBeforeNavigate.addListener(async (details) => {
  // Skip iframe navigations
  if (details.frameId !== 0) return;

  // Only check once per CHECK_THROTTLE_MS (1s)
  const now = Date.now();
  if (now - lastCheckTime < CHECK_THROTTLE_MS) return;

  lastCheckTime = now;
  await checkForUpdates();
});

API.tabs.onRemoved.addListener(async (tabId) => {
  await injectedReady;

  let changed = false;
  for (const key of [...injected.keys()]) {
    if (key.startsWith(`${tabId}:`)) changed = injected.delete(key) || changed;
  }

  if (changed) await persistInjected();
});

async function checkForUpdates() {
  try {
    const res = await fetch(`${SERVER}/v4/checksum.json`);
    const { checksum } = await res.json();

    if (lastChecksum === null) {
      lastChecksum = checksum;
      return;
    }

    if (checksum !== lastChecksum) {
      console.log("Scripts changed, reloading...");
      lastChecksum = checksum;
      await reload();
    }
  } catch (e) {
    console.error("Failed to check for updates:", e);
  }
}

async function reload() {
  cssByHost.clear();

  const version = await fetchVersion();
  console.log(`Version: ${version.version}, build: ${version.build}`);

  if (version.build < minimumBuildNumber) {
    console.log("Version mismatch");

    API.action.setBadgeText({ text: "!" });
    API.action.setBadgeBackgroundColor({ color: "#cc0000" });
    API.action.setTitle({ title: "Please upgrade Sprinkles to continue" });
    API.action.onClicked.addListener(() => {
      API.tabs.create({
        url: `https://getsprinkles.app/troubleshooting?version=${version.version}&build=${version.build}`,
      });
    });

    return;
  }

  const { global, domains } = await fetchDomains();

  // Styles don't need the userScripts permission, so apply them before asking for it.
  await refreshStyles();

  if (!(await API.permissions.contains({ permissions: ["userScripts"] }))) {
    console.log("userScripts permission not granted");
    API.runtime.openOptionsPage();
    return;
  }

  await API.userScripts.unregister();

  if (global.enabled && global.js) {
    await register("global", global.matches, await fetchScript("global"));
  }

  await Promise.all(
    domains
      .filter((domain) => domain.js)
      .map(async (domain) => {
        console.log(`Fetching user script for ${domain.id}`);
        await register(domain.id, domain.matches, await fetchScript(domain.id));
      }),
  );
}

async function fetchVersion() {
  try {
    const res = await fetch(`${SERVER}/version.json`);
    return res.json();
  } catch (e) {
    console.error(e);
    return { version: "unknown", build: 0 };
  }
}

async function fetchDomains() {
  try {
    const res = await fetch(`${SERVER}/v4/domains.json`);
    return res.json();
  } catch (e) {
    console.error(e);
    return { global: { enabled: false }, domains: [] };
  }
}

async function fetchScript(domain) {
  const res = await fetch(`${SERVER}/v4/js/${encodeURIComponent(domain)}.js`);
  return res.text();
}

async function register(domain, matches, code) {
  if (!code.trim()) return;

  console.log(`Registering user script for ${domain}`);
  await API.userScripts.register([
    {
      id: `user-script-${domain}`,
      matches,
      js: [{ code }],
      runAt: "document_idle",
      world: "MAIN",
    },
  ]);
}

// Styles are handed to the browser instead of being built into a <style> element by page-world
// JavaScript. Extension-injected CSS is exempt from the page's Content Security Policy, so
// @font-face and background images keep working on sites that lock down font-src/style-src.
function applyStyles(tabId, frameId, url, { fresh = false } = {}) {
  const key = `${tabId}:${frameId}`;
  // Chain onto whatever is already running for this frame. stylesFor() awaits the network, and
  // a checksum-triggered refreshStyles() racing a navigation would otherwise have both callers
  // read "nothing injected", both insert, and only the second be remembered - leaving a sheet
  // behind that removeCSS is never told about.
  const previous = inFlight.get(key) || Promise.resolve();
  const current = previous
    .catch(() => {})
    .then(() => applyStylesNow(key, tabId, frameId, url, fresh));

  inFlight.set(key, current);
  current.catch(() => {}).then(() => {
    if (inFlight.get(key) === current) inFlight.delete(key);
  });

  return current;
}

async function applyStylesNow(key, tabId, frameId, url, fresh) {
  await injectedReady;

  if (fresh && injected.delete(key)) await persistInjected();

  const host = hostname(url);
  const css = host ? await stylesFor(host) : "";
  const current = injected.get(key);

  if (current && current.host === host && current.css === css) return;

  if (current) {
    injected.delete(key);
    await persistInjected();
    try {
      await API.scripting.removeCSS({
        target: { tabId, frameIds: [frameId] },
        css: current.css,
      });
    } catch (e) {
      // The frame navigated away or closed; nothing left to clean up.
    }
  }

  if (!css) return;

  try {
    await API.scripting.insertCSS({
      target: { tabId, frameIds: [frameId] },
      css,
    });
    injected.set(key, { host, css });
    await persistInjected();
  } catch (e) {
    console.error(`Failed to inject styles for ${host}:`, e);
  }
}

// Re-applies styles to every frame that is already open, so edits land without a page reload.
async function refreshStyles() {
  let tabs = [];
  try {
    tabs = await API.tabs.query({});
  } catch (e) {
    return;
  }

  await Promise.all(
    tabs.map(async (tab) => {
      let frames = [];
      try {
        frames = (await API.webNavigation.getAllFrames({ tabId: tab.id })) || [];
      } catch (e) {
        return;
      }

      await Promise.all(
        frames.map((frame) => applyStyles(tab.id, frame.frameId, frame.url)),
      );
    }),
  );
}

function stylesFor(host) {
  // Caches the promise rather than the settled value: refreshStyles fans out over every frame at
  // once, so caching only on completion would let N frames sharing a host each issue their own
  // request - and each one costs a full catalog load on the Sprinkles side.
  let pending = cssByHost.get(host);

  if (!pending) {
    pending = (async () => {
      try {
        const res = await fetch(`${SERVER}/v4/site/${encodeURIComponent(host)}.css`);
        if (res.ok) return (await res.text()).trim();
      } catch (e) {
        console.error(`Failed to fetch styles for ${host}:`, e);
      }

      return "";
    })();

    cssByHost.set(host, pending);
  }

  return pending;
}

function hostname(url) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
    return parsed.hostname;
  } catch (e) {
    return null;
  }
}

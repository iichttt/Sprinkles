// The only reason this document exists: a service worker has no matchMedia, so it cannot tell a
// light toolbar from a dark one. This reads that here and hands the answer to sw.js, which owns
// the icon.
const dark = matchMedia("(prefers-color-scheme: dark)");

function report() {
  chrome.runtime.sendMessage({ event: "theme", dark: dark.matches });
}

dark.addEventListener("change", report);
report();

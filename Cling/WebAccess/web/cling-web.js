// Cling Web Access: the few things htmx doesn't do. Keeping the dock above the on-screen keyboard and clear of the
// screen's edges, downloading a selection one file after another, arrow keys through the results on a computer, and
// the workarounds an installed app needs on an iPhone.
(() => {
    const root = document.documentElement;
    const field = () => document.getElementById("q");

    // Installed from the Home Screen. `display-mode: standalone` is false inside an installed iOS app, so ask
    // navigator.standalone too, which only iOS sets.
    const standalone = navigator.standalone === true || matchMedia("(display-mode: standalone)").matches;
    // An installed iPhone or iPad app, where a file the app navigates to (shown or downloaded) takes over the whole
    // app with no way back but force-quitting it. Files open in a viewer of the page's own, and downloads are saved
    // from memory instead.
    const iosApp = navigator.standalone === true;
    if (standalone) root.dataset.standalone = "";

    // WebKit doesn't initialise env(safe-area-inset-*) until the viewport geometry changes, so an installed app's cold
    // launch reads 0 and the dock slides under the home indicator. Measure them with a probe instead; the CSS keeps
    // env() as the fallback for every other browser.
    const measure = (side) => {
        const probe = document.createElement("div");
        probe.style.cssText = `position:fixed;top:0;left:0;visibility:hidden;pointer-events:none;width:0;height:env(safe-area-inset-${side}, 0px)`;
        document.body.append(probe);
        const value = probe.offsetHeight;
        probe.remove();
        return value;
    };
    const syncInsets = () => {
        const insets = Object.fromEntries(["top", "bottom", "left", "right"].map((side) => [side, measure(side)]));
        for (const [side, value] of Object.entries(insets)) root.style.setProperty(`--safe-${side}`, `${value}px`);
        return insets;
    };
    // Flipping viewport-fit for a frame counts as the geometry change WebKit waits for. Zero can also be the truth (a
    // phone without a notch), so it only nudges and measures again.
    if (Object.values(syncInsets()).every((v) => v === 0) && standalone) {
        const meta = document.querySelector('meta[name="viewport"]');
        const original = meta?.getAttribute("content") || "";
        if (original.includes("viewport-fit=cover")) {
            meta.setAttribute("content", original.replace("viewport-fit=cover", "viewport-fit=auto"));
            requestAnimationFrame(() => meta.setAttribute("content", original));
            setTimeout(syncInsets, 120);
            setTimeout(syncInsets, 600);
        }
    }
    addEventListener("orientationchange", () => setTimeout(syncInsets, 300));

    // iOS keeps the layout viewport tall while the keyboard is up, which would leave the docked field under the
    // keyboard. Only while it's up does the page take the visible height: the rest of the time 100vh (installed) or
    // 100dvh (in a tab) is right, and a cold-launched installed app reads the visual viewport too early to trust it.
    const viewport = window.visualViewport;
    if (viewport) {
        const fit = () => {
            syncInsets();
            const keyboard = viewport.scale < 1.01 && viewport.height < window.innerHeight - 80;
            if (keyboard) root.style.setProperty("--vvh", `${Math.round(viewport.height)}px`);
            else root.style.removeProperty("--vvh");
        };
        viewport.addEventListener("resize", fit);
        fit();
    }

    // Over HTTPS only (the Tailscale name), the one place browsers allow a service worker.
    if (location.protocol === "https:" && "serviceWorker" in navigator) {
        navigator.serviceWorker.register("/sw.js").catch(() => {});
    }

    // Return just puts the keyboard away: the results are already there.
    document.addEventListener("submit", (event) => {
        if (!event.target.matches("form.search")) return;
        event.preventDefault();
        field()?.blur();
    });

    // MARK: Toast

    // One line over the dock for what a download is doing, with up to one action and a close button.
    const toast = (() => {
        let element;
        const show = (text, action, onAction, onClose) => {
            if (!element) {
                element = document.createElement("div");
                element.className = "toast";
                element.setAttribute("role", "status");
                element.innerHTML = `<span class="toast-text"></span><button class="btn primary" type="button"></button><button class="clear" type="button" aria-label="Close"><svg class="i" aria-hidden="true"><use href="#i-x"/></svg></button>`;
                document.querySelector(".dock")?.prepend(element);
            }
            element.querySelector(".toast-text").textContent = text;
            const button = element.querySelector(".btn");
            button.hidden = !action;
            button.textContent = action || "";
            button.onclick = onAction || null;
            element.querySelector(".clear").onclick = () => {
                onClose?.();
                hide();
            };
            element.hidden = false;
        };
        const hide = () => {
            if (element) element.hidden = true;
        };
        return { show, hide };
    })();

    // MARK: Downloads

    // Download each selected file in turn. Browsers ask once before letting a page start several downloads.
    document.addEventListener("click", async (event) => {
        const button = event.target.closest("[data-urls]");
        if (!button) return;
        event.preventDefault();
        const urls = JSON.parse(button.dataset.urls);
        if (iosApp) {
            saveInApp(urls);
            return;
        }
        button.classList.add("busy");
        for (const [i, url] of urls.entries()) {
            const link = Object.assign(document.createElement("a"), { href: url, download: "", hidden: true });
            document.body.append(link);
            link.click();
            link.remove();
            if (i < urls.length - 1) await new Promise((resolve) => setTimeout(resolve, 1200));
        }
        button.classList.remove("busy");
    });

    // In the installed iOS app every download goes through memory: fetched here with its progress showing, then handed
    // to the share sheet (Save to Files, or to Photos for pictures and videos) or, without HTTPS, to Safari's download
    // prompt as a blob, the one kind of download an installed app survives.
    if (iosApp) {
        document.addEventListener("click", (event) => {
            const link = event.target.closest("a[download]");
            // Not the click handOver makes on the blob it saves.
            if (!link || !event.isTrusted || link.protocol === "blob:") return;
            event.preventDefault();
            saveInApp([link.href]);
        }, true);
    }

    // Past this, holding the files in memory risks iOS closing the app. Safari's own downloads have no such limit.
    const inAppLimit = 512 * 1024 * 1024;
    let saving = null;

    const fileName = (response, url) => {
        const header = response.headers.get("Content-Disposition") || "";
        const encoded = /filename\*=UTF-8''([^;]+)/i.exec(header);
        if (encoded) return decodeURIComponent(encoded[1]);
        return decodeURIComponent(new URL(url).pathname.split("/").filter(Boolean).pop() || "download");
    };

    const percent = (done, total) => (total ? ` · ${Math.floor((done / total) * 100)}%` : "");

    async function saveInApp(urls) {
        saving?.abort();
        const controller = new AbortController();
        saving = controller;
        const files = [];
        try {
            for (const [index, url] of urls.entries()) {
                const response = await fetch(url, { signal: controller.signal });
                if (!response.ok) throw new Error(`HTTP ${response.status}`);
                const name = fileName(response, url);
                const total = Number(response.headers.get("Content-Length")) || 0;
                const held = files.reduce((sum, file) => sum + file.size, 0);
                if (held + total > inAppLimit) {
                    controller.abort();
                    tooBig(url);
                    return;
                }
                const label = urls.length > 1 ? `Downloading ${index + 1} of ${urls.length}` : `Downloading ${name}`;
                toast.show(label, null, null, () => controller.abort());
                const reader = response.body.getReader();
                const chunks = [];
                let received = 0;
                for (;;) {
                    const { done, value } = await reader.read();
                    if (done) break;
                    chunks.push(value);
                    received += value.length;
                    toast.show(label + percent(received, total), null, null, () => controller.abort());
                }
                files.push(new File(chunks, name, { type: response.headers.get("Content-Type") || "application/octet-stream" }));
            }
        } catch (error) {
            if (error.name !== "AbortError") toast.show(`Couldn't download ${urls.length > 1 ? "the files" : "the file"}`);
            return;
        } finally {
            if (saving === controller) saving = null;
        }
        handOver(files);
    }

    // The share sheet needs a tap of its own when the download took longer than the tap that started it counts for.
    async function handOver(files) {
        if (navigator.canShare?.({ files })) {
            try {
                await navigator.share({ files });
                toast.hide();
            } catch (error) {
                if (error.name === "NotAllowedError") {
                    const ready = files.length > 1 ? `${files.length} files are ready` : `${files[0].name} is ready`;
                    toast.show(ready, "Save", () => handOver(files));
                } else {
                    toast.hide();
                }
            }
            return;
        }
        for (const file of files) {
            const href = URL.createObjectURL(file);
            const link = Object.assign(document.createElement("a"), { href, download: file.name, hidden: true });
            document.body.append(link);
            link.click();
            link.remove();
            setTimeout(() => URL.revokeObjectURL(href), 60_000);
        }
        toast.hide();
    }

    // Safari downloads to disk however big the file, and it signed in when the link or QR code was opened there.
    function tooBig(url) {
        toast.show("Too big to save in the app. Open the link in Safari.", "Copy link", async () => {
            const absolute = new URL(url, location.href).href;
            try {
                await navigator.clipboard.writeText(absolute);
            } catch {
                const input = Object.assign(document.createElement("input"), { value: absolute, readOnly: true });
                document.body.append(input);
                input.select();
                document.execCommand("copy");
                input.remove();
            }
            toast.show("Link copied");
        });
    }

    // MARK: Viewer

    // In an installed app a file shown by navigating to it fills the app with no way back, so the page shows it itself,
    // over the results, and the back swipe or Close puts it away. A browser tab keeps its own viewer and back button.
    const viewable = iosApp ? ["image", "video", "audio", "text", "html", "pdf"] : ["image", "video", "audio", "text", "html"];
    let viewer = null;

    if (standalone) {
        document.addEventListener("click", (event) => {
            const link = event.target.closest("a.main[data-kind]");
            if (!link || !viewable.includes(link.dataset.kind) || event.metaKey || event.ctrlKey) return;
            event.preventDefault();
            const row = link.closest(".row");
            openViewer(link.href, link.dataset.kind, row?.querySelector(".name")?.textContent || "", row?.querySelector("a.dl")?.href);
        });
        addEventListener("popstate", () => {
            if (viewer) closeViewer(false);
        });
    }

    function openViewer(url, kind, name, download) {
        if (viewer) closeViewer(false);
        viewer = document.createElement("div");
        viewer.className = "viewer";
        viewer.setAttribute("role", "dialog");
        viewer.setAttribute("aria-modal", "true");
        viewer.innerHTML = `<header class="viewer-bar"><button class="clear" type="button" aria-label="Close"><svg class="i" aria-hidden="true"><use href="#i-x"/></svg></button><span class="viewer-name"></span><a class="dl" download><svg class="i" aria-hidden="true"><use href="#i-download"/></svg></a></header><div class="viewer-body"></div>`;
        viewer.querySelector(".viewer-name").textContent = name;
        const save = viewer.querySelector("a.dl");
        if (download) {
            save.href = download;
            save.setAttribute("aria-label", `Download ${name}`);
        } else {
            save.remove();
        }
        viewer.querySelector(".clear").addEventListener("click", () => closeViewer(true));

        const body = viewer.querySelector(".viewer-body");
        if (kind === "image") {
            body.append(Object.assign(document.createElement("img"), { src: url, alt: name }));
        } else if (kind === "video" || kind === "audio") {
            const media = Object.assign(document.createElement(kind), { src: url, controls: true, autoplay: true, playsInline: true });
            body.append(media);
        } else if (kind === "text") {
            const pre = document.createElement("pre");
            body.append(pre);
            fetch(url).then((r) => r.text()).then((text) => (pre.textContent = text)).catch(() => {});
        } else {
            body.append(Object.assign(document.createElement("iframe"), { src: url, title: name }));
        }
        document.body.append(viewer);
        history.pushState({ viewer: true }, "");
    }

    // `back` when the viewer was closed with its own button, which also takes back the history entry it added.
    function closeViewer(back) {
        for (const media of viewer.querySelectorAll("video, audio")) media.pause();
        viewer.remove();
        viewer = null;
        if (back && history.state?.viewer) history.back();
    }

    // MARK: Results

    // A thumbnail Quick Look couldn't make leaves the row's plain icon showing. A listener rather than an onerror
    // attribute, since the page's CSP allows no inline script.
    document.addEventListener("error", (event) => {
        if (event.target.matches?.("img.thumb")) event.target.remove();
    }, true);
    // The ones that failed before this script ran.
    for (const img of document.querySelectorAll("img.thumb")) {
        if (img.complete && img.naturalWidth === 0) img.remove();
    }

    document.addEventListener("cling:cleared", () => {
        for (const box of document.querySelectorAll(".pick input:checked")) box.checked = false;
    });

    // A search sent while the Mac is out of reach fails as fetch fails, with a TypeError; a search a newer one
    // replaced is an AbortError, and nothing to report.
    let unreachable = false;
    document.addEventListener("htmx:error", (event) => {
        if (event.detail?.error?.name !== "TypeError") return;
        unreachable = true;
        toast.show(`Can't reach ${document.body.dataset.mac || "the Mac"}`, null, null, () => (unreachable = false));
    });
    document.addEventListener("htmx:after:request", () => {
        if (!unreachable) return;
        unreachable = false;
        toast.hide();
    });

    document.addEventListener("keydown", (event) => {
        const input = field();
        if (viewer && event.key === "Escape") {
            event.preventDefault();
            closeViewer(true);
            return;
        }
        if (!input || event.metaKey || event.ctrlKey || event.altKey) return;
        const active = document.activeElement;
        const rows = [...document.querySelectorAll("#results .row .main")];
        const index = rows.indexOf(active);

        if (event.key === "/" && active !== input) {
            event.preventDefault();
            input.focus();
            input.select();
        } else if (event.key === "ArrowDown" && rows.length && (active === input || index >= 0)) {
            event.preventDefault();
            rows[Math.min(index + 1, rows.length - 1)].focus();
            rows[Math.min(index + 1, rows.length - 1)].scrollIntoView({ block: "nearest" });
        } else if (event.key === "ArrowUp" && index >= 0) {
            event.preventDefault();
            if (index === 0) input.focus();
            else {
                rows[index - 1].focus();
                rows[index - 1].scrollIntoView({ block: "nearest" });
            }
        } else if (event.key === " " && index >= 0) {
            event.preventDefault();
            active.closest(".row").querySelector(".pick input:not(:disabled)")?.click();
        } else if (event.key === "Escape" && active === input && input.value) {
            input.value = "";
            input.dispatchEvent(new Event("input", { bubbles: true }));
        }
    });
})();

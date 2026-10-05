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

    // The page is exactly as tall as the window, so the dock sits on its bottom edge. No CSS unit gets that right in an
    // installed iOS app (100vh counts the status bar it starts below), and iOS keeps the window tall while the
    // keyboard is up, which would leave the docked field under the keyboard: then the page takes the visible height.
    // Measured again after a cold launch, where the first reading can come before the app has its final size.
    // With the keyboard up, iOS also slides the visible area down the page (offsetTop) to keep the field in view, and
    // the page, pinned in the CSS, follows it, or the dock would show at the top of the screen.
    const viewport = window.visualViewport;
    const fit = () => {
        syncInsets();
        const keyboard = viewport && viewport.scale < 1.01 && viewport.height < window.innerHeight - 80;
        root.style.setProperty("--app-height", `${Math.round(keyboard ? viewport.height : window.innerHeight)}px`);
        root.style.setProperty("--app-top", `${Math.round(keyboard ? viewport.offsetTop : 0)}px`);
        fitOptions();
    };
    viewport?.addEventListener("resize", fit);
    viewport?.addEventListener("scroll", fit);
    addEventListener("resize", fit);
    addEventListener("orientationchange", () => setTimeout(fit, 300));
    addEventListener("pageshow", fit);
    fit();
    setTimeout(fit, 150);
    setTimeout(fit, 800);

    // The page doesn't zoom (see touch-action in the CSS), but iOS Safari zooms on its own gesture events regardless.
    for (const type of ["gesturestart", "gesturechange"]) {
        document.addEventListener(type, (event) => event.preventDefault(), { passive: false });
    }

    // Over HTTPS only (the Tailscale name), the one place browsers allow a service worker.
    if (location.protocol === "https:" && "serviceWorker" in navigator) {
        navigator.serviceWorker.register("/sw.js").catch(() => {});
    }

    // MARK: Search options

    // The chosen options sit in the field while their names fit whole and leave room to type, and in a row above it
    // otherwise (.spill in the CSS).
    function fitOptions() {
        const dock = document.querySelector(".dock");
        const input = field();
        const label = document.querySelector(".opts-label");
        if (!dock || !input || !label) return;
        dock.classList.remove("spill");
        if (!label.childElementCount) return;
        const cut = [...label.querySelectorAll(".part > span")].some((name) => name.scrollWidth > name.clientWidth + 1);
        if (cut || input.clientWidth < 120) dock.classList.add("spill");
    }
    document.addEventListener("input", (event) => {
        if (event.target === field()) fitOptions();
    });
    document.addEventListener("htmx:after:request", fitOptions);

    // A choice in the options sheet searches again, and the button shows what the search is narrowed to. The sheet is
    // inside the search form, so htmx sends its radios with every search.
    // The button's label is built the way the server builds it (WebPage.optionsSummary): each choice's icon and name.
    document.addEventListener("change", (event) => {
        if (!event.target.matches('#options input[type="radio"]')) return;
        const chosen = [...document.querySelectorAll('#options input[type="radio"]:checked')].filter((radio) => radio.value);
        const button = document.querySelector("button.opts");
        if (button) {
            button.classList.toggle("on", chosen.length > 0);
            button.querySelector(".opts-label").replaceChildren(...chosen.map((radio) => {
                const part = document.createElement("span");
                part.className = radio.name === "where" && radio.value === "everything" ? "part everything" : "part";
                const name = document.createElement("span");
                name.textContent = radio.dataset.label;
                part.append(radio.closest("label").querySelector(".sym").cloneNode(true), name);
                return part;
            }));
            fitOptions();
        }
        field()?.dispatchEvent(new Event("search"));
    });

    // MARK: Sheets

    // The options and the selection open as modal dialogs from the bottom edge. Modal, so a tap beside one only
    // closes it: a popover closed on the same tap that went on to open the file underneath.
    document.addEventListener("click", (event) => {
        const opener = event.target.closest("[data-opens]");
        if (opener) {
            const dialog = document.getElementById(opener.dataset.opens);
            if (dialog && !dialog.open) {
                // Where the keyboard would hide it.
                field()?.blur();
                dialog.showModal();
            }
            return;
        }
        // A tap on the backdrop lands on the dialog itself, outside its box.
        const dialog = event.target;
        if (dialog instanceof HTMLDialogElement && dialog.open) {
            const box = dialog.getBoundingClientRect();
            const inside = event.clientX >= box.left && event.clientX <= box.right && event.clientY >= box.top && event.clientY <= box.bottom;
            if (!inside) dialog.close();
        }
    });

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

    // MARK: Selection

    // Selection mode opens the checkbox column and makes a tap on a row select it. Select and Done switch it, and so
    // does a two-finger glide down the list, the way iOS lists start selecting. The selection itself is kept on the
    // Mac, so it outlasts the mode, a search or a reload: Done only puts the checkboxes away.
    const setSelecting = (on) => {
        document.body.classList.toggle("selecting", on);
        const button = document.querySelector("button.select");
        if (!button) return;
        button.textContent = on ? "Done" : "Select";
        button.setAttribute("aria-pressed", on ? "true" : "false");
    };
    const selecting = () => document.body.classList.contains("selecting");

    document.addEventListener("click", (event) => {
        if (event.target.closest("button.select")) setSelecting(!selecting());
    });

    // In selection mode the whole row is the checkbox. Capturing and registered first, so it runs before the viewer
    // and the in-app download see the tap.
    document.addEventListener("click", (event) => {
        if (!selecting()) return;
        const main = event.target.closest("#results .row .main");
        if (!main) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        main.closest(".row").querySelector(".pick input:not(:disabled)")?.click();
    }, true);

    // Two fingers sliding up or down the list select every row they pass, or deselect them when the first row was
    // already selected, as in Mail and Files. The boxes change as the fingers move; the Mac hears about all of them in
    // one request when the fingers lift.
    const results = document.getElementById("results");
    let glide = null;
    const midpoint = (touches) => ({ x: (touches[0].clientX + touches[1].clientX) / 2, y: (touches[0].clientY + touches[1].clientY) / 2 });
    const pathOf = (box) => {
        try {
            return JSON.parse(box.getAttribute("hx-vals")).p;
        } catch {
            return null;
        }
    };

    const glideTo = (point) => {
        const row = document.elementFromPoint(point.x, point.y)?.closest("#results .row");
        const rows = [...results.querySelectorAll(".row")];
        const index = rows.indexOf(row);
        if (index < 0) return;
        if (glide.target === null) {
            const box = row.querySelector(".pick input:not(:disabled)");
            if (!box) return;
            glide.target = !box.checked;
            glide.last = index;
        }
        // Every row between the last one and this, which a quick glide skips over.
        for (const passed of rows.slice(Math.min(glide.last, index), Math.max(glide.last, index) + 1)) {
            const box = passed.querySelector(".pick input:not(:disabled)");
            const path = box && pathOf(box);
            if (!path || box.checked === glide.target) continue;
            box.checked = glide.target;
            glide.changed.set(path, box);
        }
        glide.last = index;
    };

    // Held near the top or bottom of the list, the glide scrolls it, faster the closer it gets to the edge.
    const autoscroll = () => {
        if (!glide?.active) return;
        const box = results.getBoundingClientRect();
        const edge = 56;
        const y = glide.point.y;
        const speed = y < box.top + edge ? -(box.top + edge - y) / 4 : y > box.bottom - edge ? (y - box.bottom + edge) / 4 : 0;
        if (speed) {
            results.scrollTop += Math.round(speed);
            glideTo(glide.point);
        }
        glide.frame = requestAnimationFrame(autoscroll);
    };

    if (results) {
        results.addEventListener("touchstart", (event) => {
            if (event.touches.length !== 2) return;
            const start = midpoint(event.touches);
            glide = { start, point: start, active: false, target: null, last: -1, changed: new Map(), frame: 0 };
        }, { passive: true });

        results.addEventListener("touchmove", (event) => {
            if (!glide || event.touches.length !== 2) return;
            // Two fingers on the list glide rather than scroll.
            event.preventDefault();
            glide.point = midpoint(event.touches);
            if (!glide.active) {
                const dx = Math.abs(glide.point.x - glide.start.x);
                const dy = Math.abs(glide.point.y - glide.start.y);
                if (dy < 12 || dx > dy) return;
                glide.active = true;
                setSelecting(true);
                glideTo(glide.start);
                glide.frame = requestAnimationFrame(autoscroll);
            }
            glideTo(glide.point);
        }, { passive: false });

        const endGlide = () => {
            if (!glide) return;
            cancelAnimationFrame(glide.frame);
            const { active, changed, target } = glide;
            glide = null;
            if (!active || !changed.size) return;
            const body = new URLSearchParams();
            for (const path of changed.keys()) body.append("p", path);
            body.append("on", target ? "true" : "false");
            fetch("/select", { method: "POST", headers: { "HX-Request": "true", "Content-Type": "application/x-www-form-urlencoded" }, body })
                .then((response) => (response.ok ? response.text() : Promise.reject(new Error(`HTTP ${response.status}`))))
                .then((html) => {
                    const bar = document.getElementById("selbar");
                    if (!bar) return;
                    bar.outerHTML = html;
                    window.htmx?.process(document.getElementById("selbar"));
                })
                // The boxes go back to what the Mac still has.
                .catch(() => {
                    for (const box of changed.values()) box.checked = !target;
                });
        };
        results.addEventListener("touchend", (event) => {
            if (event.touches.length < 2) endGlide();
        });
        results.addEventListener("touchcancel", endGlide);
    }

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
            const image = Object.assign(document.createElement("img"), { src: url, alt: name });
            body.append(image);
            zoomable(image, body);
        } else if (kind === "video" || kind === "audio") {
            const media = Object.assign(document.createElement(kind), { src: url, controls: true, autoplay: true, playsInline: true });
            body.append(media);
            if (kind === "video") zoomable(media, body);
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

    // Pinch to zoom around the fingers, drag to pan once zoomed, double-tap to zoom in or back out. The element moves
    // by transform alone, so the bar with Close stays where it is. One finger at 1x is left to the video's controls.
    function zoomable(element, container) {
        const pointers = new Map();
        let scale = 1;
        let x = 0;
        let y = 0;
        let start = null;
        let lastTap = { time: 0, x: 0, y: 0 };
        let moved = false;
        // A pinch can start beside the picture, on the letterboxing, and still has to reach these listeners.
        container.style.touchAction = "none";

        const apply = () => {
            element.style.transform = scale === 1 ? "" : `translate(${x}px, ${y}px) scale(${scale})`;
        };
        // Zoomed in, the picture's edges stop at the container's edges; zoomed out, it snaps back to the middle.
        const clamp = () => {
            scale = Math.min(Math.max(scale, 1), 8);
            if (scale === 1) {
                x = 0;
                y = 0;
                return;
            }
            const box = container.getBoundingClientRect();
            const limitX = Math.max(0, (element.offsetWidth * scale - box.width) / 2);
            const limitY = Math.max(0, (element.offsetHeight * scale - box.height) / 2);
            x = Math.min(Math.max(x, -limitX), limitX);
            y = Math.min(Math.max(y, -limitY), limitY);
        };
        const centre = () => {
            const box = container.getBoundingClientRect();
            return { x: box.left + box.width / 2, y: box.top + box.height / 2 };
        };
        const points = () => [...pointers.values()];
        // Measures from wherever the fingers are now, so lifting or adding one doesn't make the picture jump.
        const begin = () => {
            const [a, b] = points();
            if (!a) {
                start = null;
                return;
            }
            const mid = b ? { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 } : a;
            start = { distance: b ? Math.hypot(a.x - b.x, a.y - b.y) : 0, mid, scale, x, y };
        };
        // Zooms by `factor` keeping the screen point `at` where it is.
        const zoomAt = (from, factor, at, now) => {
            const c = centre();
            scale = from.scale * factor;
            x = now.x - c.x - factor * (at.x - c.x - from.x);
            y = now.y - c.y - factor * (at.y - c.y - from.y);
        };

        container.addEventListener("pointerdown", (event) => {
            pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
            if (pointers.size === 2 || scale > 1) {
                try {
                    container.setPointerCapture(event.pointerId);
                } catch {}
            }
            moved = false;
            begin();
        });
        container.addEventListener("pointermove", (event) => {
            if (!pointers.has(event.pointerId) || !start) return;
            pointers.set(event.pointerId, { x: event.clientX, y: event.clientY });
            const [a, b] = points();
            if (b && start.distance > 0) {
                const mid = { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 };
                zoomAt(start, Math.hypot(a.x - b.x, a.y - b.y) / start.distance, start.mid, mid);
                moved = true;
            } else if (scale > 1) {
                x = start.x + (a.x - start.mid.x);
                y = start.y + (a.y - start.mid.y);
                moved ||= Math.hypot(a.x - start.mid.x, a.y - start.mid.y) > 6;
            } else {
                return;
            }
            clamp();
            apply();
        });
        const end = (event) => {
            if (!pointers.has(event.pointerId)) return;
            const wasSingle = pointers.size === 1;
            pointers.delete(event.pointerId);
            clamp();
            apply();
            begin();
            if (!wasSingle || moved) return;
            const now = performance.now();
            const near = Math.hypot(event.clientX - lastTap.x, event.clientY - lastTap.y) < 30;
            if (now - lastTap.time < 320 && near) {
                const tap = { x: event.clientX, y: event.clientY };
                if (scale > 1) scale = 1;
                else zoomAt({ scale: 1, x: 0, y: 0 }, 2.5, tap, tap);
                clamp();
                element.style.transition = "transform 0.2s ease";
                apply();
                setTimeout(() => (element.style.transition = ""), 220);
                lastTap = { time: 0, x: 0, y: 0 };
            } else {
                lastTap = { time: now, x: event.clientX, y: event.clientY };
            }
        };
        container.addEventListener("pointerup", end);
        container.addEventListener("pointercancel", end);
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
        // The dialog closes itself on Escape; nothing behind it should react too.
        if (document.querySelector("dialog[open]")) return;
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
            setSelecting(true);
            active.closest(".row").querySelector(".pick input:not(:disabled)")?.click();
        } else if (event.key === "Escape" && active === input && input.value) {
            input.value = "";
            input.dispatchEvent(new Event("input", { bubbles: true }));
        } else if (event.key === "Escape" && selecting()) {
            setSelecting(false);
        }
    });
})();

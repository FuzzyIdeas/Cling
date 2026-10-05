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
        // On its side an iPhone reports the notch's inset on both edges. The page keeps clear of the notch only and
        // runs to the other edge: turned left (90°) the notch is on the left, turned right (270°) on the right.
        // The side given up still has the screen's rounded corner, which a bar's button would sit under, so the bars
        // keep a little room there (--corner-*); the list runs under it like a photo grid does.
        const turned = screen.orientation?.angle ?? window.orientation;
        const corner = { left: 0, right: 0 };
        if (insets.left > 0 && insets.right > 0) {
            if (turned === 90) [insets.right, corner.right] = [0, 16];
            else if (turned === 270 || turned === -90) [insets.left, corner.left] = [0, 16];
        }
        for (const [side, value] of Object.entries(insets)) root.style.setProperty(`--safe-${side}`, `${value}px`);
        for (const [side, value] of Object.entries(corner)) root.style.setProperty(`--corner-${side}`, `${value}px`);
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
    // Turning straight from one side to the other keeps the same size, so no resize comes to measure again.
    screen.orientation?.addEventListener("change", () => setTimeout(syncInsets, 300));

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

    // The folder being searched and the chosen options sit in the field while their names fit whole and leave room to
    // type, and in a row above it otherwise (.spill in the CSS), the folder first.
    function fitOptions() {
        const dock = document.querySelector(".dock");
        const input = field();
        const label = document.querySelector(".opts-label");
        if (!dock || !input || !label) return;
        dock.classList.remove("spill");
        const scope = dock.querySelector(".scope");
        const names = [...label.querySelectorAll(".part > span"), ...(scope ? scope.querySelectorAll("span") : [])];
        if (!names.length) return;
        const cut = names.some((name) => name.scrollWidth > name.clientWidth + 1);
        if (!cut && input.clientWidth >= 120) return;
        dock.classList.add("spill");
        dock.style.setProperty("--spill-start", scope ? `${scope.offsetWidth + 6}px` : "0px");
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

    // A sheet follows a drag down from its top, the handle or anywhere while its list is scrolled to the top, and
    // closes past a third of its height or with a flick, as iOS sheets do.
    document.addEventListener("touchstart", (event) => {
        const sheet = event.target.closest("dialog.sheet[open]");
        if (!sheet || event.touches.length !== 1) return;
        const touch = event.touches[0];
        let drag = { y: touch.clientY, last: touch.clientY, time: event.timeStamp, speed: 0, active: false };
        const move = (moveEvent) => {
            const y = moveEvent.touches[0].clientY;
            const dy = y - drag.y;
            if (!drag.active) {
                if (dy <= 0 || sheet.scrollTop > 0) return finish();
                if (dy < 10) return;
                drag.active = true;
            }
            moveEvent.preventDefault();
            drag.speed = (y - drag.last) / Math.max(1, moveEvent.timeStamp - drag.time);
            drag.last = y;
            drag.time = moveEvent.timeStamp;
            sheet.style.transform = `translateY(${dy}px)`;
        };
        const finish = () => {
            removeEventListener("touchmove", move);
            removeEventListener("touchend", finish);
            removeEventListener("touchcancel", finish);
            if (!drag?.active) return;
            const dy = drag.last - drag.y;
            const close = dy > sheet.offsetHeight / 3 || (dy > 40 && drag.speed > 0.5);
            drag = null;
            sheet.style.transition = "transform 0.22s ease";
            sheet.style.transform = close ? "translateY(100%)" : "";
            setTimeout(() => {
                sheet.style.transition = "";
                if (close) {
                    sheet.close();
                    sheet.style.transform = "";
                }
            }, 220);
        };
        addEventListener("touchmove", move, { passive: false });
        addEventListener("touchend", finish);
        addEventListener("touchcancel", finish);
    }, { passive: true });

    // MARK: Toast

    // One line over the dock for what a download is doing, with up to one action and a close button. While a file is
    // open in the viewer it sits at the viewer's foot instead, since the viewer covers the dock.
    const toast = (() => {
        let element;
        // Where it belongs right now: called again when the viewer opens or closes.
        const place = () => {
            if (!element) return;
            if (viewer) {
                if (element.parentElement !== viewer) viewer.append(element);
            } else if (element.parentElement !== document.querySelector(".dock")) {
                document.querySelector(".dock")?.prepend(element);
            }
        };
        let timer;
        // `hideAfter` (ms) for a confirmation that needs no answer; anything else stays until it's dealt with.
        const show = (text, action, onAction, onClose, hideAfter) => {
            clearTimeout(timer);
            if (hideAfter) timer = setTimeout(() => hide(), hideAfter);
            if (!element) {
                element = document.createElement("div");
                element.className = "toast";
                element.setAttribute("role", "status");
                element.innerHTML = `<span class="toast-text"></span><button class="btn primary" type="button"></button><button class="clear" type="button" aria-label="Close"><svg class="i" aria-hidden="true"><use href="#i-x"/></svg></button>`;
            }
            place();
            element.querySelector(".toast-text").textContent = text;
            const button = element.querySelector(".btn");
            button.hidden = !action;
            button.textContent = action || "";
            button.onclick = onAction || null;
            const close = element.querySelector(".clear");
            close.setAttribute("aria-label", onClose ? "Cancel" : "Dismiss");
            close.onclick = () => {
                onClose?.();
                hide();
            };
            element.hidden = false;
        };
        const hide = () => {
            clearTimeout(timer);
            if (element) element.hidden = true;
        };
        return { show, hide, place };
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

    // Tells the Mac `paths` are now selected (`on`) or not, and shows the bar it answers with.
    function postSelection(paths, on) {
        const body = new URLSearchParams();
        for (const path of paths) body.append("p", path);
        body.append("on", on ? "true" : "false");
        return fetch("/select", { method: "POST", headers: { "HX-Request": "true", "Content-Type": "application/x-www-form-urlencoded" }, body })
            .then((response) => (response.ok ? response.text() : Promise.reject(new Error(`HTTP ${response.status}`))))
            .then(replaceBar);
    }

    function replaceBar(html) {
        const bar = document.getElementById("selbar");
        if (!bar) return;
        bar.outerHTML = html;
        window.htmx?.process(document.getElementById("selbar"));
    }

    // Select All while selecting (and ⌘A on a computer) picks every row loaded so far; with all of them picked it
    // reads Deselect All and clears them.
    const allBoxes = () => [...document.querySelectorAll("#results .pick input:not(:disabled)")];
    function syncSelectAll() {
        const button = document.querySelector("[data-select-all]");
        if (!button) return;
        const boxes = allBoxes();
        button.textContent = boxes.length && boxes.every((box) => box.checked) ? "Deselect All" : "Select All";
        button.disabled = !boxes.length;
    }
    function selectAll() {
        const boxes = allBoxes();
        const on = !(boxes.length && boxes.every((box) => box.checked));
        const changed = boxes.filter((box) => box.checked !== on);
        if (!changed.length) return;
        for (const box of changed) box.checked = on;
        syncSelectAll();
        postSelection(changed.map(pathOf).filter(Boolean), on).catch(() => {
            for (const box of changed) box.checked = !on;
            syncSelectAll();
            toast.show(`Can't reach ${document.body.dataset.mac || "the Mac"}`);
        });
    }
    document.addEventListener("click", (event) => {
        if (event.target.closest("[data-select-all]")) selectAll();
    });
    document.addEventListener("change", (event) => {
        if (event.target.matches(".pick input")) syncSelectAll();
    });
    document.addEventListener("htmx:after:swap", syncSelectAll);
    document.addEventListener("htmx:after:request", syncSelectAll);

    // A row of the selection sheet leaves the selection, the list and the results' box at once.
    document.addEventListener("click", (event) => {
        const button = event.target.closest("[data-unselect]");
        if (!button) return;
        const path = button.dataset.unselect;
        const row = button.closest(".row");
        row.hidden = true;
        postSelection([path], false)
            .then(() => {
                row.remove();
                for (const box of document.querySelectorAll(".pick input")) {
                    if (pathOf(box) === path) box.checked = false;
                }
                syncSelectAll();
                const sheet = document.getElementById("sheet");
                if (sheet?.open && !sheet.querySelector(".row")) sheet.close();
            })
            .catch(() => {
                row.hidden = false;
                toast.show(`Can't reach ${document.body.dataset.mac || "the Mac"}`);
            });
    });

    // MARK: Preview

    // In landscape, wide enough for both, a file opens in a column beside the list instead of over it, as in Finder or
    // Mail: the list stays put, and a tap on another row or the arrow keys show the next file. The column can be hidden,
    // and stays hidden on this device until it's shown again. Its tap handler is on the window and registered before
    // the download handlers below, so a row's tap shows the file instead of downloading it.
    const preview = document.getElementById("preview");
    const wide = matchMedia("(orientation: landscape) and (min-width: 720px)");
    const previewHiddenKey = "cling:previewHidden";
    let previewed = null;
    let previewedURL = null;
    try {
        root.classList.toggle("preview-off", localStorage.getItem(previewHiddenKey) === "1");
    } catch {}
    const previewOn = () => !!preview && wide.matches && !root.classList.contains("preview-off");
    const pausePreview = () => {
        for (const media of preview?.querySelectorAll("video, audio") ?? []) media.pause();
    };
    wide.addEventListener("change", () => previewOn() || pausePreview());

    const previewTemplate = `<header class="viewer-bar"><span class="viewer-name"></span><button class="clear" type="button" aria-label="Send securely"><svg class="i" aria-hidden="true"><use href="#i-send"/></svg></button><a class="clear dl" download><svg class="i" aria-hidden="true"><use href="#i-download"/></svg></a><button class="clear hidepreview" type="button" aria-label="Hide preview"><svg class="i" aria-hidden="true"><use href="#i-sidebar"/></svg></button></header><div class="viewer-body"></div>`;

    function emptyPreview() {
        preview.innerHTML = previewTemplate;
        wireFileButtons(preview.querySelector(".viewer-bar"), null, "");
        preview.querySelector(".viewer-body").append(Object.assign(document.createElement("p"), { className: "viewer-missing", textContent: "No file selected" }));
    }
    if (preview) emptyPreview();

    function setPreviewHidden(hidden) {
        root.classList.toggle("preview-off", hidden);
        try {
            localStorage.setItem(previewHiddenKey, hidden ? "1" : "0");
        } catch {}
        if (hidden) pausePreview();
    }

    // The row the column shows, marked in the list.
    function markPreviewed(link) {
        for (const row of document.querySelectorAll("#results .row.current")) row.classList.remove("current");
        previewed = link;
        previewedURL = link?.href ?? null;
        link?.closest(".row")?.classList.add("current");
    }

    function showPreview(link) {
        if (link === previewed && preview.querySelector(".viewer-name").textContent) return;
        pausePreview();
        const row = link.closest(".row");
        const name = row?.querySelector(".name")?.textContent || "";
        markPreviewed(link);
        preview.innerHTML = previewTemplate;
        preview.querySelector(".viewer-name").textContent = name;
        wireFileButtons(preview.querySelector(".viewer-bar"), row, name);
        const body = preview.querySelector(".viewer-body");
        const kind = link.dataset.kind;
        if (kind && kind !== "none") renderFile(body, link.href, kind, name, false);
        else previewCard(body, row, name);
    }

    // A file the browser can't show: the Mac's Quick Look picture of it, large, and what the row says about it.
    function previewCard(body, row, name) {
        const card = Object.assign(document.createElement("div"), { className: "preview-card" });
        const glyph = row?.querySelector(".glyph")?.cloneNode(true);
        const thumb = row?.querySelector("img.thumb");
        if (thumb) {
            const url = new URL(thumb.src);
            url.searchParams.set("s", "320");
            const image = Object.assign(document.createElement("img"), { className: "preview-thumb", src: url, alt: "" });
            image.addEventListener("error", () => (glyph ? image.replaceWith(glyph) : image.remove()));
            card.append(image);
        } else if (glyph) {
            card.append(glyph);
        }
        card.append(Object.assign(document.createElement("p"), { className: "preview-name", textContent: name }));
        const meta = row?.querySelector(".meta")?.cloneNode(true);
        if (meta) card.append(meta);
        body.append(card);
    }

    addEventListener("click", (event) => {
        if (!previewOn() || selecting() || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
        const link = event.target.closest?.("#results a.main");
        // A folder opens as before.
        if (!link || link.matches('[href="/"], [href^="/?"]')) return;
        event.preventDefault();
        event.stopImmediatePropagation();
        showPreview(link);
    }, true);

    document.addEventListener("click", (event) => {
        if (event.target.closest(".showpreview")) setPreviewHidden(false);
        else if (event.target.closest(".hidepreview")) setPreviewHidden(true);
    });

    // The arrow keys move through the rows; the column follows once they stop on one.
    let previewFollow = 0;
    document.addEventListener("focusin", (event) => {
        const link = event.target.closest?.("#results a.main");
        if (!link || link === previewed || !previewOn() || link.matches('[href^="/?"]')) return;
        clearTimeout(previewFollow);
        previewFollow = setTimeout(() => document.activeElement === link && previewOn() && showPreview(link), 150);
    });

    // A new search or the next page replaces the rows: the one shown is marked again if it's still among them.
    document.addEventListener("htmx:after:swap", () => {
        if (!previewedURL || previewed?.isConnected) return;
        const again = [...document.querySelectorAll("#results a.main")].find((link) => link.href === previewedURL);
        if (again) markPreviewed(again);
    });

    // MARK: Large downloads

    // A download over the size set in Settings > File server asks first, and so does a share link, which has the Mac
    // zip any folder in it before the link opens. Captured on the window, so this runs before every other click
    // handler: a declined download never reaches them, and a confirmed one goes on through them.
    const confirmOver = Number(document.body.dataset.confirmOver) || 0;
    let confirmedDownload = null;
    let askDialog = null;

    addEventListener("click", (event) => {
        // Downloading, or started a moment ago in a browser tab (see Downloads): a second tap would fetch a second copy.
        if (event.target.closest?.("a[download], [data-urls], [data-link]")?.matches(".busy, .started")) {
            event.preventDefault();
            event.stopImmediatePropagation();
            return;
        }
        if (!confirmOver) return;
        const target = event.target.closest?.("a[download][data-size], [data-urls][data-size], [data-link][data-size]");
        if (!target || target.protocol === "blob:") return;
        // In selection mode a tap on a row picks it (see Selection) instead of downloading it.
        if (target.matches(".main") && document.body.classList.contains("selecting")) return;
        // Already kept on this phone (see Kept downloads): nothing big comes over the network.
        if (iosApp && target.matches("a[download]") && kept.has(target.href)) return;
        if (confirmedDownload === target) {
            confirmedDownload = null;
            return;
        }
        event.preventDefault();
        event.stopImmediatePropagation();
        weighDownload(target);
    }, true);

    // A folder's ZIP has no size until the Mac measures it, which takes up to a second.
    async function weighDownload(target) {
        let { size, sizeLabel: label, sizeFloor: floor } = target.dataset;
        if (size === "?") {
            target.classList.add("busy");
            try {
                const response = await fetch("/size" + new URL(target.href).pathname.slice(2));
                ({ bytes: size, label, floor } = await response.json());
            } catch {
                startDownload(target);
                return;
            } finally {
                target.classList.remove("busy");
            }
        }
        if (Number(size) <= confirmOver && !floor) {
            startDownload(target);
            return;
        }
        if (!askDialog) {
            askDialog = document.createElement("dialog");
            askDialog.className = "alert";
            askDialog.innerHTML = `<h2></h2><p></p><div class="alert-buttons"><button class="btn" type="button" data-answer="cancel">Cancel</button><button class="btn primary" type="button" data-answer="download"></button></div>`;
            askDialog.querySelector('[data-answer="cancel"]').addEventListener("click", () => askDialog.close());
            document.body.append(askDialog);
        }
        const amount = floor ? `over ${label}` : label;
        askDialog.querySelector("h2").textContent = target.dataset.link ? `Send ${amount} securely?` : `Download ${amount}?`;
        askDialog.querySelector("p").textContent = downloadName(target);
        const go = askDialog.querySelector('[data-answer="download"]');
        go.textContent = target.dataset.link ? "Create Link" : "Download";
        go.onclick = () => {
            askDialog.close();
            startDownload(target);
        };
        askDialog.showModal();
    }

    function startDownload(target) {
        // The installed app saves through memory (see Downloads), and only for a tap the person made.
        if (iosApp && target.matches("a[download]")) {
            saveInApp([target.href]);
            return;
        }
        confirmedDownload = target;
        target.click();
    }

    function downloadName(target) {
        if (target.dataset.name) return target.dataset.name;
        if (target.dataset.urls) return `${JSON.parse(target.dataset.urls).length} files`;
        const name = target.closest(".row")?.querySelector(".name")?.textContent;
        return name || decodeURIComponent(new URL(target.href).pathname.split("/").filter(Boolean).pop() || "");
    }

    // MARK: Links

    // A drop link (Send Securely in Cling) to the selection or to the file in the viewer, opened by the Mac. It can
    // take minutes, since a folder is zipped first: the Mac answers "pending" every so often and the page asks again.
    // By then the tap that asked can no longer open the share sheet, so the link waits in the toast for a tap of its own.
    document.addEventListener("click", async (event) => {
        const button = event.target.closest("[data-link]");
        if (!button) return;
        event.preventDefault();
        // Already asked: the toast says how it's going.
        if (button.classList.contains("busy")) return;
        const body = new URLSearchParams(button.dataset.link === "selection" ? { sel: "1" } : { p: button.dataset.link });
        button.classList.add("busy");
        toast.show("Creating link…");
        let message = "Couldn't create a link";
        try {
            let result;
            do {
                const response = await fetch("/link", { method: "POST", headers: { "HX-Request": "true" }, body });
                result = await response.json();
            } while (result.pending);
            if (result.url) {
                offerLink(result.url, result.expires);
                return;
            }
            if (result.error) message = result.error;
        } catch (error) {
            if (error instanceof TypeError) message = `Can't reach ${document.body.dataset.mac || "the Mac"}`;
        } finally {
            button.classList.remove("busy");
        }
        toast.show(message);
    });

    // When it stops working, which the person it's sent to will want to know.
    function expiresIn(expires) {
        if (!expires) return "";
        const minutes = Math.max(1, Math.round((expires * 1000 - Date.now()) / 60000));
        const plural = (n, unit) => `${n} ${unit}${n === 1 ? "" : "s"}`;
        if (minutes < 55) return ` · expires in ${minutes} min`;
        const hours = Math.round(minutes / 60);
        if (hours < 36) return ` · expires in ${plural(hours, "hour")}`;
        return ` · expires in ${plural(Math.round(hours / 24), "day")}`;
    }

    function offerLink(url, expires) {
        const ready = "Link ready" + expiresIn(expires);
        if (navigator.share) {
            toast.show(ready, "Share", async () => {
                try {
                    await navigator.share({ url });
                    toast.hide();
                } catch {}
            });
        } else {
            toast.show(ready, "Copy", async () => {
                await copyText(url);
                toast.show("Link copied", null, null, null, 2500);
            });
        }
    }

    async function copyText(text) {
        try {
            await navigator.clipboard.writeText(text);
        } catch {
            const input = Object.assign(document.createElement("input"), { value: text, readOnly: true });
            document.body.append(input);
            input.select();
            document.execCommand("copy");
            input.remove();
        }
    }

    // MARK: Downloads

    // In a browser tab the browser downloads it and shows its own progress, so the button only rests for a moment, long
    // enough that a second tap doesn't start a second copy. After the download confirmation, which goes first.
    if (!iosApp) {
        addEventListener("click", (event) => {
            const link = event.target.closest?.("a[download]");
            if (!link || link.protocol === "blob:" || event.defaultPrevented) return;
            if (link.matches(".main") && document.body.classList.contains("selecting")) return;
            link.classList.add("started");
            setTimeout(() => link.classList.remove("started"), 3000);
        }, true);
    }

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
    // What is downloading: one batch at a time, which a download started meanwhile joins rather than replacing it, so
    // they all reach the share sheet together. `urls` grows while it runs.
    let batch = null;

    const fileName = (response, url) => {
        const header = response.headers.get("Content-Disposition") || "";
        const encoded = /filename\*=UTF-8''([^;]+)/i.exec(header);
        if (encoded) return decodeURIComponent(encoded[1]);
        return decodeURIComponent(new URL(url).pathname.split("/").filter(Boolean).pop() || "download");
    };

    const nameOf = (url) => decodeURIComponent(new URL(url, location.href).pathname.split("/").filter(Boolean).pop() || "download");
    const megabytes = (bytes) => `${(bytes / 1e6).toFixed(bytes < 1e7 ? 1 : 0)} MB`;
    const progress = (done, total) => (total ? ` · ${Math.floor((done / total) * 100)}%` : ` · ${megabytes(done)}`);

    // Every button that downloads `url`, in the results and in the viewer, shows how far it got and takes no taps until
    // it's done. `fraction` is null while the size isn't known (a folder's ZIP).
    function markDownloading(url, fraction) {
        const href = new URL(url, location.href).href;
        for (const button of document.querySelectorAll("a[download]")) {
            if (button.href !== href) continue;
            button.classList.toggle("busy", fraction !== undefined);
            button.classList.toggle("sized", typeof fraction === "number");
            if (typeof fraction === "number") button.style.setProperty("--progress", fraction.toFixed(3));
        }
    }

    function saveInApp(urls) {
        if (batch) {
            const fresh = urls.filter((url) => !batch.urls.includes(url));
            batch.urls.push(...fresh);
            for (const url of fresh) markDownloading(url, null);
            return;
        }
        batch = { urls: [...urls], controller: new AbortController() };
        for (const url of urls) markDownloading(url, null);
        download(batch);
    }

    async function download(current) {
        const { urls, controller } = current;
        const cancel = () => controller.abort();
        const files = [];
        // Over the limit on their own or with what's already held, or failed: left out, while the rest still reach the
        // share sheet, and said afterwards.
        const tooLarge = [];
        const failed = [];
        try {
            for (let index = 0; index < urls.length; index++) {
                const url = urls[index];
                const label = (name) => (urls.length > 1 ? `Downloading ${index + 1} of ${urls.length}` : `Downloading ${name}`);
                const held = files.reduce((sum, file) => sum + file.size, 0);
                try {
                    const file = await fetchFile(url, held, label, controller.signal, cancel);
                    if (file) files.push(file);
                    else tooLarge.push(url);
                } catch (error) {
                    // Cancelled stops them all; anything else is this file's problem only.
                    if (error.name === "AbortError") throw error;
                    failed.push(url);
                } finally {
                    markDownloading(url, undefined);
                }
            }
        } catch {
            return;
        } finally {
            for (const url of urls) markDownloading(url, undefined);
            if (batch === current) batch = null;
        }
        const leftOut = () => {
            if (tooLarge.length) tooBig(tooLarge);
            else if (failed.length) toast.show(failed.length > 1 ? `Couldn't download ${failed.length} files` : `Couldn't download ${nameOf(failed[0])}`);
        };
        if (files.length) handOver(files, leftOut);
        else leftOut();
    }

    // One file into memory, its progress in the toast and on its buttons. Nil when it won't fit beside the `held` bytes.
    async function fetchFile(url, held, label, signal, cancel) {
        // Shown before the Mac answers, which for a big folder's ZIP takes a while, with Cancel right away.
        toast.show(label(nameOf(url)), null, null, cancel);
        const href = new URL(url, location.href).href;
        const known = kept.get(href);
        if (known && held + known.size <= inAppLimit && (await keptIsCurrent(href, known, signal))) {
            const file = await keptFile(href);
            if (file) return file;
        }
        const response = await fetch(url, { signal });
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const name = fileName(response, url);
        const total = Number(response.headers.get("Content-Length")) || 0;
        if (held + total > inAppLimit) {
            response.body?.cancel();
            return null;
        }
        toast.show(label(name), null, null, cancel);
        const reader = response.body.getReader();
        const chunks = [];
        let received = 0;
        for (;;) {
            const { done, value } = await reader.read();
            if (done) break;
            chunks.push(value);
            received += value.length;
            // A folder's ZIP has no size up front, so it's measured as it comes.
            if (held + received > inAppLimit) {
                reader.cancel();
                return null;
            }
            toast.show(label(name) + progress(received, total), null, null, cancel);
            markDownloading(url, total ? received / total : null);
        }
        const file = new File(chunks, name, { type: response.headers.get("Content-Type") || "application/octet-stream" });
        keep(href, file, response.headers.get("ETag"));
        return file;
    }

    // The share sheet needs a tap of its own when the download took longer than the tap that started it counts for.
    // `after` runs once the files are handed over.
    async function handOver(files, after) {
        if (navigator.canShare?.({ files })) {
            try {
                await navigator.share({ files });
                toast.hide();
            } catch (error) {
                if (error.name === "NotAllowedError") {
                    const ready = files.length > 1 ? `${files.length} files are ready` : `${files[0].name} is ready`;
                    toast.show(ready, "Save", () => handOver(files, after));
                    return;
                }
                toast.hide();
            }
            after?.();
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
        after?.();
    }

    // Safari downloads to disk however big the file, and it signed in when the link or QR code was opened there.
    function tooBig(urls) {
        const name = nameOf(urls[0]);
        const text = urls.length > 1 ? `${urls.length} files are too big to save in the app. Open them in Safari.` : `${name} is too big to save in the app. Open the link in Safari.`;
        toast.show(text, "Copy link", async () => {
            await copyText(urls.map((url) => new URL(url, location.href).href).join("\n"));
            toast.show(urls.length > 1 ? "Links copied" : "Link copied", null, null, null, 2500);
        });
    }

    // MARK: Kept downloads

    // The installed app keeps what it downloads, up to 1 GB, the least recently used going first. The same file again
    // is handed over at once when the Mac says it hasn't changed (its ETag: one round trip with nothing in it), and
    // when the Mac can't be reached at all, or no longer has it. Kept in IndexedDB, since the Cache API only exists
    // over HTTPS and most of these pages are plain HTTP on a home network. A browser tab has its own Downloads.
    const keptLimit = 1024 * 1024 * 1024;
    // Everything but the files themselves, by absolute URL, so a tap can be decided without waiting on the database.
    const kept = new Map();
    let keptDB = null;

    // Two stores: what the list shows ("info", by URL), and the files themselves ("data"), so reading the list at
    // launch doesn't read every file.
    function openKept() {
        keptDB ??= new Promise((resolve) => {
            try {
                const request = indexedDB.open("cling-downloads", 1);
                request.onupgradeneeded = () => {
                    request.result.createObjectStore("info", { keyPath: "url" });
                    request.result.createObjectStore("data");
                };
                request.onsuccess = () => resolve(request.result);
                request.onerror = () => resolve(null);
            } catch {
                resolve(null);
            }
        });
        return keptDB;
    }

    // `work` gets the two stores and returns the request whose result is wanted. Null when there's no database or the
    // write didn't fit.
    async function keptStore(mode, work) {
        const db = await openKept();
        if (!db) return null;
        return new Promise((resolve) => {
            try {
                const transaction = db.transaction(["info", "data"], mode);
                const request = work(transaction.objectStore("info"), transaction.objectStore("data"));
                transaction.oncomplete = () => resolve(request?.result ?? true);
                transaction.onerror = transaction.onabort = () => resolve(null);
            } catch {
                resolve(null);
            }
        });
    }

    if (iosApp) {
        keptStore("readonly", (info) => info.getAll()).then((records) => {
            for (const record of Array.isArray(records) ? records : []) kept.set(record.url, record);
            showDownloadsButton();
        });
    }

    // Unchanged on the Mac, out of reach, or gone from it: in every case the kept copy is the file to hand over.
    async function keptIsCurrent(href, known, signal) {
        try {
            const response = await fetch(href, { method: "HEAD", cache: "no-store", headers: { "If-None-Match": known.etag }, signal });
            return response.status === 304 || response.status === 404;
        } catch (error) {
            if (error.name === "AbortError") throw error;
            return true;
        }
    }

    async function keptFile(href) {
        const known = kept.get(href);
        if (!known) return null;
        const usedAt = Date.now();
        const data = await keptStore("readwrite", (info, data) => {
            info.put({ ...known, usedAt });
            return data.get(href);
        });
        if (!(data instanceof Blob || data instanceof ArrayBuffer)) return null;
        known.usedAt = usedAt;
        return new File([data], known.name, { type: known.type });
    }

    async function keep(href, file, etag) {
        if (!iosApp || !etag || file.size > keptLimit) return;
        const thumb = [...document.querySelectorAll("#results a.dl")].find((link) => link.href === href)?.closest(".row")?.querySelector("img.thumb")?.getAttribute("src");
        const record = { url: href, name: file.name, type: file.type, size: file.size, etag, thumb, savedAt: Date.now(), usedAt: Date.now() };
        // The least recently used make room.
        const others = [...kept.values()].filter((item) => item.url !== href).sort((a, b) => a.usedAt - b.usedAt);
        let total = others.reduce((sum, item) => sum + item.size, 0) + file.size;
        const evicted = [];
        while (total > keptLimit && others.length) {
            const item = others.shift();
            total -= item.size;
            evicted.push(item.url);
        }
        const store = (bytes) =>
            keptStore("readwrite", (info, data) => {
                for (const url of evicted) {
                    info.delete(url);
                    data.delete(url);
                }
                data.put(bytes, href);
                return info.put(record);
            });
        // A file is kept on disk as it is, except where WebKit won't store one (a private window), which takes its bytes.
        const stored = (await store(file)) || (await store(await file.arrayBuffer()));
        if (!stored) return;
        for (const url of evicted) kept.delete(url);
        kept.set(href, record);
        navigator.storage?.persist?.().catch(() => {});
        showDownloadsButton();
    }

    async function forget(urls) {
        await keptStore("readwrite", (info, data) => {
            let request = null;
            for (const url of urls) {
                data.delete(url);
                request = info.delete(url);
            }
            return request;
        });
        for (const url of urls) kept.delete(url);
        showDownloadsButton();
    }

    // On Recent, beside its title, once something is kept.
    function showDownloadsButton() {
        const header = document.querySelector("#results header.crumb.recent");
        if (!header) return;
        const button = header.querySelector("[data-downloads]");
        if (!kept.size) button?.remove();
        else if (!button) header.insertAdjacentHTML("beforeend", `<button class="pill" type="button" data-downloads><svg class="i" aria-hidden="true"><use href="#i-download"/></svg><span>Downloads</span></button>`);
    }
    document.addEventListener("htmx:after:swap", showDownloadsButton);

    const sizeText = (bytes) => (bytes < 1000 ? `${bytes} bytes` : bytes < 1e6 ? `${Math.round(bytes / 1e3)} KB` : bytes < 1e9 ? `${(bytes / 1e6).toFixed(1)} MB` : `${(bytes / 1e9).toFixed(2)} GB`);
    const dayText = (time) => {
        const date = new Date(time);
        const today = new Date().toDateString() === date.toDateString();
        return today ? date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" }) : date.toLocaleDateString([], { day: "numeric", month: "short" });
    };
    const device = /iPad/.test(navigator.userAgent) || (navigator.maxTouchPoints > 1 && /Mac/.test(navigator.platform)) ? "iPad" : "iPhone";

    function openDownloads() {
        const sheet = document.getElementById("sheet");
        if (!sheet) return;
        const items = [...kept.values()].sort((a, b) => b.savedAt - a.savedAt);
        const total = items.reduce((sum, item) => sum + item.size, 0);
        sheet.innerHTML = `<header class="crumb"><h1>Downloads</h1><button class="link" type="button" data-forget-all>Clear</button></header><p class="sheet-note"></p><ul class="list"></ul>`;
        sheet.querySelector(".sheet-note").textContent = `${items.length} ${items.length === 1 ? "file" : "files"} · ${sizeText(total)} on this ${device}`;
        const list = sheet.querySelector(".list");
        for (const item of items) {
            const row = document.createElement("li");
            row.className = "row";
            row.innerHTML = `<span class="main" role="button" tabindex="0"><span class="icon"><span class="glyph"><svg class="i" aria-hidden="true"><use href="#i-file"/></svg></span></span><span class="text"><span class="name"></span><span class="meta"><span></span><span></span></span></span></span><button class="clear" type="button"><svg class="i" aria-hidden="true"><use href="#i-x"/></svg></button>`;
            row.querySelector(".main").dataset.kept = item.url;
            row.querySelector(".name").textContent = item.name;
            const [size, day] = row.querySelectorAll(".meta span");
            size.textContent = sizeText(item.size);
            day.textContent = dayText(item.savedAt);
            if (item.thumb) {
                const image = Object.assign(document.createElement("img"), { className: "thumb", src: item.thumb, alt: "", decoding: "async" });
                image.addEventListener("error", () => image.remove());
                row.querySelector(".icon").append(image);
            }
            const remove = row.querySelector(".clear");
            remove.dataset.forget = item.url;
            remove.setAttribute("aria-label", `Remove ${item.name}`);
            list.append(row);
        }
        field()?.blur();
        if (!sheet.open) sheet.showModal();
    }

    document.addEventListener("click", async (event) => {
        if (event.target.closest("[data-downloads]")) {
            openDownloads();
            return;
        }
        const sheet = document.getElementById("sheet");
        const one = event.target.closest("[data-forget]");
        if (one) {
            await forget([one.dataset.forget]);
            if (kept.size) openDownloads();
            else sheet?.close();
            return;
        }
        if (event.target.closest("[data-forget-all]")) {
            await forget([...kept.keys()]);
            sheet?.close();
            toast.show("Downloads cleared", null, null, null, 2500);
            return;
        }
        // Saved again from the copy here, whatever the Mac is doing. The sheet goes first, or the share sheet's own
        // prompt to tap Save would sit under it.
        const row = event.target.closest("[data-kept]");
        if (!row) return;
        const file = await keptFile(row.dataset.kept);
        sheet?.close();
        if (file) handOver([file]);
    });

    // MARK: Viewer

    // In an installed app a file shown by navigating to it fills the app with no way back, so the page shows it itself,
    // over the results, and the back swipe or Close puts it away. On a phone's browser tab too, where it keeps Download
    // and Send securely at hand; a computer's browser keeps its own viewer.
    const inPageViewer = standalone || matchMedia("(pointer: coarse)").matches;
    const viewable = iosApp ? ["image", "video", "audio", "text", "html", "pdf"] : ["image", "video", "audio", "text", "html"];
    let viewer = null;
    let viewerClosedAt = -Infinity;
    // The row link shown, for stepping to the next one.
    let viewing = null;

    if (inPageViewer) {
        document.addEventListener("click", (event) => {
            const link = event.target.closest("a.main[data-kind]");
            if (!link || !viewable.includes(link.dataset.kind) || event.metaKey || event.ctrlKey) return;
            event.preventDefault();
            openViewer(link);
        });
        addEventListener("popstate", () => {
            if (viewer) closeViewer(false);
        });
        // Closing the viewer steps back over the history entry it added, onto one of htmx's, which htmx then restores
        // by fetching the whole page again: the results came back scrolled to the top. Nothing changed under the
        // viewer, so the page stays as it is. Either order: the viewer may still be open when htmx asks.
        document.addEventListener("htmx:before:history:restore", (event) => {
            if (viewer || performance.now() - viewerClosedAt < 1000) event.preventDefault();
        });
    }

    // The files the viewer can step through: the viewable ones in the results, in their order.
    const viewableLinks = () => [...document.querySelectorAll("#results a.main[data-kind]")].filter((link) => viewable.includes(link.dataset.kind));

    // The next (1) or previous (-1) viewable file, shown in place: stepping through doesn't add history to walk back.
    function step(direction) {
        const links = viewableLinks();
        const next = links[links.indexOf(viewing) + direction];
        if (!next) return false;
        openViewer(next);
        next.scrollIntoView({ block: "nearest" });
        return true;
    }

    // `link` is the row's link to the file; the row's download link carries the size the download confirmation weighs.
    function openViewer(link) {
        const url = link.href;
        const kind = link.dataset.kind;
        const row = link.closest(".row");
        const name = row?.querySelector(".name")?.textContent || "";
        const replacing = !!viewer;
        if (viewer) teardown();
        viewing = link;
        viewer = document.createElement("div");
        viewer.className = "viewer";
        viewer.setAttribute("role", "dialog");
        viewer.setAttribute("aria-modal", "true");
        viewer.setAttribute("aria-label", name);
        viewer.innerHTML = `<header class="viewer-bar"><button class="clear" type="button" aria-label="Close"><svg class="i" aria-hidden="true"><use href="#i-x"/></svg></button><span class="viewer-name"></span><button class="clear" type="button" aria-label="Send securely"><svg class="i" aria-hidden="true"><use href="#i-send"/></svg></button><a class="clear dl" download><svg class="i" aria-hidden="true"><use href="#i-download"/></svg></a></header><div class="viewer-body"></div>`;
        viewer.querySelector(".viewer-name").textContent = name;
        wireFileButtons(viewer.querySelector(".viewer-bar"), row, name);
        const close = viewer.querySelector(".clear");
        close.addEventListener("click", () => closeViewer(true));

        const body = viewer.querySelector(".viewer-body");
        const zoom = renderFile(body, url, kind, name, true);
        // Text scrolls, so a pull down only closes it from the top. A PDF or a web page takes its own touches, which
        // leaves the bar to drag it by. Only pictures and videos swipe sideways to the next file.
        const draggable = kind === "text" ? () => body.scrollTop <= 0 : kind === "pdf" || kind === "html" ? () => false : () => !zoom?.zoomed;
        const swipeable = kind === "image" || kind === "video" ? () => !zoom?.zoomed : () => false;
        dismissible(viewer, body, draggable, swipeable, zoom);
        document.body.append(viewer);
        toast.place();
        close.focus({ preventScroll: true });
        if (!replacing) history.pushState({ viewer: true }, "");
    }

    // Send securely and Download for the file in `row`, as the row's own download link has them: the size the download
    // confirmation weighs, and the progress of a download already under way.
    function wireFileButtons(bar, row, name) {
        const download = row?.querySelector("a.dl");
        const save = bar.querySelector("a.dl");
        const share = bar.querySelector('[aria-label="Send securely"]');
        if (!download) {
            save?.remove();
            share?.remove();
            return;
        }
        save.href = download.href;
        save.setAttribute("aria-label", `Download ${name}`);
        for (const key of ["size", "sizeLabel"]) {
            if (download.dataset[key]) save.dataset[key] = share.dataset[key] = download.dataset[key];
        }
        share.dataset.link = decodeURIComponent(new URL(download.href).pathname.slice(2));
        share.dataset.name = name;
        if (download.classList.contains("busy")) save.className = download.className.replace(/\bdl\b/, "clear dl");
        save.style.cssText = download.style.cssText;
    }

    // The file itself: a picture or a video that zooms, a player, text (highlighted when it's code), or a page in a
    // frame. `autoplay` in the viewer, where opening a video means watching it. Returns the zoom, for the gestures.
    function renderFile(body, url, kind, name, autoplay) {
        const missing = () => {
            body.replaceChildren(Object.assign(document.createElement("p"), { className: "viewer-missing", textContent: "Not found" }));
        };
        if (kind === "image") {
            const image = Object.assign(document.createElement("img"), { src: url, alt: name });
            image.addEventListener("error", missing);
            body.append(image);
            return zoomable(image, body);
        }
        if (kind === "video" || kind === "audio") {
            const media = Object.assign(document.createElement(kind), { src: url, controls: true, autoplay, playsInline: true });
            media.addEventListener("error", missing);
            body.append(media);
            return kind === "video" ? zoomable(media, body) : null;
        }
        if (kind === "text") {
            const pre = document.createElement("pre");
            body.append(pre);
            fetch(url)
                .then((response) => (response.ok ? response.text() : Promise.reject(response.status)))
                .then((text) => {
                    pre.textContent = text;
                    highlight(pre, text, name);
                })
                .catch(missing);
            return null;
        }
        body.append(Object.assign(document.createElement("iframe"), { src: url, title: name }));
        return null;
    }

    // highlight.js, fetched from the Mac the first time a text file is shown: most visits never need it.
    let highlighting = null;
    function highlighter() {
        highlighting ??= new Promise((resolve) => {
            const own = document.querySelector('script[src*="cling-web.js"]');
            const script = document.createElement("script");
            script.src = "/assets/highlight.min.js" + (own ? new URL(own.src).search : "");
            script.onload = () => resolve(window.hljs || null);
            script.onerror = () => {
                highlighting = null;
                resolve(null);
            };
            document.head.append(script);
        });
        return highlighting;
    }

    // Extensions highlight.js doesn't know by themselves, and the language that reads them best.
    const languages = { m: "objectivec", mm: "objectivec", fish: "bash", conf: "ini", cfg: "ini", env: "ini", xcconfig: "ini", entitlements: "xml", svg: "xml", jsonc: "json", json5: "json", jsonl: "json", mdx: "markdown" };

    // Colours the code in `pre` by its file's extension. Past a few hundred KB highlighting takes long enough to feel,
    // and a text file that big is mostly a log anyway.
    async function highlight(pre, text, name) {
        const ext = name.includes(".") ? name.split(".").pop().toLowerCase() : "";
        if (!ext || text.length > 256 * 1024) return;
        const hljs = await highlighter();
        const language = languages[ext] || ext;
        const grammar = hljs?.getLanguage(language);
        if (!grammar || grammar === hljs.getLanguage("plaintext") || !pre.isConnected) return;
        pre.innerHTML = hljs.highlight(text, { language, ignoreIllegals: true }).value;
        pre.classList.add("code");
    }

    // Down to put the viewer away, the way Photos does: the file follows the finger and shrinks a little while the
    // results show through behind it, and letting go far enough down, or with a flick, closes it. Anywhere on the bar,
    // and on the file itself while `canClose` says so. Sideways, while `canSwipe` says so, it goes to the next or the
    // previous file. A gesture only counts once it has moved 10 px, so a tap that wobbles stays a tap.
    function dismissible(viewer, body, canClose, canSwipe, zoom) {
        let drag = null;
        const follow = (dx, dy) => {
            if (drag.axis === "x") {
                body.style.transform = `translate(${dx}px, 0)`;
                return;
            }
            const progress = Math.min(Math.max(dy, 0) / 500, 1);
            body.style.transform = `translate(${dx * 0.6}px, ${Math.max(dy, 0)}px) scale(${1 - progress * 0.3})`;
            viewer.style.setProperty("--dismiss", progress.toFixed(3));
        };
        const settle = (transform, dismiss, then) => {
            body.style.transition = "transform 0.24s ease";
            viewer.style.transition = "--dismiss 0.24s ease";
            body.style.transform = transform;
            viewer.style.setProperty("--dismiss", dismiss);
            setTimeout(() => {
                body.style.transition = viewer.style.transition = "";
                then?.();
            }, 240);
        };
        viewer.addEventListener("touchstart", (event) => {
            if (event.touches.length !== 1) {
                // A second finger is a pinch, not a drag.
                if (drag?.axis) settle("", 0);
                drag = null;
                return;
            }
            const touch = event.touches[0];
            drag = { x: touch.clientX, y: touch.clientY, last: { x: touch.clientX, y: touch.clientY, time: event.timeStamp }, speed: { x: 0, y: 0 }, axis: null, claimed: false, fromBar: !!event.target.closest(".viewer-bar") };
        }, { passive: true });
        viewer.addEventListener("touchmove", (event) => {
            if (!drag || event.touches.length !== 1) return;
            const touch = event.touches[0];
            const dx = touch.clientX - drag.x;
            const dy = touch.clientY - drag.y;
            if (!drag.axis) {
                const closing = dy > 0 && dy >= Math.abs(dx) && (drag.fromBar || canClose());
                const swiping = Math.abs(dx) > Math.abs(dy) && !drag.fromBar && canSwipe();
                // Held from the first movement, before the page can scroll the text instead.
                if (!closing && !swiping && !drag.claimed) {
                    drag = null;
                    return;
                }
                drag.claimed = true;
                event.preventDefault();
                if (Math.hypot(dx, dy) < 10) return;
                if (!closing && !swiping) {
                    drag = null;
                    return;
                }
                drag.axis = closing ? "y" : "x";
                zoom?.cancelTap();
            }
            event.preventDefault();
            const elapsed = Math.max(1, event.timeStamp - drag.last.time);
            drag.speed = { x: (touch.clientX - drag.last.x) / elapsed, y: (touch.clientY - drag.last.y) / elapsed };
            drag.last = { x: touch.clientX, y: touch.clientY, time: event.timeStamp };
            follow(dx, dy);
        }, { passive: false });
        const end = () => {
            const finished = drag;
            drag = null;
            if (!finished?.axis) return;
            const dx = finished.last.x - finished.x;
            const dy = finished.last.y - finished.y;
            if (finished.axis === "x") {
                const direction = dx < 0 ? 1 : -1;
                const far = Math.abs(dx) > innerWidth / 4 || (Math.abs(dx) > 40 && Math.abs(finished.speed.x) > 0.5);
                if (far && step(direction)) return;
                settle("", 0);
            } else if (dy > 140 || (dy > 40 && finished.speed.y > 0.5)) {
                settle(`translate(0, ${innerHeight}px) scale(0.7)`, 1, () => closeViewer(true));
            } else {
                settle("", 0);
            }
        };
        viewer.addEventListener("touchend", end);
        viewer.addEventListener("touchcancel", end);
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
        return {
            get zoomed() {
                return scale > 1 || pointers.size > 1;
            },
            // A drag that closes the viewer isn't a tap towards a double-tap.
            cancelTap() {
                moved = true;
                lastTap = { time: 0, x: 0, y: 0 };
            },
        };
    }

    // `back` when the viewer was closed with its own button, which also takes back the history entry it added.
    function closeViewer(back) {
        const shown = viewing;
        teardown();
        viewerClosedAt = performance.now();
        toast.place();
        // Back on the row it showed. Stepping back through history resets focus to the search field once htmx has
        // intercepted the navigation, which could bring up the keyboard, so it waits for that to finish.
        const refocus = () => shown?.isConnected && shown.focus({ preventScroll: true });
        refocus();
        const leaving = back && history.state?.viewer;
        // Also when the back swipe closed it, mid-navigation.
        if (window.navigation && (leaving || navigation.transition)) navigation.addEventListener("navigatesuccess", refocus, { once: true });
        else if (leaving) addEventListener("popstate", () => setTimeout(refocus), { once: true });
        if (leaving) history.back();
    }

    function teardown() {
        for (const media of viewer.querySelectorAll("video, audio")) media.pause();
        viewer.remove();
        viewer = null;
        viewing = null;
    }

    // MARK: Navigation

    // Opening a folder, going up, or leaving the folder loads another page. The search options go along, the link shows
    // it's working, and an installed app asks the Mac first: if it doesn't answer, iOS shows its own error page, which
    // an installed app has no way back from. The list and how far down it was are kept, so coming back to it shows it
    // as it was, with every page that had loaded.
    const optionNames = ["where", "filter", "folders"];
    const keptLists = "cling:lists";

    document.addEventListener("click", async (event) => {
        const link = event.target.closest('a[href="/"], a[href^="/?"]');
        if (!link || event.defaultPrevented || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || event.button !== 0) return;
        event.preventDefault();
        if (link.classList.contains("busy")) return;
        const url = new URL(link.href);
        const form = document.getElementById("search");
        // `data-plain` is a link that leaves the options behind on purpose.
        if (form && !link.hasAttribute("data-plain")) {
            const data = new FormData(form);
            for (const name of optionNames) {
                const value = data.get(name);
                if (value && !url.searchParams.has(name)) url.searchParams.set(name, value);
            }
        }
        link.classList.add("busy");
        if (standalone) {
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 8000);
            try {
                await fetch(url, { method: "HEAD", cache: "no-store", signal: controller.signal });
            } catch {
                link.classList.remove("busy");
                toast.show(`Can't reach ${document.body.dataset.mac || "the Mac"}`);
                return;
            } finally {
                clearTimeout(timer);
            }
        }
        keepList();
        location.assign(url);
        // Back in the browser's cache, the page comes back as it was left, link and all.
        addEventListener("pageshow", () => link.classList.remove("busy"), { once: true });
    });

    function keepList() {
        if (!results) return;
        // What the boxes show now, which the markup alone doesn't carry.
        for (const box of results.querySelectorAll('input[type="checkbox"]')) box.toggleAttribute("checked", box.checked);
        try {
            const lists = JSON.parse(sessionStorage.getItem(keptLists) || "{}");
            lists[location.href] = { html: results.innerHTML, scroll: results.scrollTop, time: Date.now() };
            // The last few places are enough to walk back through.
            const recent = Object.entries(lists).sort((a, b) => b[1].time - a[1].time).slice(0, 6);
            sessionStorage.setItem(keptLists, JSON.stringify(Object.fromEntries(recent)));
        } catch {}
    }

    // Arrived by Back: the list as it was left, unless that was long ago.
    try {
        const [entry] = performance.getEntriesByType("navigation");
        const lists = JSON.parse(sessionStorage.getItem(keptLists) || "{}");
        const kept = lists[location.href];
        if (entry?.type === "back_forward" && kept && Date.now() - kept.time < 30 * 60 * 1000 && results) {
            results.innerHTML = kept.html;
            window.htmx?.process(results);
            requestAnimationFrame(() => (results.scrollTop = kept.scroll));
        }
    } catch {}

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
        syncSelectAll();
        toast.show("Selection cleared", "Undo", async () => {
            toast.hide();
            try {
                const response = await fetch("/select/undo", { method: "POST", headers: { "HX-Request": "true" } });
                const { bar, paths } = await response.json();
                replaceBar(bar);
                const restored = new Set(paths);
                for (const box of document.querySelectorAll(".pick input")) {
                    if (restored.has(pathOf(box))) box.checked = true;
                }
                syncSelectAll();
            } catch {
                toast.show(`Can't reach ${document.body.dataset.mac || "the Mac"}`);
            }
        }, null, 6000);
    });

    // A search sent while the Mac is out of reach fails as fetch fails, with a TypeError; a search a newer one
    // replaced is an AbortError, and nothing to report.
    // The results under it are from before, so they dim until a search gets through: Try again, or on its own when the
    // phone is back online or the app comes back to the front.
    let unreachable = false;
    const searchAgain = () => field()?.dispatchEvent(new Event("search"));
    document.addEventListener("htmx:error", (event) => {
        if (event.detail?.error?.name !== "TypeError") return;
        unreachable = true;
        results?.classList.add("stale");
        toast.show(`Can't reach ${document.body.dataset.mac || "the Mac"}`, "Try again", searchAgain, () => (unreachable = false));
    });
    document.addEventListener("htmx:after:request", (event) => {
        if (!unreachable || event.detail?.error) return;
        unreachable = false;
        results?.classList.remove("stale");
        toast.hide();
    });
    addEventListener("online", () => unreachable && searchAgain());
    document.addEventListener("visibilitychange", () => document.visibilityState === "visible" && unreachable && searchAgain());

    document.addEventListener("keydown", (event) => {
        const input = field();
        if (viewer && event.key === "Escape") {
            event.preventDefault();
            closeViewer(true);
            return;
        }
        if (viewer && (event.key === "ArrowRight" || event.key === "ArrowLeft")) {
            event.preventDefault();
            step(event.key === "ArrowRight" ? 1 : -1);
            return;
        }
        // The dialog closes itself on Escape; nothing behind it should react too.
        if (document.querySelector("dialog[open]")) return;
        const active = document.activeElement;
        if (input && (event.metaKey || event.ctrlKey) && event.key === "a" && active !== input && !(active instanceof HTMLInputElement)) {
            event.preventDefault();
            setSelecting(true);
            if (!allBoxes().every((box) => box.checked)) selectAll();
            return;
        }
        if (!input || event.metaKey || event.ctrlKey || event.altKey) return;
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

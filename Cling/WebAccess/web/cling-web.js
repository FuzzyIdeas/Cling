// Cling Web Access: the few things htmx doesn't do. Keeping the dock above the on-screen keyboard, downloading a
// selection one file after another, and arrow keys through the results on a computer.
(() => {
    const field = () => document.getElementById("q");

    // iOS keeps the layout viewport tall while the keyboard is up, which would leave the docked field under the
    // keyboard. Size the page to what is visible instead.
    const viewport = window.visualViewport;
    if (viewport) {
        const fit = () => document.documentElement.style.setProperty("--vvh", `${Math.round(viewport.height)}px`);
        viewport.addEventListener("resize", fit);
        fit();
    }

    // Return just puts the keyboard away: the results are already there.
    document.addEventListener("submit", (event) => {
        if (!event.target.matches("form.search")) return;
        event.preventDefault();
        field()?.blur();
    });

    // Download each selected file in turn. Browsers ask once before letting a page start several downloads.
    document.addEventListener("click", async (event) => {
        const button = event.target.closest("[data-urls]");
        if (!button) return;
        event.preventDefault();
        button.classList.add("busy");
        const urls = JSON.parse(button.dataset.urls);
        for (const [i, url] of urls.entries()) {
            const link = Object.assign(document.createElement("a"), { href: url, download: "", hidden: true });
            document.body.append(link);
            link.click();
            link.remove();
            if (i < urls.length - 1) await new Promise((resolve) => setTimeout(resolve, 1200));
        }
        button.classList.remove("busy");
    });

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

    document.addEventListener("keydown", (event) => {
        const input = field();
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

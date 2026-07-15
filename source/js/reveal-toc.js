// Expand a collapsed <details> write-up before jumping to a TOC target inside it.
document.addEventListener('click', function (e) {
    var a = e.target.closest && e.target.closest('#toc a');
    if (!a) {
        return;
    }
    var href = a.getAttribute('data-href') || a.getAttribute('href') || '';
    var id = decodeURIComponent(href.replace(/^#/, ''));
    var target = id && document.getElementById(id);
    if (!target) {
        return;
    }
    var details = target.closest('details');
    if (details && !details.open) {
        details.open = true;
        target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
}, true);

// AddToAny only scans the DOM once per real page load. On pjax navigation the
// share row is swapped in without a full reload, so it never gets picked up
// and the icons silently fail to render — ask AddToAny to re-scan explicitly.
function reinitShareButtons() {
    if (window.a2a && typeof window.a2a.init_all === 'function') {
        window.a2a.init_all();
    }
}
document.addEventListener('pjax:complete', reinitShareButtons);
reinitShareButtons();

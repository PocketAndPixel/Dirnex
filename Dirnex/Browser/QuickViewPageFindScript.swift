import Foundation

/// The JavaScript a rendered page is found in (2026-09-18).
///
/// Three calls, all run in `WKContentWorld.defaultClient` — an isolated world that reads the page's
/// DOM and keeps its own globals. Probed before any of this was written: with
/// `allowsContentJavaScript` **off**, which is what a previewed page ships with, the client world
/// still evaluates and still reads the DOM, while the page's own scripts do not run and cannot see
/// or overwrite what the client world stores. So finding costs the page's scripts nothing and grants
/// them nothing — the switch keeps meaning exactly what it meant.
///
/// The page is read once per search and the matching is `DirnexCore`'s, not the DOM's: `text`
/// returns what the page says, ``DirnexCore/TextFindMatches`` says where the query lies in it, and
/// `highlight` is handed those offsets back. That is what keeps a word found in an HTML file's
/// source found in the same file's rendered page — a comparison one keystroke away (`1` and `2`).
///
/// Highlighting is the CSS Custom Highlight API, which paints over the text without touching it: no
/// element is inserted, split or restyled, so a page cannot be damaged by being searched and the
/// highlight comes off by clearing one registry entry. The only thing added to the document is one
/// `<style>` rule naming the two highlights' colours.
enum QuickViewPageFindScript {
    /// The highlight registry's names, and the `<style>` element's id.
    static let allName = "dirnexFind"
    static let currentName = "dirnexFindCurrent"
    static let styleID = "dirnex-find-style"

    /// Every rendered text node walked in document order, as one string.
    ///
    /// `script`, `style` and `noscript` are skipped because they are code rather than text, and
    /// anything `checkVisibility` calls hidden is skipped because a match nobody can see cannot be
    /// scrolled to and would make the count disagree with the page. The walk is shared by `text` and
    /// `highlight`, so the offsets the one produces are the offsets the other spends.
    private static let walk = """
    function dirnexWalk(root) {
      const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
        acceptNode(node) {
          const parent = node.parentElement;
          if (!parent) { return NodeFilter.FILTER_REJECT; }
          const tag = parent.tagName;
          if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT') {
            return NodeFilter.FILTER_REJECT;
          }
          if (parent.checkVisibility && !parent.checkVisibility()) {
            return NodeFilter.FILTER_REJECT;
          }
          return NodeFilter.FILTER_ACCEPT;
        }
      });
      const nodes = [];
      let node;
      while ((node = walker.nextNode())) { nodes.push(node); }
      return nodes;
    }
    """

    /// What this frame's text is. `''` before the body exists, which is a page with nothing to find
    /// rather than an error.
    static let text = walk + """

    if (!document.body) { return ''; }
    return dirnexWalk(document.body).map(function (n) { return n.nodeValue; }).join('');
    """

    /// Highlight the ranges `spans` names — pairs of UTF-16 offsets into what `text` returned — with
    /// the one at `currentIndex` in the current colour.
    ///
    /// A text node's offsets *are* UTF-16 units, which is what makes the two agree: JavaScript
    /// strings are UTF-16 and `String.length` counts the same units ``DirnexCore/TextFindMatches``
    /// counts. A pair is located by binary search over the nodes' running start offsets, so a page
    /// with tens of thousands of nodes costs a logarithm per match rather than a scan.
    ///
    /// Returns how many ranges it drew, which is what a test reads to know the offsets landed.
    static let highlight = walk + """

    if (!document.body || typeof CSS === 'undefined' || !CSS.highlights) { return 0; }
    const nodes = dirnexWalk(document.body);
    const starts = [];
    let at = 0;
    for (const node of nodes) { starts.push(at); at += node.nodeValue.length; }
    function locate(offset) {
      let low = 0, high = nodes.length - 1, found = -1;
      while (low <= high) {
        const middle = (low + high) >> 1;
        if (starts[middle] <= offset) { found = middle; low = middle + 1; } else { high = middle - 1; }
      }
      if (found < 0) { return null; }
      return [nodes[found], offset - starts[found]];
    }
    const others = [], current = [];
    for (let index = 0; index < spans.length; index++) {
      const span = spans[index];
      const from = locate(span[0]), to = locate(span[1]);
      if (!from || !to) { continue; }
      // An offset landing exactly at a node's end belongs to that node's end, not to the next
      // node's start — `locate` answers the later node for it, which would make an empty range.
      const range = document.createRange();
      try {
        range.setStart(from[0], Math.min(from[1], from[0].nodeValue.length));
        range.setEnd(to[0], Math.min(to[1], to[0].nodeValue.length));
      } catch (error) { continue; }
      if (index === currentIndex) { current.push(range); } else { others.push(range); }
    }
    let style = document.getElementById('\(styleID)');
    if (!style) {
      style = document.createElement('style');
      style.id = '\(styleID)';
      (document.head || document.documentElement).appendChild(style);
    }
    style.textContent = styleText;
    CSS.highlights.set('\(allName)', new Highlight(...others));
    CSS.highlights.set('\(currentName)', new Highlight(...current));
    return others.length + current.length;
    """

    /// Take both highlights off and remove the rule. Leaves the page exactly as it was rendered.
    static let clear = """
    if (typeof CSS !== 'undefined' && CSS.highlights) {
      CSS.highlights.delete('\(allName)');
      CSS.highlights.delete('\(currentName)');
    }
    const style = document.getElementById('\(styleID)');
    if (style) { style.remove(); }
    return true;
    """

    /// Scroll the range `span` names into the middle of the frame, and say whether it was there to
    /// scroll to.
    static let reveal = walk + """

    if (!document.body) { return false; }
    const nodes = dirnexWalk(document.body);
    const starts = [];
    let at = 0;
    for (const node of nodes) { starts.push(at); at += node.nodeValue.length; }
    function locate(offset) {
      let low = 0, high = nodes.length - 1, found = -1;
      while (low <= high) {
        const middle = (low + high) >> 1;
        if (starts[middle] <= offset) { found = middle; low = middle + 1; } else { high = middle - 1; }
      }
      if (found < 0) { return null; }
      return [nodes[found], offset - starts[found]];
    }
    const from = locate(start), to = locate(end);
    if (!from || !to) { return false; }
    const range = document.createRange();
    try {
      range.setStart(from[0], Math.min(from[1], from[0].nodeValue.length));
      range.setEnd(to[0], Math.min(to[1], to[0].nodeValue.length));
    } catch (error) { return false; }
    // A collapsed range has no rectangle, so the element holding it is what gets scrolled to.
    const rect = range.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) {
      const holder = from[0].parentElement;
      if (holder) { holder.scrollIntoView({ block: 'center', inline: 'nearest' }); return true; }
      return false;
    }
    const top = rect.top + window.scrollY;
    const wanted = Math.max(0, top - (window.innerHeight / 2) + (rect.height / 2));
    window.scrollTo({ top: wanted, left: window.scrollX, behavior: 'instant' });
    return true;
    """

    /// The offset of the first text on screen, so a search begins in front of the reader rather than
    /// at the top of the page.
    static let visibleOffset = walk + """

    if (!document.body) { return 0; }
    const nodes = dirnexWalk(document.body);
    let at = 0;
    for (const node of nodes) {
      const holder = node.parentElement;
      if (holder) {
        const rect = holder.getBoundingClientRect();
        if (rect.bottom > 0) { return at; }
      }
      at += node.nodeValue.length;
    }
    return 0;
    """
}

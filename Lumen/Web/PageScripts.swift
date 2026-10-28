import Foundation

enum PageScripts {
    static let passwordWatcher = """
    (function () {
      if (window.__lumenPassword) return;
      window.__lumenPassword = true;
      function payload(form) {
        var pass = form.querySelector('input[type="password"]');
        if (!pass || !pass.value) return null;
        var user = form.querySelector('input[type="email"], input[autocomplete="username"], input[type="text"]');
        return { username: user ? String(user.value).slice(0, 256) : '', password: String(pass.value).slice(0, 1024) };
      }
      function send(form) {
        try {
          var data = payload(form);
          if (!data || !window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.lumenPassword) return;
          window.webkit.messageHandlers.lumenPassword.postMessage(data);
        } catch (e) {}
      }
      document.addEventListener('submit', function (event) {
        var form = event.target;
        if (form && form.querySelector) send(form);
      }, true);
      document.addEventListener('click', function (event) {
        var node = event.target;
        if (!node || !node.closest) return;
        var control = node.closest('button, input[type="submit"]');
        if (!control) return;
        var form = control.form || (control.closest ? control.closest('form') : null);
        if (form) send(form);
      }, true);
    })();
    """

    static let findEngine = """
    (function () {
      if (window.__lumenFind) return;
      function ensureStyle() {
        if (document.getElementById('lumen-find-style')) return;
        var style = document.createElement('style');
        style.id = 'lumen-find-style';
        style.textContent = '::highlight(lumen-find){background-color:#e89b2e;color:#141618}::highlight(lumen-current){background-color:#2ec4b6;color:#141618}';
        (document.head || document.documentElement).appendChild(style);
      }
      var api = {
        ranges: [],
        index: -1,
        clear: function () {
          this.ranges = [];
          this.index = -1;
          if (window.CSS && CSS.highlights) {
            CSS.highlights.delete('lumen-find');
            CSS.highlights.delete('lumen-current');
          }
        },
        paint: function () {
          if (!(window.CSS && CSS.highlights) || !this.ranges.length) return;
          var rest = this.ranges.filter((_, i) => i !== this.index);
          CSS.highlights.set('lumen-find', new Highlight(...rest));
          if (this.index >= 0) CSS.highlights.set('lumen-current', new Highlight(this.ranges[this.index]));
          var current = this.ranges[this.index];
          if (current && current.startContainer) {
            var el = current.startContainer.parentElement || current.startContainer;
            if (el && el.scrollIntoView) el.scrollIntoView({ block: 'center', inline: 'nearest' });
          }
        },
        run: function (query) {
          this.clear();
          var q = String(query || '');
          if (!q) return { count: 0, index: -1 };
          if (!(window.CSS && CSS.highlights && document.body)) {
            var found = window.find(q, false, false, true, false, true, false);
            return { count: found ? 1 : 0, index: found ? 0 : -1 };
          }
          ensureStyle();
          var needle = q.toLowerCase();
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          var node;
          var cap = 400;
          while ((node = walker.nextNode()) && this.ranges.length < cap) {
            var value = node.nodeValue || '';
            if (!value || value.length > 100000) continue;
            var hay = value.toLowerCase();
            var from = 0;
            var at = hay.indexOf(needle, from);
            while (at !== -1 && this.ranges.length < cap) {
              var range = document.createRange();
              range.setStart(node, at);
              range.setEnd(node, at + needle.length);
              this.ranges.push(range);
              from = at + Math.max(needle.length, 1);
              at = hay.indexOf(needle, from);
            }
          }
          this.index = this.ranges.length ? 0 : -1;
          this.paint();
          return { count: this.ranges.length, index: this.index };
        },
        step: function (delta) {
          if (!this.ranges.length) {
            var again = window.find && window.find(String(delta), false, delta < 0, true, false, true, false);
            return { count: again ? 1 : 0, index: 0 };
          }
          var count = this.ranges.length;
          this.index = (this.index + delta + count) % count;
          this.paint();
          return { count: count, index: this.index };
        }
      };
      window.__lumenFind = api;
    })();
    """

    static func permissionSource(_ site: SitePermissions) -> String {
        var parts: [String] = ["(function(){"]
        if site.notifications == .deny {
            parts.append("""
            try {
              if (window.Notification) {
                Notification.requestPermission = function () { return Promise.resolve('denied'); };
                Object.defineProperty(Notification, 'permission', { configurable: true, get: function () { return 'denied'; } });
              }
            } catch (e) {}
            """)
        }
        if site.location == .deny {
            parts.append("""
            try {
              var deny = function (_ok, err) { if (typeof err === 'function') err({ code: 1, message: 'denied' }); };
              if (navigator.geolocation) {
                navigator.geolocation.getCurrentPosition = deny;
                navigator.geolocation.watchPosition = function (_ok, err) { deny(_ok, err); return 0; };
              }
            } catch (e) {}
            """)
        }
        parts.append("})();")
        return parts.joined(separator: "\n")
    }

    static let pageContext = """
    (function () {
      var sel = '';
      try { sel = window.getSelection ? String(window.getSelection()) : ''; } catch (e) {}
      var text = '';
      try { text = document.body && document.body.innerText ? document.body.innerText : ''; } catch (e) {}
      return {
        title: document.title || '',
        selection: sel.slice(0, 1500),
        text: text.slice(0, 6000)
      };
    })()
    """

    static let hasPasswordField = """
    (function () {
      var el = document.querySelector('input[type="password"]');
      if (!el) return false;
      var rect = el.getBoundingClientRect();
      return rect.width > 0 && rect.height > 0;
    })()
    """

    static let fillLogin = """
    const pass = document.querySelector('input[type="password"]');
    if (!pass) return false;
    const root = pass.form || document;
    const user = root.querySelector('input[type="email"], input[autocomplete="username"], input[type="text"]');
    function setNative(el, value) {
      if (!el) return;
      const proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
      const desc = Object.getOwnPropertyDescriptor(proto, 'value');
      if (desc && desc.set) desc.set.call(el, value); else el.value = value;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
    setNative(user, username);
    setNative(pass, password);
    return true;
    """

    static let insertText = """
    const el = document.activeElement;
    if (!el) return false;
    const typing = el.matches && el.matches('input, textarea, [contenteditable="true"], [contenteditable=""]');
    if (!typing && !el.isContentEditable) return false;
    if (el.isContentEditable) {
      document.execCommand('insertText', false, text);
      return true;
    }
    const proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
    const desc = Object.getOwnPropertyDescriptor(proto, 'value');
    const start = el.selectionStart ?? String(el.value || '').length;
    const end = el.selectionEnd ?? start;
    const next = String(el.value || '').slice(0, start) + text + String(el.value || '').slice(end);
    if (desc && desc.set) desc.set.call(el, next); else el.value = next;
    el.dispatchEvent(new Event('input', { bubbles: true }));
    return true;
    """

    static let mediaPlaying = """
    (function () {
      var nodes = document.querySelectorAll('video, audio');
      for (var i = 0; i < nodes.length; i++) {
        var el = nodes[i];
        if (!el.paused && !el.ended) return true;
      }
      return false;
    })()
    """

    static let memoryProbe = """
    (function () {
      var transfer = 0;
      var resources = performance.getEntriesByType('resource');
      var cap = Math.min(resources.length, 400);
      for (var i = 0; i < cap; i++) {
        var entry = resources[i];
        transfer += entry.transferSize || entry.encodedBodySize || 0;
      }
      var nodes = 0;
      try { nodes = document.getElementsByTagName('*').length; } catch (e) {}
      return { transfer: transfer, nodes: nodes };
    })()
    """

    static let faviconHref = """
    (function () {
      var links = Array.prototype.slice.call(document.querySelectorAll('link[rel]'));
      var icons = links.filter(function (link) { return /icon/i.test(link.rel || ''); });
      var pick = icons.filter(function (link) { return !/apple-touch/i.test(link.rel || ''); })[0] || icons[0];
      if (pick && pick.href) return pick.href;
      return location.origin + '/favicon.ico';
    })()
    """

    static let rejectionText = """
    (function () {
      var body = document.body && document.body.innerText ? document.body.innerText : '';
      return body.slice(0, 1500);
    })()
    """

    /// Opt-in ghost text for ordinary text fields. Password fields are ignored.
    static let fieldGhost = """
    (function () {
      if (window.__lumenGhost) return;
      var current = null;
      var seq = 0;
      var shown = 0;
      var suffix = '';
      var box = document.createElement('div');
      box.setAttribute('data-lumen-ghost', '1');
      box.style.cssText = 'position:fixed;z-index:2147483646;pointer-events:none;color:#8b9088;white-space:pre;overflow:hidden;max-width:220px;';
      function hide() {
        suffix = '';
        box.textContent = '';
        if (box.parentNode) box.parentNode.removeChild(box);
      }
      function allowed(el) {
        if (!el) return false;
        var tag = el.tagName;
        if (tag !== 'INPUT' && tag !== 'TEXTAREA') return false;
        var type = (el.getAttribute('type') || 'text').toLowerCase();
        if (type === 'password' || type === 'hidden' || type === 'file' || type === 'checkbox' || type === 'radio' || type === 'submit' || type === 'button' || type === 'range' || type === 'color') return false;
        var auto = (el.getAttribute('autocomplete') || '').toLowerCase();
        if (auto.indexOf('password') !== -1) return false;
        return true;
      }
      function place(el) {
        if (!suffix) { hide(); return; }
        var style = getComputedStyle(el);
        var canvas = place.canvas || (place.canvas = document.createElement('canvas'));
        var ctx = canvas.getContext('2d');
        ctx.font = style.font;
        var caret = el.selectionStart == null ? String(el.value || '').length : el.selectionStart;
        var width = ctx.measureText(String(el.value || '').slice(0, caret)).width;
        var rect = el.getBoundingClientRect();
        var pad = parseFloat(style.paddingLeft) || 0;
        box.style.font = style.font;
        box.style.left = (rect.left + pad + width - (el.scrollLeft || 0) + 1) + 'px';
        box.style.top = (rect.top + (parseFloat(style.paddingTop) || 0)) + 'px';
        box.style.height = (parseFloat(style.lineHeight) || rect.height) + 'px';
        box.textContent = suffix;
        if (!box.parentNode) document.documentElement.appendChild(box);
      }
      function insert(el, extra) {
        var start = el.selectionStart == null ? String(el.value || '').length : el.selectionStart;
        var end = el.selectionEnd == null ? start : el.selectionEnd;
        var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
        var desc = Object.getOwnPropertyDescriptor(proto, 'value');
        var next = String(el.value || '').slice(0, start) + extra + String(el.value || '').slice(end);
        if (desc && desc.set) desc.set.call(el, next); else el.value = next;
        var pos = start + extra.length;
        if (el.setSelectionRange) el.setSelectionRange(pos, pos);
        el.dispatchEvent(new Event('input', { bubbles: true }));
      }
      document.addEventListener('focusin', function (event) {
        if (!allowed(event.target)) { current = null; hide(); return; }
        current = event.target;
      }, true);
      document.addEventListener('focusout', function () { hide(); }, true);
      document.addEventListener('input', function (event) {
        var el = event.target;
        if (!allowed(el) || !window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.lumenGhost) return;
        current = el;
        hide();
        var id = ++seq;
        var value = String(el.value || '').slice(0, 180);
        if (value.length < 2) return;
        var label = (el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.getAttribute('name') || '').slice(0, 80);
        setTimeout(function () {
          if (id !== seq || document.activeElement !== el) return;
          try {
            window.webkit.messageHandlers.lumenGhost.postMessage({ id: id, prefix: value, label: label });
          } catch (e) {}
        }, 500);
      }, true);
      document.addEventListener('keydown', function (event) {
        if (!suffix || !current || document.activeElement !== current) return;
        if (event.key === 'Escape') { hide(); return; }
        if (event.key !== 'Tab') return;
        event.preventDefault();
        var extra = suffix;
        hide();
        insert(current, extra);
      }, true);
      window.__lumenGhost = {
        show: function (id, text) {
          if (id !== seq || !current || document.activeElement !== current) return;
          suffix = text || '';
          if (!suffix) { hide(); return; }
          shown = id;
          place(current);
        }
      };
    })();
    """

    /// Installed on demand, only while the agent is running. Not a document-start script.
    static let agentInstall = """
    window.__lumenAgent = {
      nodes: [],
      label: function (el) {
        var text = '';
        try { text = el.getAttribute('aria-label') || el.getAttribute('placeholder') || el.innerText || el.getAttribute('title') || ''; } catch (e) {}
        return String(text).replace(/\\s+/g, ' ').trim().slice(0, 80);
      },
      secret: function (el) {
        var type = (el.getAttribute('type') || '').toLowerCase();
        var auto = (el.getAttribute('autocomplete') || '').toLowerCase();
        return type === 'password' || auto.indexOf('password') !== -1;
      },
      read: function () {
        this.nodes = [];
        var list = [];
        var found = document.querySelectorAll('a, button, input, textarea, select, [role="button"], [role="link"]');
        for (var n = 0; n < found.length && list.length < 24; n++) {
          var el = found[n];
          var rect = el.getBoundingClientRect();
          if (rect.width < 2 || rect.height < 2) continue;
          var type = (el.getAttribute('type') || '').toLowerCase();
          if (type === 'hidden' || type === 'file' || type === 'checkbox' || type === 'radio') continue;
          var secret = this.secret(el);
          var idx = this.nodes.length;
          this.nodes.push(el);
          var value = '';
          if (!secret && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA')) {
            try { value = String(el.value || '').slice(0, 40); } catch (e) {}
          }
          list.push({
            i: idx,
            tag: el.tagName.toLowerCase(),
            type: type,
            text: secret ? '' : this.label(el),
            name: String(el.getAttribute('name') || '').slice(0, 40),
            autocomplete: String(el.getAttribute('autocomplete') || '').slice(0, 40),
            secret: !!secret,
            value: value
          });
        }
        var body = '';
        try { body = document.body && document.body.innerText ? document.body.innerText.slice(0, 3500) : ''; } catch (e) {}
        return { title: document.title || '', url: String(location.href || ''), text: body, elements: list };
      },
      describe: function (i) {
        var el = this.nodes[i];
        if (!el || (el.isConnected === false)) return null;
        var type = (el.getAttribute('type') || '').toLowerCase();
        var secret = this.secret(el);
        return {
          i: i,
          tag: el.tagName.toLowerCase(),
          type: type,
          text: secret ? '' : this.label(el),
          name: String(el.getAttribute('name') || '').slice(0, 40),
          autocomplete: String(el.getAttribute('autocomplete') || '').slice(0, 40),
          secret: !!secret
        };
      },
      click: function (i) {
        var el = this.nodes[i];
        if (!el) return { ok: false, error: 'missing' };
        try { el.scrollIntoView({ block: 'center' }); } catch (e) {}
        try { el.focus(); } catch (e) {}
        el.click();
        return { ok: true };
      },
      type: function (i, text) {
        var el = this.nodes[i];
        if (!el) return { ok: false, error: 'missing' };
        if (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA') return { ok: false, error: 'not a field' };
        el.focus();
        var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
        var desc = Object.getOwnPropertyDescriptor(proto, 'value');
        if (desc && desc.set) desc.set.call(el, text); else el.value = text;
        el.dispatchEvent(new Event('input', { bubbles: true }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return { ok: true };
      },
      scroll: function (dir) {
        if (dir === 'top') window.scrollTo(0, 0);
        else window.scrollBy(0, dir === 'up' ? -480 : 480);
        return { ok: true };
      }
    };
    """

    static let readableMarkdown = """
    (function () {
      function skip(el) {
        var tag = el.tagName;
        if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'NOSCRIPT' || tag === 'SVG') return true;
        var hidden = el.getAttribute && el.getAttribute('aria-hidden') === 'true';
        return hidden;
      }
      function inline(node) {
        if (!node) return '';
        if (node.nodeType === 3) return node.nodeValue || '';
        if (node.nodeType !== 1 || skip(node)) return '';
        var tag = node.tagName;
        var text = Array.prototype.map.call(node.childNodes, inline).join('');
        if (tag === 'A') {
          var href = node.getAttribute('href') || '';
          return href ? '[' + text.trim() + '](' + href + ')' : text;
        }
        if (tag === 'CODE') return '`' + text.trim() + '`';
        if (tag === 'STRONG' || tag === 'B') return '**' + text.trim() + '**';
        if (tag === 'EM' || tag === 'I') return '*' + text.trim() + '*';
        if (tag === 'BR') return '\\n';
        return text;
      }
      function block(node, depth) {
        if (!node || node.nodeType !== 1 || skip(node)) return '';
        var tag = node.tagName;
        if (tag === 'H1' || tag === 'H2' || tag === 'H3' || tag === 'H4') {
          var level = Number(tag.slice(1));
          return '\\n' + '#'.repeat(level) + ' ' + inline(node).trim() + '\\n';
        }
        if (tag === 'PRE') return '\\n```\\n' + (node.innerText || '') + '\\n```\\n';
        if (tag === 'LI') return '\\n' + '  '.repeat(depth) + '- ' + inline(node).trim();
        if (tag === 'UL' || tag === 'OL') {
          return Array.prototype.map.call(node.children, function (child) { return block(child, depth + 1); }).join('');
        }
        if (tag === 'P' || tag === 'BLOCKQUOTE') return '\\n' + inline(node).trim() + '\\n';
        return Array.prototype.map.call(node.children, function (child) { return block(child, depth); }).join('');
      }
      var root = document.querySelector('article') || document.querySelector('main') || document.querySelector('[role="main"]') || document.body;
      if (!root) return '';
      var title = document.title ? '# ' + document.title + '\\n' : '';
      var url = location.href ? urlLine(location.href) : '';
      function urlLine(href) { return href + '\\n'; }
      var body = block(root, 0).replace(/\\n{3,}/g, '\\n\\n').trim();
      return (title + url + '\\n' + body).slice(0, 80000);
    })()
    """
}

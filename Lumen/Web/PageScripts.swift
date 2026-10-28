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
}

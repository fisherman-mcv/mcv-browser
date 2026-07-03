enum Reader {
    /// Витягає статтю (article/main/найбільший текстовий блок) і рендерить
    /// чисту типографіку. Виконується з боку застосунку, тож працює
    /// навіть коли JS сторінки вимкнено (Secure).
    static let js = """
    (function () {
      var pick = document.querySelector('article') || document.querySelector('main');
      if (!pick) {
        var best = null, score = 0;
        document.querySelectorAll('div, section').forEach(function (el) {
          var n = (el.innerText || '').length;
          if (n > score) { score = n; best = el; }
        });
        pick = best;
      }
      if (!pick) { return 'no-content'; }
      var title = document.title || '';
      var content = pick.innerHTML;
      document.documentElement.innerHTML =
        '<head><meta charset="utf-8">' +
        '<meta name="viewport" content="width=device-width,initial-scale=1">' +
        '<title>' + title + '</title><style>' +
        ':root{color-scheme:light dark;background:#F8F9FA;color:#1A1A1A}' +
        '@media (prefers-color-scheme:dark){:root{background:#0A0A0A;color:#EAEAEA}}' +
        'body{max-width:720px;margin:64px auto;padding:0 24px;' +
        'font:18px/1.8 -apple-system,BlinkMacSystemFont,"SF Pro",sans-serif;' +
        'background:inherit;color:inherit}' +
        'img,video,iframe{max-width:100%;height:auto;border-radius:8px}' +
        'h1{font-size:24px;font-weight:600;line-height:1.3;margin-bottom:24px}' +
        'h2,h3{font-family:inherit;font-weight:600;line-height:1.3}' +
        'pre{overflow-x:auto;background:rgba(108,92,231,.1);padding:16px;border-radius:8px;' +
        'font:14px/1.5 ui-monospace,SFMono-Regular,monospace}' +
        'a{color:#6C5CE7}' +
        '</style></head><body><h1>' + title + '</h1>' + content + '</body>';
      return 'ok';
    })();
    """
}

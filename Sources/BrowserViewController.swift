import UIKit
import WebKit

private let kSiteURL = "https://www.lanmei.me"

/// 转交 JS 消息，避免 WKUserContentController 强引用控制器造成循环引用
final class JSBridge: NSObject, WKScriptMessageHandler {
    weak var browser: BrowserViewController?
    init(_ browser: BrowserViewController) { self.browser = browser }

    func userContentController(_ controller: WKUserContentController,
                              didReceive message: WKScriptMessage) {
        switch message.name {
        case "media":
            if let u = message.body as? String { browser?.rememberMedia(u) }
        case "download":
            browser?.handleDownloadTap()
        default:
            break
        }
    }
}

final class BrowserViewController: UIViewController, WKNavigationDelegate, UITextFieldDelegate {

    private var webView: WKWebView!
    private var bridge: JSBridge!
    private var lastMediaURL: String?
    private var progressBar: UIProgressView!
    private var observing: NSKeyValueObservation?

    private let injectJS = """
    (function(){
      if (window.__zzHooked) return; window.__zzHooked = true;
      window.__zzLastUrl = '';
      function pub(u){
        try{
          if(!u || typeof u !== 'string') return;
          if(!/\\.m3u8|\\.mp4|\\.ts(\\?|$)/i.test(u)) return;
          window.__zzLastUrl = u;
          window.webkit.messageHandlers.media.postMessage(u);
        }catch(e){}
      }
      var open = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m,u){ try{ pub(u); }catch(e){} return open.apply(this, arguments); };
      var f = window.fetch;
      if (f) { window.fetch = function(input){ try{ pub(typeof input === 'string' ? input : (input && input.url)); }catch(e){} return f.apply(this, arguments); }; }
      ['loadedmetadata','play','playing'].forEach(function(ev){
        document.addEventListener(ev, function(e){
          var v = e.target;
          if (v && v.tagName === 'VIDEO') pub(v.currentSrc || v.src);
        }, true);
      });
      function addBtn(){
        if (!document.body || document.getElementById('zzdl-btn')) return;
        var b = document.createElement('div');
        b.id = 'zzdl-btn'; b.textContent = '下载';
        b.style.cssText = 'position:fixed;z-index:2147483647;top:12px;right:12px;padding:9px 15px;' +
          'border-radius:16px;background:rgba(0,0,0,.72);color:#fff;font-size:13px;font-weight:600;' +
          'border:1px solid rgba(255,255,255,.45);-webkit-backdrop-filter:blur(6px);';
        b.onclick = function(){
          try{ window.webkit.messageHandlers.download.postMessage(''); }catch(e){}
        };
        document.body.appendChild(b);
      }
      if (document.body) addBtn(); else document.addEventListener('DOMContentLoaded', addBtn);
      setInterval(addBtn, 2500);
    })();
    """

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "蓝莓视频"
        view.backgroundColor = .black

        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.allowsAirPlayForMediaPlayback = true
        cfg.websiteDataStore = .default()

        bridge = JSBridge(self)
        let ucc = WKUserContentController()
        ucc.add(bridge, name: "media")
        ucc.add(bridge, name: "download")
        ucc.addUserScript(WKUserScript(source: injectJS,
                                       injectionTime: .atDocumentStart,
                                       forMainFrameOnly: false))
        cfg.userContentController = ucc

        webView = WKWebView(frame: .zero, configuration: cfg)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.customUserAgent = MediaDownloader.userAgent
        view.addSubview(webView)

        progressBar = UIProgressView(progressViewStyle: .bar)
        progressBar.progressTintColor = UIColor(red: 0.49, green: 0.30, blue: 1.0, alpha: 1)
        progressBar.trackTintColor = .clear
        view.addSubview(progressBar)

        observing = webView.observe(\.estimatedProgress, options: .new) { [weak self] wv, _ in
            guard let self = self else { return }
            self.progressBar.progress = Float(wv.estimatedProgress)
            self.progressBar.isHidden = wv.estimatedProgress >= 1.0
        }

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "下载中心", style: .plain, target: self, action: #selector(openCenter))

        if let u = URL(string: kSiteURL) {
            webView.load(URLRequest(url: u))
        }
        NotificationCenter.default.addObserver(self, selector: #selector(updateBadge),
                                              name: .zzDownloadsChanged, object: nil)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = view.safeAreaInsets.top
        webView.frame = view.bounds
        progressBar.frame = CGRect(x: 0, y: top, width: view.bounds.width, height: 2)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        observing?.invalidate()
        webView?.configuration.userContentController.removeAllUserScripts()
    }

    // MARK: - 下载

    func rememberMedia(_ url: String) {
        lastMediaURL = url
    }

    func handleDownloadTap() {
        // 优先用 JS 侧记录的最新地址，拿不到再用原生记录
        webView.evaluateJavaScript("window.__zzLastUrl || ''") { [weak self] value, _ in
            guard let self = self else { return }
            var url = (value as? String) ?? ""
            if url.isEmpty { url = self.lastMediaURL ?? "" }
            guard !url.isEmpty else {
                self.alert("暂时没取到视频地址", "等视频开始播放后再点下载")
                return
            }
            self.promptAndEnqueue(url: url)
        }
    }

    private func promptAndEnqueue(url: String) {
        webView.evaluateJavaScript("document.title || ''") { [weak self] value, _ in
            guard let self = self else { return }
            var title = (value as? String) ?? ""
            if title.isEmpty || title.count < 2 { title = "视频_" + self.stamp() }
            let item = MediaDownloader.shared.enqueue(url: url, title: title)
            self.toast("已加入下载中心：\(item.title)")
            self.updateBadge()
        }
    }

    private func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMdd_HHmmss"
        return f.string(from: Date())
    }

    @objc private func updateBadge() {
        let active = MediaDownloader.shared.snapshot().filter {
            $0.state == .running || $0.state == .waiting
        }.count
        navigationItem.rightBarButtonItem?.title = active > 0 ? "下载中心(\(active))" : "下载中心"
    }

    @objc private func openCenter() {
        let vc = DownloadListViewController()
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    // MARK: - UI helpers

    private func alert(_ t: String, _ m: String) {
        let a = UIAlertController(title: t, message: m, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }

    private func toast(_ text: String) {
        let label = UILabel()
        label.text = text
        label.textColor = .white
        label.backgroundColor = UIColor.black.withAlphaComponent(0.8)
        label.font = .systemFont(ofSize: 13)
        label.numberOfLines = 2
        label.textAlignment = .center
        label.layer.cornerRadius = 10
        label.clipsToBounds = true
        label.frame = CGRect(x: 24, y: view.bounds.height - 140, width: view.bounds.width - 48, height: 52)
        view.addSubview(label)
        UIView.animate(withDuration: 0.3, delay: 2.2, options: []) {
            label.alpha = 0
        } completion: { _ in
            label.removeFromSuperview()
        }
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        progressBar.isHidden = true
        if let t = webView.title, !t.isEmpty { title = t }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        progressBar.isHidden = true
    }
}

import SwiftUI
import WebKit
import UniformTypeIdentifiers
import AVFoundation
import LocalAuthentication
import UIKit

@main
struct FallVaultApp: App {
    var body: some Scene {
        WindowGroup {
            WebShellView()
                .ignoresSafeArea()
                .preferredColorScheme(.dark)
        }
    }
}

/// WKWebView 壳：装 007-screens 原型跑（真机预览）
/// 桥接能力：
///   · openExternal —— 网页点「网站」→ 系统 Safari
///   · saveFile     —— 导出备份 / TOTP → 系统「文件」App 让用户选保存位置
///   · pickFile     —— 导入备份 → 系统「文件」App 让用户选文件，内容回传网页
struct WebShellView: UIViewRepresentable {

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.mediaTypesRequiringUserActionForPlayback = []
        cfg.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        // 注入 App 全屏模式：去掉顶部说明 / 手机边框 / 模拟状态栏，改成真机全屏
        let appModeJS = """
        (function(){
          function mark(){ try { document.documentElement.classList.add('app'); } catch(e){} }
          mark();
          document.addEventListener('DOMContentLoaded', mark);
        })();
        """
        cfg.userContentController.addUserScript(
            WKUserScript(source: appModeJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )

        // 全新安装检测：卸载重装后 WKWebView 的 localStorage 可能残留（iOS 已知坑），
        // 首次启动主动清空 WebKit 网站数据 → 真正回到"设置主密码"全新页面；覆盖升级则保留数据
        if !UserDefaults.standard.bool(forKey: "fvLaunchedOnce") {
            UserDefaults.standard.set(true, forKey: "fvLaunchedOnce")
            WKWebsiteDataStore.default().removeData(
                ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                modifiedSince: .distantPast) { }
            // JS 兜底（removeData 是异步的，HTML 可能先加载读到旧数据）：
            // document start 时清掉所有 FallVault 本地键 → 无论如何都从"设置主密码"开始
            let cleanupScript = "try{Object.keys(localStorage).forEach(function(k){if(k.indexOf('fv')===0||k.indexOf('fallvault')===0||k.indexOf('FallVault')===0){localStorage.removeItem(k)}})}catch(e){}"
            cfg.userContentController.addUserScript(
                WKUserScript(source: cleanupScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }

        let cc = cfg.userContentController
        cc.add(context.coordinator, name: "openExternal")
        cc.add(context.coordinator, name: "saveFile")
        cc.add(context.coordinator, name: "pickFile")
        cc.add(context.coordinator, name: "cameraOn")     // Face ID：原生摄像头（权限只问一次）
        cc.add(context.coordinator, name: "cameraOff")
        cc.add(context.coordinator, name: "faceIdAuth")    // 系统 Face ID 验证（LocalAuthentication）
        cc.add(context.coordinator, name: "faceIdCheck")   // 检查系统是否可用/已录入面容
        cc.add(context.coordinator, name: "vaultSave")     // 数据持久化：网页 → 沙盒文件（localStorage 不可靠）
        cc.add(context.coordinator, name: "vaultLoad")     // 启动加载：沙盒文件 → 网页

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.uiDelegate = context.coordinator
        wv.navigationDelegate = context.coordinator
        context.coordinator.webView = wv        // 供「文件」App 回调把内容回传网页

        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.scrollView.bounces = false
        wv.scrollView.contentInsetAdjustmentBehavior = .never
        wv.allowsBackForwardNavigationGestures = false

        // 内置资源加载（云更新已删除：一律从 bundle 加载）
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web/007-screens"),
            Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "007-screens"),
            Bundle.main.url(forResource: "index", withExtension: "html"),
        ]
        if let url = candidates.compactMap({ $0 }).first {
            wv.loadFileURL(url, allowingReadAccessTo: Bundle.main.bundleURL)
        } else {
            let msg = "找不到内置页面\n期望位置: web/007-screens/index.html\nbundle: \(Bundle.main.bundlePath)"
            let html = "<html><body style=\"background:#000;color:#fff;font:14px -apple-system;padding:24px;line-height:1.6\">\(msg)</body></html>"
            wv.loadHTMLString(html, baseURL: nil)
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    // MARK: - 原生桥
    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler {

        weak var webView: WKWebView?
        private var camera: CameraController?

        // 双保险：页面加载完成后强制进入 App 全屏模式（WKUserScript 万一失效也能兜底）
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.documentElement.classList.add('app')", completionHandler: nil)
        }

        func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
            switch message.name {
            case "openExternal":
                openExternally(message.body as? String)
            case "saveFile":
                guard let d = message.body as? [String: Any],
                      let name = d["name"] as? String,
                      let text = d["text"] as? String else { return }
                saveWithPicker(name: name, text: text)
            case "pickFile":
                pickWithPicker()
            case "vaultSave":
                // 数据持久化：网页每次保存 → 写入沙盒 Documents/fvdata.json（WKWebView localStorage 在 iOS 不可靠）
                guard let d = message.body as? [String: Any], let data = d["data"] as? String else { return }
                let fm = FileManager.default
                let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
                let file = docs.appendingPathComponent("fvdata.json")
                do {
                    try data.write(to: file, atomically: true, encoding: .utf8)
                } catch {}
            case "vaultLoad":
                // 读取沙盒持久化数据回传网页
                let fm = FileManager.default
                let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
                let file = docs.appendingPathComponent("fvdata.json")
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                // 必须用 JSON 序列化生成 JS 字符串字面量：
                // 手动转义只处理了 \\ 和 '，数据里一旦有换行（多行文本/格式化 JSON）
                // evaluateJavaScript 就会语法错误 → 真机上重启后永远加载不到数据
                callJS("window.__fvVaultLoaded && window.__fvVaultLoaded(" + Self.jsString(text) + ")")
            case "cameraOn":
                // Face ID 采集：网页传来取景框位置（CSS 像素），原生预览层盖在原位
                guard let d = message.body as? [String: Any] else { return }
                let rect = CGRect(x: (d["x"] as? Double) ?? 0,
                                  y: (d["y"] as? Double) ?? 0,
                                  width: (d["w"] as? Double) ?? 200,
                                  height: (d["h"] as? Double) ?? 200)
                DispatchQueue.main.async { [weak self] in
                    guard let self, let wv = self.webView else { return }
                    self.camera?.stop()
                    let cam = CameraController()
                    self.camera = cam
                    cam.start(on: wv, rect: rect)
                }
            case "cameraOff":
                DispatchQueue.main.async { [weak self] in
                    self?.camera?.stop()
                    self?.camera = nil
                }
            case "faceIdAuth":
                // 系统 Face ID / Touch ID 验证 → 结果回传 window.__fvFaceIdResult({ok,reason})
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let ctx = LAContext()
                    var err: NSError?
                    guard ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err) else {
                        let reason = (err?.code == LAError.biometryNotEnrolled.rawValue) ? "no-enroll" : "no-biometry"
                        self.callJS("window.__fvFaceIdResult && window.__fvFaceIdResult({ok:false,reason:'\(reason)'})")
                        return
                    }
                    ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                       localizedReason: "解锁 FallVault") { ok, error in
                        DispatchQueue.main.async {
                            if ok {
                                self.callJS("window.__fvFaceIdResult && window.__fvFaceIdResult({ok:true})")
                            } else {
                                let code = (error as NSError?)?.code ?? 0
                                let cancel = (code == LAError.userCancel.rawValue
                                              || code == LAError.systemCancel.rawValue
                                              || code == LAError.appCancel.rawValue)
                                self.callJS("window.__fvFaceIdResult && window.__fvFaceIdResult({ok:false,reason:'\(cancel ? "cancel" : "fail")'})")
                            }
                        }
                    }
                }
            case "faceIdCheck":
                // 检查系统生物识别可用性 → window.__fvFaceIdCheck({ok,enrolled})
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    let ctx = LAContext()
                    var err: NSError?
                    let can = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &err)
                    // enrolled 只在「设备可用但没录入」时为 false；其余情况按可用处理
                    let enrolled = can ? true : (err?.code != LAError.biometryNotEnrolled.rawValue)
                    self.callJS("window.__fvFaceIdCheck && window.__fvFaceIdCheck({ok:\(can),enrolled:\(enrolled)})")
                }
            default:
                break
            }
        }

        // window.open(url, '_blank') → 系统浏览器
        func webView(_ webView: WKWebView,
                     createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url { UIApplication.shared.open(url) }
            return nil
        }

        // 站内 http(s) 跳转一律外开，避免 WebView 变成浏览器
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url {
                let s = url.scheme?.lowercased() ?? ""
                if s == "http" || s == "https" {
                    UIApplication.shared.open(url)
                    decisionHandler(.cancel)
                    return
                }
            }
            decisionHandler(.allow)
        }

        private func callJS(_ js: String) {
            guard let wv = webView else { return }
            DispatchQueue.main.async { wv.evaluateJavaScript(js, completionHandler: nil) }
        }


        private func openExternally(_ raw: String?) {
            guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return }
            if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
                s = "https://" + s
            }
            if let url = URL(string: s) {
                DispatchQueue.main.async { UIApplication.shared.open(url) }
            }
        }

        /// 导出：写到临时文件 → 分享面板（含「存储到文件」=选保存位置；比 UIDocumentPicker 更可靠）
        private func saveWithPicker(name: String, text: String) {
            let safeName = name.replacingOccurrences(of: "/", with: "_")
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
            do {
                try Data(text.utf8).write(to: tmp, options: .atomic)
            } catch { return }
            DispatchQueue.main.async { [weak self] in
                guard let root = Self.topViewController() else { return }
                let avc = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
                avc.popoverPresentationController?.sourceView = root.view
                avc.popoverPresentationController?.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 0, height: 0)
                avc.excludedActivityTypes = [.addToReadingList, .assignToContact, .saveToCameraRoll]
                root.present(avc, animated: true)
            }
        }

        /// 导入：弹「文件」App 选文件 → 读成文本回传网页
        private func pickWithPicker() {
            DispatchQueue.main.async { [weak self] in
                guard let root = Self.topViewController() else { return }
                let types: [UTType] = [.data, .plainText, .json]
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
                picker.delegate = self
                root.present(picker, animated: true)
            }
        }

        private static func topViewController() -> UIViewController? {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow }
                ?? scenes.flatMap { $0.windows }.first
            var vc = window?.rootViewController
            while let p = vc?.presentedViewController { vc = p }
            return vc
        }
    }
}

// MARK: - 「文件」App 回调
extension WebShellView.Coordinator: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        // 导入：把文件内容回传给网页（网页端 window.__fvImported 接收）
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let name = url.lastPathComponent
        if let wv = webView {
            let js = "window.__fvImported && window.__fvImported(\(Self.jsString(name)), \(Self.jsString(text)))"
            DispatchQueue.main.async { wv.evaluateJavaScript(js) }
        } else {
            // 兜底：从配置里找回 webView
            for scene in UIApplication.shared.connectedScenes {
                guard let ws = scene as? UIWindowScene else { continue }
                for w in ws.windows {
                    if let wv = Self.findWebView(in: w) {
                        let js = "window.__fvImported && window.__fvImported(\(Self.jsString(name)), \(Self.jsString(text)))"
                        DispatchQueue.main.async { wv.evaluateJavaScript(js) }
                        return
                    }
                }
            }
        }
    }

    private static func findWebView(in view: UIView) -> WKWebView? {
        if let wv = view as? WKWebView { return wv }
        for sub in view.subviews {
            if let found = findWebView(in: sub) { return found }
        }
        return nil
    }

    private static func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [])
        guard let d = data, let arr = String(data: d, encoding: .utf8) else { return "\"\"" }
        return String(arr.dropFirst().dropLast())   // 去掉外层 []
    }
}

// MARK: - 原生摄像头（Face ID 采集）
// 为什么不用网页 getUserMedia：iOS 对 WKWebView 的摄像头权限不持久（每次冷启动都弹「允许」）。
// AVCaptureDevice.requestAccess 是系统级授权，用户点过一次「允许」后永久记住，不再弹窗。
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let ciContext = CIContext()
    private var preview: AVCaptureVideoPreviewLayer?
    private var lastJPEG: Data?
    private weak var webView: WKWebView?
    private var timer: Timer?

    func start(on wv: WKWebView, rect: CGRect) {
        webView = wv
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, granted else { return }
                self.configure(rect: rect)
            }
        }
    }

    private func configure(rect: CGRect) {
        session.beginConfiguration()
        session.sessionPreset = .medium
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: dev) else {
            session.commitConfiguration()
            return
        }
        if session.canAddInput(input) { session.addInput(input) }
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        ]
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "fv.camera"))
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()

        // 预览层直接盖在网页取景框的位置（网页侧已把 <video> 隐藏）
        let pl = AVCaptureVideoPreviewLayer(session: session)
        pl.videoGravity = .resizeAspectFill
        pl.frame = rect
        pl.cornerRadius = rect.width / 2          // 取景框都是圆形：锁屏 48px / 录入 200px
        pl.masksToBounds = true
        webView?.layer.addSublayer(pl)
        preview = pl

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.session.startRunning()
        }

        // 每 400ms 把最新一帧（~240px JPEG）推给网页做人脸检测
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            self?.pushFrame()
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        session.stopRunning()
        preview?.removeFromSuperlayer()
        preview = nil
        lastJPEG = nil
        webView = nil
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // ⚠️ 关键：sensor 原始帧是横的（90° 旋转），face-api 只认正立人脸 ——
        // 不转方向就会「一直显示没有人脸」。前置镜头再镜像一次，与预览层显示一致。
        if connection.isVideoOrientationSupported { connection.videoOrientation = .portrait }
        if connection.isVideoMirroringSupported { connection.isVideoMirrored = true }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let fullW = CGFloat(CVPixelBufferGetWidth(pb))
        let fullH = CGFloat(CVPixelBufferGetHeight(pb))
        guard fullW > 0, fullH > 0 else { return }
        let scale = 240.0 / fullW
        let target = CGSize(width: 240, height: fullH * scale)
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: fullW, height: fullH)) else { return }
        let img = UIImage(cgImage: cg)
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in
            img.draw(in: CGRect(origin: .zero, size: target))
        }
        lastJPEG = scaled.jpegData(compressionQuality: 0.7)
    }

    private func pushFrame() {
        guard let wv = webView, let data = lastJPEG else { return }
        let js = "window.__fvFrameSrc='data:image/jpeg;base64," + data.base64EncodedString() + "';"
        DispatchQueue.main.async { wv.evaluateJavaScript(js, completionHandler: nil) }
    }
}


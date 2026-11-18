import UIKit
import WebKit

func printView(webView: WKWebView){
    let printController = UIPrintInteractionController.shared

    let printInfo = UIPrintInfo(dictionary:nil)
    printInfo.outputType = UIPrintInfo.OutputType.general
    printInfo.jobName = (webView.url?.absoluteString)!
    printInfo.duplex = UIPrintInfo.Duplex.none
    printInfo.orientation = UIPrintInfo.Orientation.portrait

    printController.printPageRenderer = UIPrintPageRenderer()
          
    printController.printPageRenderer?.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)

    printController.printInfo = printInfo
    printController.showsNumberOfCopies = true
    printController.present(animated: true)
}


// MARK: - Native speech for languages the web view cannot see (for example Gujarati)
// Safari/WKWebView does not list every voice installed on the iPhone. app.html sends the text here
// when no web voice exists for the language, and Apple's own speech engine speaks it.
import AVFoundation

final class NativeSpeech: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = NativeSpeech()
    private let synth = AVSpeechSynthesizer()

    override init() {
        super.init()
        synth.delegate = self
    }

    // Language codes (for example "gu", "hi") that have a voice on this iPhone
    func voiceLanguages() -> [String] {
        var set = Set<String>()
        for v in AVSpeechSynthesisVoice.speechVoices() {
            if let base = v.language.split(separator: "-").first {
                set.insert(String(base).lowercased())
            }
        }
        return Array(set).sorted()
    }

    private func pickVoice(lang: String, gender: String) -> (AVSpeechSynthesisVoice?, Bool) {
        let base = lang.split(separator: "-").first.map { String($0).lowercased() } ?? lang.lowercased()
        let all = AVSpeechSynthesisVoice.speechVoices().filter {
            $0.language.lowercased().hasPrefix(base)
        }
        if all.isEmpty { return (AVSpeechSynthesisVoice(language: lang), false) }
        let best = all.sorted { $0.quality.rawValue > $1.quality.rawValue }
        if #available(iOS 17.0, *) {
            let want: AVSpeechSynthesisVoiceGender = (gender == "m") ? .male : .female
            if let match = best.first(where: { $0.gender == want }) { return (match, true) }
        }
        return (best.first, false)
    }

    func speak(text: String, lang: String, rate: Double, pitch: Double, volume: Double, gender: String) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {}
        let (voice, genderMatched) = pickVoice(lang: lang, gender: gender)
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        let r = Float(AVSpeechUtteranceDefaultSpeechRate) * Float(rate)
        u.rate = min(max(r, AVSpeechUtteranceMinimumSpeechRate), AVSpeechUtteranceMaximumSpeechRate)
        u.pitchMultiplier = genderMatched ? 1.0 : Float(min(max(pitch, 0.5), 2.0))
        u.volume = Float(min(max(volume, 0.0), 1.0))
        synth.speak(u)
    }

    func stop() {
        if synth.isSpeaking || synth.isPaused {
            synth.stopSpeaking(at: .immediate)
        }
    }

    // Tell the page one sentence has finished, so it can say the next one
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        DispatchQueue.main.async(execute: {
            AidovaAAC.webView.evaluateJavaScript("window.aidovaNativeSpeechDone && window.aidovaNativeSpeechDone()", completionHandler: nil)
        })
    }
}

func handleNativeSpeak(message: WKScriptMessage) {
    guard let str = message.body as? String,
          let data = str.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
          let text = obj["text"] as? String,
          let lang = obj["lang"] as? String else { return }
    let rate = (obj["rate"] as? Double) ?? 1.0
    let pitch = (obj["pitch"] as? Double) ?? 1.0
    let volume = (obj["volume"] as? Double) ?? 1.0
    let gender = (obj["gender"] as? String) ?? "f"
    NativeSpeech.shared.speak(text: text, lang: lang, rate: rate, pitch: pitch, volume: volume, gender: gender)
}

func handleNativeVoices() {
    let langs = NativeSpeech.shared.voiceLanguages()
    guard let data = try? JSONSerialization.data(withJSONObject: langs, options: []),
          let json = String(data: data, encoding: .utf8) else { return }
    DispatchQueue.main.async(execute: {
        AidovaAAC.webView.evaluateJavaScript("window.handleNativeVoices && window.handleNativeVoices('\(json)')", completionHandler: nil)
    })
}

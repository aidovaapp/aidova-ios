import WebKit
import FirebaseMessaging
import UserNotifications

class SubscribeMessage {
    var topic  = ""
    var eventValue = ""
    var unsubscribe = false
    struct Keys {
        static var TOPIC = "topic"
        static var UNSUBSCRIBE = "unsubscribe"
        static var EVENTVALUE = "eventValue"
    }
    convenience init(dict: Dictionary<String,Any>) {
        self.init()
        if let topic = dict[Keys.TOPIC] as? String {
            self.topic = topic
        }
        if let unsubscribe = dict[Keys.UNSUBSCRIBE] as? Bool {
            self.unsubscribe = unsubscribe
        }
        if let eventValue = dict[Keys.EVENTVALUE] as? String {
            self.eventValue = eventValue
        }
    }
}

func handleSubscribeTouch(message: WKScriptMessage) {
  // [START subscribe_topic]
    let subscribeMessages = parseSubscribeMessage(message: message)
    if (subscribeMessages.count > 0){
        let _message = subscribeMessages[0]
        if (_message.unsubscribe) {
            Messaging.messaging().unsubscribe(fromTopic: _message.topic) { error in }
        }
        else {
            Messaging.messaging().subscribe(toTopic: _message.topic) { error in }
        }
    }
    

  // [END subscribe_topic]
}

func parseSubscribeMessage(message: WKScriptMessage) -> [SubscribeMessage] {
    var subscribeMessages = [SubscribeMessage]()
    if let objStr = message.body as? String {

        let data: Data = objStr.data(using: .utf8)!
        do {
            let jsObj = try JSONSerialization.jsonObject(with: data, options: .init(rawValue: 0))
            if let jsonObjDict = jsObj as? Dictionary<String, Any> {
                let subscribeMessage = SubscribeMessage(dict: jsonObjDict)
                subscribeMessages.append(subscribeMessage)
            } else if let jsonArr = jsObj as? [Dictionary<String, Any>] {
                for jsonObj in jsonArr {
                    let sMessage = SubscribeMessage(dict: jsonObj)
                    subscribeMessages.append(sMessage)
                }
            }
        } catch _ {
            
        }
    }
    return subscribeMessages
}

func returnPermissionResult(isGranted: Bool){
    DispatchQueue.main.async(execute: {
        if (isGranted){
            AidovaAAC.webView.evaluateJavaScript("this.dispatchEvent(new CustomEvent('push-permission-request', { detail: 'granted' }))")
        }
        else {
            AidovaAAC.webView.evaluateJavaScript("this.dispatchEvent(new CustomEvent('push-permission-request', { detail: 'denied' }))")
        }
    })
}
func returnPermissionState(state: String){
    DispatchQueue.main.async(execute: {
        AidovaAAC.webView.evaluateJavaScript("this.dispatchEvent(new CustomEvent('push-permission-state', { detail: '\(state)' }))")
    })
}

func handlePushPermission() {
    UNUserNotificationCenter.current().getNotificationSettings () { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                let authOptions: UNAuthorizationOptions = [.alert, .badge, .sound]
                UNUserNotificationCenter.current().requestAuthorization(
                    options: authOptions,
                    completionHandler: { (success, error) in
                        if error == nil {
                            if success == true {
                                returnPermissionResult(isGranted: true)
                                DispatchQueue.main.async {
                                  UIApplication.shared.registerForRemoteNotifications()
                                }
                            }
                            else {
                                returnPermissionResult(isGranted: false)
                            }
                        }
                        else {
                            returnPermissionResult(isGranted: false)
                        }
                    }
                )
            case .denied:
                returnPermissionResult(isGranted: false)
            case .authorized, .ephemeral, .provisional:
                returnPermissionResult(isGranted: true)
            @unknown default:
                return;
            }
        }
}
func handlePushState() {
    UNUserNotificationCenter.current().getNotificationSettings () { settings in
        switch settings.authorizationStatus {
        case .notDetermined:
            returnPermissionState(state: "notDetermined")
        case .denied:
            returnPermissionState(state: "denied")
        case .authorized:
            returnPermissionState(state: "authorized")
        case .ephemeral:
            returnPermissionState(state: "ephemeral")
        case .provisional:
            returnPermissionState(state: "provisional")
        @unknown default:
            returnPermissionState(state: "unknown")
            return;
        }
    }
}

func checkViewAndEvaluate(event: String, detail: String) {
    if (!AidovaAAC.webView.isHidden && !AidovaAAC.webView.isLoading ) {
        DispatchQueue.main.async(execute: {
            AidovaAAC.webView.evaluateJavaScript("this.dispatchEvent(new CustomEvent('\(event)', { detail: \(detail) }))")
        })
    }
    else {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            checkViewAndEvaluate(event: event, detail: detail)
        }
    }
}

func handleFCMToken(){
    DispatchQueue.main.async(execute: {
        Messaging.messaging().token { token, error in
            if let error = error {
                print("Error fetching FCM registration token: \(error)")
                checkViewAndEvaluate(event: "push-token", detail: "ERROR GET TOKEN")
            } else if let token = token {
                print("FCM registration token: \(token)")
                checkViewAndEvaluate(event: "push-token", detail: "'\(token)'")
            }
        }   
    })
}

func sendPushToWebView(userInfo: [AnyHashable: Any]){
    var json = "";
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: userInfo)
        json = String(data: jsonData, encoding: .utf8)!
    } catch {
        print("ERROR: userInfo parsing problem")
        return
    }
    checkViewAndEvaluate(event: "push-notification", detail: json)
}

func sendPushClickToWebView(userInfo: [AnyHashable: Any]){
    var json = "";
    do {
        let jsonData = try JSONSerialization.data(withJSONObject: userInfo)
        json = String(data: jsonData, encoding: .utf8)!
    } catch {
        print("ERROR: userInfo parsing problem")
        return
    }
    checkViewAndEvaluate(event: "push-notification-click", detail: json)
}

// MARK: - Aidova reminders on this iPhone (timer, medicines, daily check-in)
// Scheduled by the phone itself (local notifications): no server and no Firebase.
// app.html sends JSON strings to window.webkit.messageHandlers['aidova-notify']:
//   {"action":"permission"}  -> asks iOS (only when the person turns a reminder on); replies window.aidovaNotifyResult('granted'|'denied')
//   {"action":"status"}      -> replies window.aidovaNotifyStatus('granted'|'denied'|'unknown')
//   {"action":"replace","prefix":"aidova.med.","items":[{id,title,body,at(ms)|hour+minute,sound}]}
//        removes every pending reminder whose id starts with prefix, then adds the items
//        (items with "at" ring once at that time; items with hour/minute ring every day)

func aidovaNotifyJS(_ js: String) {
    DispatchQueue.main.async { AidovaAAC.webView?.evaluateJavaScript(js, completionHandler: nil) }
}

func handleAidovaNotify(message: WKScriptMessage) {
    guard let s = message.body as? String, let data = s.data(using: .utf8),
          let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let action = o["action"] as? String else { return }
    let center = UNUserNotificationCenter.current()
    switch action {
    case "permission":
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            aidovaNotifyJS("window.aidovaNotifyResult&&window.aidovaNotifyResult('\(granted ? "granted" : "denied")')")
        }
    case "status":
        center.getNotificationSettings { st in
            var v = "unknown"
            if st.authorizationStatus == .authorized || st.authorizationStatus == .provisional { v = "granted" }
            if st.authorizationStatus == .denied { v = "denied" }
            aidovaNotifyJS("window.aidovaNotifyStatus&&window.aidovaNotifyStatus('\(v)')")
        }
    case "replace":
        let prefix = (o["prefix"] as? String) ?? ""
        guard prefix.hasPrefix("aidova.") else { return }
        let items = (o["items"] as? [[String: Any]]) ?? []
        center.getPendingNotificationRequests { reqs in
            let old = reqs.map { $0.identifier }.filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: old)
            for it in items {
                guard let id = it["id"] as? String, id.hasPrefix(prefix) else { continue }
                let content = UNMutableNotificationContent()
                content.title = (it["title"] as? String) ?? "Aidova"
                content.body = (it["body"] as? String) ?? ""
                if let snd = it["sound"] as? String, !snd.isEmpty {
                    content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: snd))
                } else {
                    content.sound = .default
                }
                content.userInfo = ["aidova": id]
                let trigger: UNNotificationTrigger
                if let at = (it["at"] as? NSNumber)?.doubleValue {
                    let secs = at / 1000.0 - Date().timeIntervalSince1970
                    if secs < 1 { continue }
                    trigger = UNTimeIntervalNotificationTrigger(timeInterval: secs, repeats: false)
                } else {
                    var dc = DateComponents()
                    dc.hour = (it["hour"] as? NSNumber)?.intValue ?? 9
                    dc.minute = (it["minute"] as? NSNumber)?.intValue ?? 0
                    trigger = UNCalendarNotificationTrigger(dateMatching: dc, repeats: true)
                }
                center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        }
    default:
        break
    }
}

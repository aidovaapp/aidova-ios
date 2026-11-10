import StoreKit
import WebKit

// Product IDs matching App Store Connect
enum AidovaProduct: String, CaseIterable {
    case premiumMonthly  = "app.aidova.aac.premium.monthly"
    case premiumYearly   = "app.aidova.aac.premium.yearly"
    case premplusMonthly = "app.aidova.aac.premplus.monthly"
    case premplusYearly  = "app.aidova.aac.premplus.yearly"
    
    var tier: String {
        switch self {
        case .premiumMonthly, .premiumYearly:   return "premium"
        case .premplusMonthly, .premplusYearly: return "premplus"
        }
    }
}

@MainActor
class StoreKitManager: NSObject, ObservableObject {
    
    static let shared = StoreKitManager()
    
    var webView: WKWebView?
    var products: [Product] = []
    // Free-trial info per product, so the page only offers "7 days free" to people who can still get it (Apple guideline 3.1.2)
    var introInfo: [String: (eligible: Bool, days: Int)] = [:]
    var transactionListener: Task<Void, Error>?
    
    override init() {
        super.init()
        transactionListener = listenForTransactions()
        Task { await loadProducts() }
    }
    
    deinit {
        transactionListener?.cancel()
    }
    
    // MARK: — Load products from App Store Connect
    func loadProducts() async {
        do {
            let productIds = AidovaProduct.allCases.map { $0.rawValue }
            products = try await Product.products(for: productIds)
            print("Aidova StoreKit: loaded \(products.count) products")
            await refreshIntroInfo()
        } catch {
            print("Aidova StoreKit: failed to load products — \(error)")
        }
    }
    
    // MARK: — Purchase
    func purchase(productId: String) async {
        guard let product = products.first(where: { $0.id == productId }) else {
            print("Aidova StoreKit: product not found — \(productId)")
            await sendToWebView(action: "purchase-failed", data: "Product not found. Please try again.")
            // Retry loading products
            await loadProducts()
            return
        }
        
        do {
            let result = try await product.purchase()
            
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await unlockPremium(for: productId)
                await transaction.finish()
                
            case .userCancelled:
                // User cancelled — no error shown, just close quietly
                await sendToWebView(action: "purchase-cancelled", data: "")
                
            case .pending:
                // Waiting for approval (e.g. Ask to Buy)
                await sendToWebView(action: "purchase-pending", data: "Your purchase is pending approval.")
                
            @unknown default:
                await sendToWebView(action: "purchase-failed", data: "Something went wrong. Please try again.")
            }
            
        } catch StoreKitError.notEntitled {
            await sendToWebView(action: "purchase-failed", data: "Not entitled to this purchase.")
        } catch StoreKitError.networkError {
            await sendToWebView(action: "purchase-failed", data: "No internet connection. Please try again.")
        } catch {
            await sendToWebView(action: "purchase-failed", data: "Purchase failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: — Restore purchases
    func restorePurchases() async {
        do {
            try await AppStore.sync()
            var restored = false
            
            for await result in Transaction.currentEntitlements {
                if let transaction = try? checkVerified(result) {
                    await unlockPremium(for: transaction.productID)
                    await transaction.finish()
                    restored = true
                }
            }
            
            if restored {
                await sendToWebView(action: "restore-success", data: "Your purchases have been restored.")
            } else {
                await sendToWebView(action: "restore-none", data: "No previous purchases found.")
            }
            
        } catch {
            await sendToWebView(action: "restore-failed", data: "Restore failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: — Listen for transactions (handles interrupted purchases, renewals)
    func listenForTransactions() -> Task<Void, Error> {
        return Task.detached {
            for await result in Transaction.updates {
                do {
                    let transaction = try await self.checkVerified(result)
                    await self.unlockPremium(for: transaction.productID)
                    await transaction.finish()
                } catch {
                    print("Aidova StoreKit: transaction verification failed — \(error)")
                }
            }
        }
    }
    
    // MARK: — Check current entitlements on launch
    func checkCurrentEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if let transaction = try? checkVerified(result) {
                await unlockPremium(for: transaction.productID)
                await transaction.finish()
            }
        }
    }
    
    // MARK: — Unlock premium in the PWA via JavaScript bridge
    func unlockPremium(for productId: String) async {
        guard let aidovaProduct = AidovaProduct(rawValue: productId) else { return }
        let tier = aidovaProduct.tier
        await sendToWebView(action: "purchase-success", data: tier)
    }
    
    // MARK: — Send message to JavaScript in the PWA
    func sendToWebView(action: String, data: String) async {
        guard let wv = webView else { return }
        let js = "window.handleStoreKitEvent('\(action)', '\(data.replacingOccurrences(of: "'", with: "\\'"))'); "
        DispatchQueue.main.async {
            wv.evaluateJavaScript(js) { _, error in
                if let error = error {
                    print("Aidova StoreKit: JS bridge error — \(error)")
                }
            }
        }
    }
    
    // MARK: — Verify transaction
    func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let safe):
            return safe
        }
    }
    
    // MARK: — Free trial: is there one, and can this person still use it?
    // Apple gives one introductory offer per subscription group, so after a trial has been used it is no longer offered.
    func refreshIntroInfo() async {
        var info: [String: (eligible: Bool, days: Int)] = [:]
        for p in products {
            guard let sub = p.subscription, let offer = sub.introductoryOffer, offer.paymentMode == .freeTrial else { continue }
            let eligible = await sub.isEligibleForIntroOffer
            var days = offer.period.value
            switch offer.period.unit {
            case .week: days = offer.period.value * 7
            case .month: days = offer.period.value * 30
            case .year: days = offer.period.value * 365
            default: break
            }
            info[p.id] = (eligible, days)
        }
        introInfo = info
    }

    // MARK: — Get available products as JSON for JavaScript
    func getProductsJSON() -> String {
        var arr: [[String: String]] = []
        for p in products {
            var item: [String: String] = [
                "id": p.id,
                "displayName": p.displayName,
                "description": p.description,
                "displayPrice": p.displayPrice
            ]
            if let intro = introInfo[p.id] {
                item["trialDays"] = String(intro.days)
                item["trialEligible"] = intro.eligible ? "1" : "0"
            }
            arr.append(item)
        }
        if let data = try? JSONSerialization.data(withJSONObject: arr),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "[]"
    }
}

import SwiftUI
import SafariServices
import AuthenticationServices

// Used for getting a public completion handler to inject an assignment that sets `item` to `nil`.
// INFO: It's not possible to access a completion handler from an `ASWebAuthenticationSession` instance
// because it has no public getter and setter for that.
public struct WebAuthenticationSession {
    
    public typealias CompletionHandler = ASWebAuthenticationSession.CompletionHandler
    
    // MARK: Representation Properties
    
    let url: URL
    let callbackURLScheme: String?
    let completionHandler: CompletionHandler
    
    public init(
        url: URL,
        callbackURLScheme: String?,
        completionHandler: @escaping CompletionHandler
    ) {
        self.url = url
        self.callbackURLScheme = callbackURLScheme
        self.completionHandler = completionHandler
    }
    
    // MARK: Modifiers
    
    var prefersEphemeralWebBrowserSession: Bool = false
    
    public func prefersEphemeralWebBrowserSession(_ prefersEphemeralWebBrowserSession: Bool) -> Self {
        var modified = self
        modified.prefersEphemeralWebBrowserSession = prefersEphemeralWebBrowserSession
        return modified
    }
    
    // MARK: Modification Applier
    
    func applyModification(to webAuthenticationSession: ASWebAuthenticationSession) {
        webAuthenticationSession.prefersEphemeralWebBrowserSession = self.prefersEphemeralWebBrowserSession
    }
}

// Used for providing `presentationContextProvider`, which is needed for `ASWebAuthenticationSession` to start its session.
// INFO: `ASWebAuthenticationPresentationContextProviding` provides an window
// to present an `SFAuthenticationViewController`, and usually presents the `SFAuthenticationViewController`
// by calling `present(_:animated:completion:)` method from a root view controller of the window.
class WebAuthenticationSessionViewController: UIViewController, ASWebAuthenticationPresentationContextProviding {
    
    // MARK: ASWebAuthenticationPresentationContextProviding
    
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        return view.window!
    }
}

struct WebAuthenticationSessionHosting<Item: Identifiable>: UIViewControllerRepresentable {
    
    // MARK: Representation
    
    @Binding var item: Item?
    var representationBuilder: (Item) -> WebAuthenticationSession
    
    // MARK: UIViewControllerRepresentable
    
    func makeUIViewController(context: Context) -> WebAuthenticationSessionViewController {
        return WebAuthenticationSessionViewController()
    }
    
    func updateUIViewController(_ uiViewController: WebAuthenticationSessionViewController, context: Context) {
        
        // To set a delegate for the presentation controller of an `SFAuthenticationViewController` as soon as possible,
        // check the view controller presented by `uiViewController` then set it as a delegate on every view updates.
        // INFO: `SFAuthenticationViewController` is a private subclass of `SFSafariViewController`.
        setInteractiveDismissalDelegateToSafariViewController(presentedBy: uiViewController, in: context)
        
        // Ensure the following statements are executed once only after the item is changed
        // by comparing current item to old one during frequent view updates.
        let itemUpdateChange = context.coordinator.itemStorage.updateItem(item)
        
        switch itemUpdateChange { // (oldItem, newItem)
        case (.none, .none):
            ()
        case let (.none, .some(newItem)):
            startWebAuthenticationSession(on: uiViewController, in: context, using: newItem)
        case (.some, .some):
            ()
        case (.some, .none):
            cancelWebAuthenticationSession(in: context)
        }
    }
    
    // MARK: Update Handlers
    
    // There was a problem that `item` is not set to `nil` after the sheet is dismissed with pulling down
    // because the completion handler is not called on this case due to a system bug.
    // To resolve this issue, it sets `PresentationControllerDismissalDelegate` of `Coordinator`
    // as a presentation controller delegate of `SFAuthenticationViewController`
    // so that ensures the completion handler is always called.
    private func setInteractiveDismissalDelegateToSafariViewController(presentedBy uiViewController: UIViewController, in context: Context) {
        guard let safariViewController = uiViewController.presentedViewController as? SFSafariViewController else {
            return
        }
        safariViewController.presentationController?.delegate = context.coordinator.interactiveDismissalDelegate
    }
    
    private func startWebAuthenticationSession(on presentationContextProvider: ASWebAuthenticationPresentationContextProviding, in context: Context, using item: Item) {
        let representation = representationBuilder(item)
        let session = ASWebAuthenticationSession(
            url: representation.url,
            callbackURLScheme: representation.callbackURLScheme,
            completionHandler: { (callbackURL, error) in
                self.resetItemBinding()
                representation.completionHandler(callbackURL, error)
            }
        )
        representation.applyModification(to: session)
        session.presentationContextProvider = presentationContextProvider
        
        context.coordinator.session = session
        session.start()
    }
    
    private func cancelWebAuthenticationSession(in context: Context) {
        context.coordinator.session?.cancel()
        context.coordinator.session = nil
    }
    
    // MARK: Dismissal Handlers
    
    private func resetItemBinding() {
        self.item = nil
    }
    
    // MARK: Coordinator
    
    func makeCoordinator() -> Coordinator {
        return Coordinator(onInteractiveDismiss: resetItemBinding)
    }
    
    class Coordinator {
        
        var session: ASWebAuthenticationSession?
        var itemStorage: ItemStorage<Item>
        let interactiveDismissalDelegate: InteractiveDismissalDelegate
        
        init(onInteractiveDismiss: @escaping () -> Void) {
            self.itemStorage = ItemStorage()
            self.interactiveDismissalDelegate = InteractiveDismissalDelegate(onInteractiveDismiss: onInteractiveDismiss)
        }
    }
    
    class InteractiveDismissalDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
        
        private let onInteractiveDismiss: () -> Void
        
        init(onInteractiveDismiss: @escaping () -> Void) {
            self.onInteractiveDismiss = onInteractiveDismiss
        }
        
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onInteractiveDismiss()
        }
    }
}

struct WebAuthenticationSessionPresentationModifier: ViewModifier {
    
    @Binding var isPresented: Bool
    var representationBuilder: () -> WebAuthenticationSession
    
    private var item: Binding<Bool?> {
        .init(
            get: { self.isPresented ? true : nil },
            set: { self.isPresented = ($0 != nil) }
        )
    }
    
    // Converts `() -> Void` closure to `(Bool) -> Void`
    private func itemRepresentationBuilder(bool: Bool) -> WebAuthenticationSession {
        return representationBuilder()
    }
    
    func body(content: Content) -> some View {
        content.background(
            WebAuthenticationSessionHosting(
                item: item,
                representationBuilder: itemRepresentationBuilder
            )
        )
    }
}

struct ItemWebAuthenticationSessionPresentationModifier<Item: Identifiable>: ViewModifier {
    
    @Binding var item: Item?
    var representationBuilder: (Item) -> WebAuthenticationSession
    
    func body(content: Content) -> some View {
        content.background(
            WebAuthenticationSessionHosting(
                item: $item,
                representationBuilder: representationBuilder
            )
        )
    }
}

public extension View {
    
    /// Starts a web authentication session when a given condition is true.
    ///
    /// - Parameters:
    ///   - isPresented: A binding to whether the web authentication session should be started.
    ///   - content: A closure returning the `WebAuthenticationSession` to start.
    func webAuthenticationSession(
        isPresented: Binding<Bool>,
        content representationBuilder: @escaping () -> WebAuthenticationSession
    ) -> some View {
        self.modifier(
            WebAuthenticationSessionPresentationModifier(
                isPresented: isPresented,
                representationBuilder: representationBuilder
            )
        )
    }
    
    // FIXME: Dismiss and replace the view if the identity changes
    
    /// Starts a web authentication session using the given item as a data source
    /// for the `WebAuthenticationSession` to start.
    ///
    /// - Parameters:
    ///   - item: A binding to an optional source of truth for the web authentication session.
    ///     When representing a non-`nil` item, the system uses `content` to
    ///     create a session representation of the item.
    ///     If the identity changes, the system cancels a
    ///     currently-started session and replace it by a new session.
    ///   - content: A closure returning the `WebAuthenticationSession` to start.
    func webAuthenticationSession<Item: Identifiable>(
        item: Binding<Item?>,
        content representationBuilder: @escaping (Item) -> WebAuthenticationSession
    ) -> some View {
        self.modifier(
            ItemWebAuthenticationSessionPresentationModifier(
                item: item,
                representationBuilder: representationBuilder
            )
        )
    }
}

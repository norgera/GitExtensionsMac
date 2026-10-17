import GitExtensionsCore
import AppKit

@MainActor
final class FilePreviewPresentation<Value: Sendable>: NSObject {
    enum State: Equatable { case empty, deferred, loading, displayed }
    private(set) var state: State = .empty
    private(set) var generation = 0
    let button = NSButton()
    private var pending: (@Sendable () async throws -> Value)?
    private var task: Task<Void, Never>?
    private var display: ((Value) -> Void)?
    private var failure: ((Error) -> Void)?

    override init() {
        super.init()
        button.title = ""
        button.isBordered = false
        button.bezelStyle = .inline
        button.target = self
        button.action = #selector(showAnyway)
        button.isHidden = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier("FileViewer.ShowLargePreview")
    }

    func install(in view: NSView) {
        view.addSubview(button)
        NSLayoutConstraint.activate([button.centerXAnchor.constraint(equalTo: view.centerXAnchor), button.centerYAnchor.constraint(equalTo: view.centerYAnchor), button.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12), button.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12)])
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        pending = nil
        display = nil
        failure = nil
        button.isHidden = true
        state = .empty
    }

    func present(_ preview: FilePreview<Value>, display: @escaping (Value) -> Void, failure: @escaping (Error) -> Void) {
        cancel()
        self.display = display
        self.failure = failure
        switch preview {
        case .ready(let value):
            state = .displayed
            display(value)
        case .deferred(let length, let load):
            pending = load
            state = .deferred
            button.title = String(format: "This file is %.1f MB. Showing large files can be slow. Click to show anyway.", Double(length) / (1024 * 1024))
            button.isHidden = false
        }
    }

    @objc func showAnyway() {
        guard state == .deferred, let pending else { return }
        self.pending = nil
        state = .loading
        button.isHidden = true
        let token = generation
        task = Task { @MainActor [weak self] in
            do {
                let value = try await pending()
                guard let self, !Task.isCancelled, token == generation else { return }
                state = .displayed
                display?(value)
            } catch is CancellationError {
                return
            } catch {
                guard let self, !Task.isCancelled, token == generation else { return }
                state = .empty
                failure?(error)
            }
        }
    }
}

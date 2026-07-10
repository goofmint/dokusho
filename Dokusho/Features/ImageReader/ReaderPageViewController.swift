import UIKit

/// Displays one ``ReaderSpread`` (single page or two-page spread) with pinch and
/// double-tap zoom (1x–4x) inside a `UIScrollView`.
///
/// The zoom scroll view sits *inside* each `UIPageViewController` child so that
/// pinch/pan gestures resolve against the page-turn swipe cleanly (design.md
/// §2.3 rationale for choosing `UIPageViewController` over SwiftUI paging).
///
/// Page numbers are **1-based**. For a spread, the two images are laid out
/// side-by-side; `progression` decides which page is on the left vs right:
/// - LTR: reading-order `first` on the **left**, `second` on the **right**.
/// - RTL: reading-order `first` on the **right**, `second` on the **left**.
final class ReaderPageViewController: UIViewController, UIScrollViewDelegate {
    /// The spread this controller renders. Fixed for the controller's lifetime.
    let spread: ReaderSpread
    /// The index of this spread within the layout (used by the pager delegate).
    let spreadIndex: Int

    private let progression: ReadingProgression
    private let backgroundColor: UIColor

    private let scrollView = UIScrollView()
    /// Container holding one or two image views laid out horizontally.
    private let contentStack = UIStackView()

    /// Image views keyed by 1-based page number, so async loads can find them.
    private var imageViews: [Int: UIImageView] = [:]
    /// Loading/error overlays keyed by page number.
    private var overlays: [Int: PageOverlayView] = [:]

    /// Called when the user taps "再試行" on a failed page. Passes the page number.
    var onRetry: ((Int) -> Void)?

    init(
        spread: ReaderSpread,
        spreadIndex: Int,
        progression: ReadingProgression,
        backgroundColor: UIColor
    ) {
        self.spread = spread
        self.spreadIndex = spreadIndex
        self.progression = progression
        self.backgroundColor = backgroundColor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = backgroundColor
        configureScrollView()
        configureContent()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Keep content sized to the viewport at 1x and centered.
        scrollView.frame = view.bounds
        if scrollView.zoomScale == scrollView.minimumZoomScale {
            contentStack.frame = scrollView.bounds
        }
        centerContent()
    }

    // MARK: - Setup

    private func configureScrollView() {
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        view.addSubview(scrollView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
    }

    private func configureContent() {
        contentStack.axis = .horizontal
        contentStack.alignment = .fill
        contentStack.distribution = .fillEqually
        contentStack.spacing = 0
        scrollView.addSubview(contentStack)

        // Build image views in *visual* (left-to-right) order.
        for page in visualPageOrder() {
            let container = makePageContainer(for: page)
            contentStack.addArrangedSubview(container)
        }
    }

    /// The page numbers in left-to-right *visual* order for this spread.
    private func visualPageOrder() -> [Int] {
        switch spread {
        case let .single(page):
            return [page]
        case let .spread(first, second):
            // Reading order is (first, second). For RTL the first-read page sits
            // on the right, so the visual left-to-right order is reversed.
            return progression.isRightToLeft ? [second, first] : [first, second]
        }
    }

    private func makePageContainer(for page: Int) -> UIView {
        let container = UIView()
        container.backgroundColor = .clear

        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFit
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(imageView)
        imageViews[page] = imageView

        let overlay = PageOverlayView { [weak self] in
            self?.onRetry?(page)
        }
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay)
        overlays[page] = overlay
        overlay.showLoading()

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: container.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            overlay.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        return container
    }

    // MARK: - Image updates (called from the SwiftUI coordinator, main actor)

    /// Sets the loaded image for a page and hides its overlay.
    func setImage(_ image: UIImage, for page: Int) {
        guard let imageView = imageViews[page] else { return }
        imageView.image = image
        overlays[page]?.hide()
    }

    /// Shows the loading spinner for a page (e.g. on retry).
    func showLoading(for page: Int) {
        overlays[page]?.showLoading()
    }

    /// Shows the tap-to-retry error state for a page.
    func showError(for page: Int) {
        overlays[page]?.showError()
    }

    // MARK: - Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        contentStack
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
    }

    private func centerContent() {
        let boundsSize = scrollView.bounds.size
        var frame = contentStack.frame
        frame.origin.x = frame.width < boundsSize.width ? (boundsSize.width - frame.width) / 2 : 0
        frame.origin.y = frame.height < boundsSize.height ? (boundsSize.height - frame.height) / 2 : 0
        contentStack.frame = frame
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if scrollView.zoomScale > scrollView.minimumZoomScale {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
        } else {
            let point = gesture.location(in: contentStack)
            let targetScale: CGFloat = 2
            let size = scrollView.bounds.size
            let width = size.width / targetScale
            let height = size.height / targetScale
            let rect = CGRect(
                x: point.x - width / 2,
                y: point.y - height / 2,
                width: width,
                height: height
            )
            scrollView.zoom(to: rect, animated: true)
        }
    }
}

/// A small overlay shown over a page while it loads or when it fails.
///
/// - Loading: an activity spinner.
/// - Error: a message with a tappable "再試行" button.
private final class PageOverlayView: UIView {
    private let spinner = UIActivityIndicatorView(style: .large)
    private let stack = UIStackView()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let onRetry: () -> Void

    init(onRetry: @escaping () -> Void) {
        self.onRetry = onRetry
        super.init(frame: .zero)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func configure() {
        spinner.hidesWhenStopped = true
        spinner.color = .secondaryLabel

        messageLabel.text = "画像を読み込めませんでした"
        messageLabel.textColor = .secondaryLabel
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.textAlignment = .center

        retryButton.setTitle("再試行", for: .normal)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .touchUpInside)

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(retryButton)
        stack.isHidden = true

        addSubview(spinner)
        addSubview(stack)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    func showLoading() {
        stack.isHidden = true
        spinner.startAnimating()
        isHidden = false
    }

    func showError() {
        spinner.stopAnimating()
        stack.isHidden = false
        isHidden = false
    }

    func hide() {
        spinner.stopAnimating()
        isHidden = true
    }

    @objc private func retryTapped() {
        onRetry()
    }
}

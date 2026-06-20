import AppKit
import ImageIO
import AVKit
import AVFoundation
import Photos
import PhotosUI
import PlateCore

/// Photos-app-style single-asset viewer. No persistent HUD bar — image fills
/// the window, and four floating controls (close, prev, next, metadata label)
/// auto-hide after 2 s of mouse inactivity. Loads via ImageIO downsampled to
/// 4096 px so 100MP HEIC / 3FR stays under ~200MB peak and decodes in ~0.5 s.
final class DetailViewController: NSViewController {

    private let library: PlateLibrary
    private var assets: [Asset]
    private var currentIndex: Int
    private let onClose: () -> Void

    private let imageView = NonGreedyImageView()
    private let imageScrollView = NSScrollView()

    /// Video + Live Photo playback surfaces, created lazily the first time a
    /// non-still asset is shown and reused thereafter. Both are inserted *below*
    /// the `chrome` overlay so the close / nav / caption controls stay on top.
    private var playerView: AVPlayerView?
    private var player: AVPlayer?
    private var livePhotoView: PHLivePhotoView?
    /// The Live Photo view lives inside its own magnifying scroll view so the
    /// still is pinch-to-zoomable exactly like a regular photo; the motion still
    /// plays (auto on open, or by hovering the badge).
    private var livePhotoScrollView: NSScrollView?
    /// Our own "LIVE" badge, pinned top-right at a fixed size. PHLivePhotoView's
    /// built-in badge sits *inside* the zoom scroll view and shrinks with the
    /// fit magnification (tiny, bottom-left), so we hide that and draw this.
    /// Click it to replay the motion.
    private let liveBadge = NSView()
    private let liveBadgeLabel = NSTextField(labelWithString: "")

    /// Which surface is currently front-most. Drives `setMediaMode` show/hide.
    private enum MediaMode { case image, video, livePhoto }
    /// Whole-window overlay holding the floating buttons / caption / strip.
    /// Uses `PassThroughView` so empty areas don't swallow pinch-to-zoom or
    /// two-finger pan gestures — those need to reach the imageScrollView below.
    private let chrome = PassThroughView()
    private let captionPill = NSVisualEffectView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let strip = ThumbnailStrip()
    private let closeButton: FloatingButton
    private let favoriteButton: FloatingButton
    private let infoButton: FloatingButton
    private let prevButton: FloatingButton
    private let nextButton: FloatingButton

    /// Top-right EXIF panel, toggled by the info button. A chrome subview so it
    /// fades with the rest of the overlay; `exifVisible` keeps it shown across
    /// prev/next navigation until the user dismisses it.
    private let exifPanel = NSVisualEffectView()
    private let exifLabel = NSTextField(labelWithString: "")
    private var exifVisible = false

    private static let captionDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var loadGeneration = 0
    private var hideTimer: Timer?

    /// Pixel ceiling of the currently-loaded image for the active asset.
    /// Starts at 4096 (snappy fit-display); upgraded to 8192 once the user
    /// zooms in past 1.5× fit so detail stays crisp without paying the high-
    /// res decode + memory cost on every navigation.
    private var loadedAtMaxPixel: Int = 0
    private static let fastMaxPixel: Int = 4096
    private static let detailMaxPixel: Int = 8192
    /// The lightweight (fastMaxPixel) decode of the *current* asset, kept around
    /// so we can swap straight back to it when the user zooms out — no re-decode,
    /// and the heavy detail image is released instead of lingering in memory.
    private var fastImage: NSImage?

    init(library: PlateLibrary,
         assets: [Asset],
         startIndex: Int,
         onClose: @escaping () -> Void)
    {
        self.library = library
        self.assets = assets
        self.currentIndex = startIndex
        self.onClose = onClose
        self.closeButton    = FloatingButton(symbol: "xmark",          size: 28, weight: .medium)
        self.favoriteButton = FloatingButton(symbol: "heart",          size: 28, weight: .medium)
        self.infoButton     = FloatingButton(symbol: "info.circle",    size: 28, weight: .medium)
        self.prevButton     = FloatingButton(symbol: "chevron.left",   size: 44, weight: .regular)
        self.nextButton     = FloatingButton(symbol: "chevron.right",  size: 44, weight: .regular)
        super.init(nibName: nil, bundle: nil)
        self.closeButton.action    = { [weak self] in self?.close(nil) }
        self.favoriteButton.action = { [weak self] in self?.toggleFavorite(nil) }
        self.infoButton.action     = { [weak self] in self?.toggleExif() }
        self.prevButton.action     = { [weak self] in self?.previous(nil) }
        self.nextButton.action     = { [weak self] in self?.nextItem(nil) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() {
        let v = MouseTrackingView(frame: NSRect(x: 0, y: 0, width: 1280, height: 820))
        v.wantsLayer = true
        v.layer?.backgroundColor = PlateColor.primary.cgColor
        v.onMouseMoved = { [weak self] in self?.showChrome() }
        view = v

        // Wrap the image view in an NSScrollView so we get native trackpad
        // pinch-to-zoom + two-finger pan.
        //
        // Sizing convention: the imageView's frame matches the *image's pixel
        // size* (set on every load via applyImage), so magnification means
        // exactly what it says — 1.0 is 1:1 pixel, fitMag is "fit to window".
        // We start at fitMag, clamp min to fitMag (no zooming out below fit),
        // and cap max at 6× fit. CenteringClipView centers the photo when its
        // scaled size is smaller than the visible area on either axis.
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        imageView.frame = .zero

        let centeringClip = CenteringClipView()
        centeringClip.drawsBackground = false
        imageScrollView.contentView = centeringClip

        imageScrollView.hasHorizontalScroller = false
        imageScrollView.hasVerticalScroller = false
        imageScrollView.scrollerStyle = .overlay
        imageScrollView.borderType = .noBorder
        imageScrollView.drawsBackground = false
        imageScrollView.allowsMagnification = true
        imageScrollView.minMagnification = 0.01    // placeholder; recomputed per image
        imageScrollView.maxMagnification = 6.0
        imageScrollView.usesPredominantAxisScrolling = false
        imageScrollView.documentView = imageView
        imageScrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(imageScrollView)

        chrome.wantsLayer = true
        chrome.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(chrome)

        // Editorial top-center caption inside a translucent pill. Pill gives
        // legibility on top of light photos (text was illegible against snow /
        // sky before); HUD material + 6pt radius matches macOS HUD windows.
        captionPill.material = .hudWindow
        captionPill.state = .active
        captionPill.blendingMode = .withinWindow
        captionPill.wantsLayer = true
        captionPill.layer?.cornerRadius = 6
        captionPill.layer?.masksToBounds = true
        captionPill.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.alignment = .center
        metaLabel.lineBreakMode = .byTruncatingTail

        strip.library = library
        strip.assets = assets
        strip.currentIndex = currentIndex
        strip.onSelect = { [weak self] idx in
            guard let self = self, idx != self.currentIndex else { return }
            self.currentIndex = idx
            self.loadCurrent()
        }
        strip.translatesAutoresizingMaskIntoConstraints = false

        for sub in [closeButton, favoriteButton, infoButton, prevButton, nextButton, strip, captionPill, exifPanel] {
            sub.translatesAutoresizingMaskIntoConstraints = false
            chrome.addSubview(sub)
        }
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        captionPill.addSubview(titleLabel)
        captionPill.addSubview(metaLabel)

        // EXIF panel — HUD pill in the top-right, mirroring the caption pill's
        // material. Hidden until the user taps the info button.
        exifPanel.material = .hudWindow
        exifPanel.state = .active
        exifPanel.blendingMode = .withinWindow
        exifPanel.wantsLayer = true
        exifPanel.layer?.cornerRadius = 6
        exifPanel.layer?.masksToBounds = true
        exifPanel.isHidden = true
        exifLabel.maximumNumberOfLines = 0
        exifLabel.lineBreakMode = .byWordWrapping
        exifLabel.alignment = .left
        exifLabel.translatesAutoresizingMaskIntoConstraints = false
        exifPanel.addSubview(exifLabel)

        NSLayoutConstraint.activate([
            // Scrollable image (with magnification) fills the entire content area.
            imageScrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            imageScrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            imageScrollView.topAnchor.constraint(equalTo: v.topAnchor),
            imageScrollView.bottomAnchor.constraint(equalTo: v.bottomAnchor),

            chrome.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            chrome.topAnchor.constraint(equalTo: v.topAnchor),
            chrome.bottomAnchor.constraint(equalTo: v.bottomAnchor),

            // Close — clears the macOS traffic-light cluster (~78px wide).
            closeButton.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 86),
            closeButton.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 12),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            // Favorite (heart) — to the immediate right of Close.
            favoriteButton.leadingAnchor.constraint(equalTo: closeButton.trailingAnchor, constant: 10),
            favoriteButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            favoriteButton.widthAnchor.constraint(equalToConstant: 28),
            favoriteButton.heightAnchor.constraint(equalToConstant: 28),

            // Info (EXIF) — right of favorite.
            infoButton.leadingAnchor.constraint(equalTo: favoriteButton.trailingAnchor, constant: 10),
            infoButton.centerYAnchor.constraint(equalTo: favoriteButton.centerYAnchor),
            infoButton.widthAnchor.constraint(equalToConstant: 28),
            infoButton.heightAnchor.constraint(equalToConstant: 28),

            // EXIF panel pinned top-right, below the traffic-light row.
            exifPanel.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -20),
            exifPanel.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 12),
            exifPanel.widthAnchor.constraint(lessThanOrEqualToConstant: 340),

            exifLabel.topAnchor.constraint(equalTo: exifPanel.topAnchor, constant: 12),
            exifLabel.leadingAnchor.constraint(equalTo: exifPanel.leadingAnchor, constant: 14),
            exifLabel.trailingAnchor.constraint(equalTo: exifPanel.trailingAnchor, constant: -14),
            exifLabel.bottomAnchor.constraint(equalTo: exifPanel.bottomAnchor, constant: -12),

            // Prev / next pinned to left/right edges, vertically centered.
            prevButton.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 20),
            prevButton.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),
            prevButton.widthAnchor.constraint(equalToConstant: 44),
            prevButton.heightAnchor.constraint(equalToConstant: 44),

            nextButton.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -20),
            nextButton.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),
            nextButton.widthAnchor.constraint(equalToConstant: 44),
            nextButton.heightAnchor.constraint(equalToConstant: 44),

            // Caption pill anchored to the top-center of the chrome.
            captionPill.centerXAnchor.constraint(equalTo: chrome.centerXAnchor),
            captionPill.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 12),
            captionPill.widthAnchor.constraint(lessThanOrEqualToConstant: 540),

            // Filename + meta lines hug the pill with 14×8 padding.
            titleLabel.topAnchor.constraint(equalTo: captionPill.topAnchor, constant: 8),
            titleLabel.leadingAnchor.constraint(equalTo: captionPill.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: captionPill.trailingAnchor, constant: -16),
            metaLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            metaLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            metaLabel.bottomAnchor.constraint(equalTo: captionPill.bottomAnchor, constant: -8),

            // Filmstrip stays pinned to the bottom — clean edge, no caption below.
            strip.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            strip.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -16),
            strip.heightAnchor.constraint(equalToConstant: 64),
        ])

        // Fixed-size LIVE badge (top-right). Added above the media surfaces but
        // below the auto-hiding chrome so it stays put and visible; click to
        // replay the motion. Shown only for Live Photos (see setMediaMode).
        liveBadge.wantsLayer = true
        liveBadge.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        liveBadge.layer?.cornerRadius = 6
        liveBadge.isHidden = true
        liveBadge.translatesAutoresizingMaskIntoConstraints = false
        liveBadge.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.5)
            s.shadowBlurRadius = 5
            s.shadowOffset = NSSize(width: 0, height: -1)
            return s
        }()
        let liveAttr = NSMutableAttributedString(string: "◉ LIVE")
        liveAttr.addAttributes([
            .font: PlateFont.mono(13, weight: .semibold),
            .foregroundColor: PlateColor.textPrimary,
            .kern: 1.0,
        ], range: NSRange(location: 0, length: liveAttr.length))
        liveBadgeLabel.attributedStringValue = liveAttr
        liveBadgeLabel.alignment = .center
        liveBadgeLabel.translatesAutoresizingMaskIntoConstraints = false
        liveBadge.addSubview(liveBadgeLabel)
        v.addSubview(liveBadge, positioned: .below, relativeTo: chrome)
        liveBadge.addGestureRecognizer(
            NSClickGestureRecognizer(target: self, action: #selector(replayLiveMotion)))
        NSLayoutConstraint.activate([
            liveBadge.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            liveBadge.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            liveBadgeLabel.leadingAnchor.constraint(equalTo: liveBadge.leadingAnchor, constant: 11),
            liveBadgeLabel.trailingAnchor.constraint(equalTo: liveBadge.trailingAnchor, constant: -11),
            liveBadgeLabel.topAnchor.constraint(equalTo: liveBadge.topAnchor, constant: 5),
            liveBadgeLabel.bottomAnchor.constraint(equalTo: liveBadge.bottomAnchor, constant: -5),
        ])

        loadCurrent()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didEndLiveMagnify(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: imageScrollView
        )
    }

    /// Replay the Live Photo motion — fired by clicking the LIVE badge.
    @objc private func replayLiveMotion() {
        livePhotoView?.startPlayback(with: .full)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
        view.window?.acceptsMouseMovedEvents = true
        showChrome()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        hideTimer?.invalidate()
        hideTimer = nil
        // Stop playback + audio when the viewer is dismissed.
        teardownPlayback()
    }

    // MARK: - Chrome auto-hide

    private func showChrome() {
        hideTimer?.invalidate()
        if chrome.alphaValue < 1.0 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                chrome.animator().alphaValue = 1.0
            }
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
            self?.hideChrome()
        }
    }

    private func hideChrome() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.4
            chrome.animator().alphaValue = 0.0
        }
    }

    // MARK: - Loading

    private func loadCurrent() {
        let asset = assets[currentIndex]

        // Top line — filename in serif, like a book chapter title.
        let filename = (asset.primary as NSString).lastPathComponent
        let titleAttr = NSAttributedString(string: filename, attributes: [
            .font: PlateFont.serif(14, weight: .semibold),
            .foregroundColor: PlateColor.textPrimary,
        ])
        titleLabel.attributedStringValue = titleAttr

        // Bottom of caption — "APR 28, 2026 · 15 / 28" in mono caps, kerned.
        let dateText: String = asset.capturedAt
            .map { Self.captionDateFormatter.string(from: $0).uppercased() }
            ?? ""
        let positionText = "\(currentIndex + 1) / \(assets.count)"
        let meta = NSMutableAttributedString()
        if !dateText.isEmpty {
            meta.append(NSAttributedString(string: dateText, attributes: [
                .font: PlateFont.mono(10, weight: .medium),
                .foregroundColor: PlateColor.textMuted,
                .kern: 1.4,
            ]))
            meta.append(NSAttributedString(string: "   ·   ", attributes: [
                .font: PlateFont.mono(10),
                .foregroundColor: PlateColor.textFaint,
                .kern: 1.0,
            ]))
        }
        meta.append(NSAttributedString(string: positionText, attributes: [
            .font: PlateFont.mono(10, weight: .medium),
            .foregroundColor: PlateColor.textMuted,
            .kern: 1.4,
        ]))
        metaLabel.attributedStringValue = meta

        prevButton.isEnabled = currentIndex > 0
        nextButton.isEnabled = currentIndex < assets.count - 1
        strip.currentIndex = currentIndex
        refreshFavoriteIcon()
        if exifVisible { populateExif() }

        // Keep the prior image visible until the new one decodes — no flash.
        loadGeneration &+= 1
        let generation = loadGeneration

        // Stop and release any prior video/Live Photo before showing the next
        // asset — kills audio and frees the player even when navigating from a
        // movie straight to a still.
        teardownPlayback()

        switch asset.mediaType {
        case .image:     showImage(asset: asset, generation: generation)
        case .video:     showVideo(asset: asset)
        case .livePhoto: showLivePhoto(asset: asset, generation: generation)
        }
    }

    // MARK: - Media surfaces

    /// Show / hide the three content surfaces so exactly one is front-most.
    private func setMediaMode(_ mode: MediaMode) {
        imageScrollView.isHidden     = (mode != .image)
        playerView?.isHidden         = (mode != .video)
        livePhotoScrollView?.isHidden = (mode != .livePhoto)
        liveBadge.isHidden           = (mode != .livePhoto)
    }

    /// Pause + release the active player / Live Photo. Safe to call when nothing
    /// is playing. Leaves the (reusable) views in place, just emptied.
    private func teardownPlayback() {
        player?.pause()
        player = nil
        playerView?.player = nil
        livePhotoView?.stopPlayback()
        livePhotoView?.livePhoto = nil
    }

    private func showImage(asset: Asset, generation: Int) {
        setMediaMode(.image)
        loadedAtMaxPixel = 0
        let url = library.absoluteURL(forRelative: asset.primary)
        let targetMaxPixel = Self.fastMaxPixel
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.decodeDownsampled(url: url, maxPixel: targetMaxPixel)
            DispatchQueue.main.async {
                guard let self = self, self.loadGeneration == generation else { return }
                if let image = image {
                    self.fastImage = image
                    self.crossfadeImage()
                    self.applyImage(image)
                    self.loadedAtMaxPixel = targetMaxPixel
                }
            }
        }
    }

    private func showVideo(asset: Asset) {
        let url = library.absoluteURL(forRelative: asset.primary)
        let pv = ensurePlayerView()
        let newPlayer = AVPlayer(url: url)
        player = newPlayer
        pv.player = newPlayer
        setMediaMode(.video)
        newPlayer.play()
    }

    private func showLivePhoto(asset: Asset, generation: Int) {
        // A Live Photo with no motion file on the row is just a still — fall back
        // rather than showing an empty Live Photo view.
        guard let motion = asset.motionPath else {
            showImage(asset: asset, generation: generation)
            return
        }
        let stillURL = library.absoluteURL(forRelative: asset.primary)
        let motionURL = library.absoluteURL(forRelative: motion)
        let lpv = ensureLivePhotoView()
        lpv.livePhoto = nil
        setMediaMode(.livePhoto)

        PHLivePhoto.request(withResourceFileURLs: [stillURL, motionURL],
                            placeholderImage: nil,
                            targetSize: .zero,
                            contentMode: .aspectFit) { [weak self] livePhoto, info in
            // The handler can fire on a background queue and more than once (a
            // degraded placeholder, then the full asset). Hop to main, guard the
            // navigation generation, and only auto-play the non-degraded result.
            DispatchQueue.main.async {
                guard let self = self,
                      self.loadGeneration == generation,
                      let livePhoto = livePhoto else { return }
                lpv.livePhoto = livePhoto
                // Hide the framework badge (it scales with the zoom scroll view);
                // our fixed top-right `liveBadge` stands in for it.
                lpv.livePhotoBadgeView?.isHidden = true
                self.applyLivePhotoLayout(asset: asset)
                let degraded = (info[PHLivePhotoInfoIsDegradedKey] as? NSNumber)?.boolValue ?? false
                if !degraded {
                    // Defer auto-play briefly so the still renders first. Starting
                    // immediately races the view's initial layout — the short
                    // motion would play before anything is on screen, so the user
                    // would only ever see the still (and think it never played).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                        guard let self = self, self.loadGeneration == generation else { return }
                        lpv.startPlayback(with: .full)
                    }
                }
            }
        }
    }

    /// Lazily build the AVPlayerView, inserted just below the chrome overlay and
    /// pinned to the content edges. Floating controls (auto-hiding scrubber +
    /// play/pause) match the viewer's minimal aesthetic.
    private func ensurePlayerView() -> AVPlayerView {
        if let pv = playerView { return pv }
        let pv = AVPlayerView()
        pv.controlsStyle = .floating
        pv.videoGravity = .resizeAspect
        pv.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(pv, positioned: .below, relativeTo: chrome)
        NSLayoutConstraint.activate([
            pv.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            pv.topAnchor.constraint(equalTo: view.topAnchor),
            pv.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        playerView = pv
        return pv
    }

    private func ensureLivePhotoView() -> PHLivePhotoView {
        if let lpv = livePhotoView { return lpv }
        let lpv = PHLivePhotoView()
        lpv.contentMode = .aspectFit

        // Same magnify-to-zoom setup as the still image path: the PHLivePhotoView
        // is the documentView (sized to the still's pixels in showLivePhoto), and
        // magnification == "fit to window". Native trackpad pinch / two-finger pan.
        let scroll = NSScrollView()
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.01   // recomputed per asset in fitLivePhotoToView
        scroll.maxMagnification = 6.0
        scroll.usesPredominantAxisScrolling = false
        scroll.documentView = lpv
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll, positioned: .below, relativeTo: chrome)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        livePhotoView = lpv
        livePhotoScrollView = scroll
        return lpv
    }

    /// Size the Live Photo documentView to the still's pixel dimensions, then
    /// fit it to the window. Mirrors `applyImage` / `fitImageToView` for stills.
    private func applyLivePhotoLayout(asset: Asset) {
        guard let lpv = livePhotoView else { return }
        let w = asset.pixelWidth ?? Int(view.bounds.width.rounded())
        let h = asset.pixelHeight ?? Int(view.bounds.height.rounded())
        lpv.frame = NSRect(x: 0, y: 0, width: max(1, w), height: max(1, h))
        fitLivePhotoToView()
    }

    private func fitLivePhotoToView() {
        guard let scroll = livePhotoScrollView, let lpv = livePhotoView else { return }
        let scrollSize = scroll.frame.size
        let imgSize = lpv.frame.size
        guard imgSize.width > 0, imgSize.height > 0,
              scrollSize.width > 0, scrollSize.height > 0 else { return }
        let fit = min(scrollSize.width / imgSize.width, scrollSize.height / imgSize.height)
        scroll.minMagnification = fit
        scroll.maxMagnification = max(fit * 6.0, fit + 0.01)
        scroll.magnification = fit
    }

    /// Space-bar behavior: only a video claims Space (play/pause). Stills AND
    /// Live Photos return false so Space falls through to the established "close
    /// the viewer" dismiss — replaying a Live Photo's motion is done by hovering
    /// its badge, not by Space (which users expect to take them back to the grid).
    private func handleSpaceForMedia() -> Bool {
        guard currentIndex >= 0, currentIndex < assets.count,
              assets[currentIndex].mediaType == .video,
              let player = player else { return false }
        if player.rate == 0 { player.play() } else { player.pause() }
        return true
    }

    /// Drop a short CATransition on the imageView before swapping its image.
    /// Animates the prev/next navigation as a quick cross-dissolve (matches
    /// Apple Photos) rather than a hard cut. Reused for high-res upgrades too,
    /// where it hides the brief "image gets sharper" moment.
    private func crossfadeImage() {
        imageView.wantsLayer = true
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.18
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        imageView.layer?.add(transition, forKey: "PlateImageSwap")
    }

    // MARK: - High-res upgrade

    @objc private func didEndLiveMagnify(_ note: Notification) {
        // Magnification only applies to the still image surface; video / Live
        // Photo manage their own scaling.
        guard currentIndex >= 0, currentIndex < assets.count,
              assets[currentIndex].mediaType == .image else { return }
        upgradeIfNeeded()
        downgradeIfNeeded()
    }

    /// Symmetric counterpart to `upgradeIfNeeded`: once the user zooms back to
    /// (essentially) fit, swap the heavy detail image out for the cached
    /// lightweight one. At fit the two are visually identical (both downscaled),
    /// but this releases the ~200MB detail bitmap so the zoomed-out state — and
    /// the next zoom gesture — start light instead of dragging the giant image
    /// around. The guards are mutually exclusive with the upgrade's (>1.5×).
    private func downgradeIfNeeded() {
        let fit = imageScrollView.minMagnification
        guard fit > 0 else { return }
        let zoomFactor = imageScrollView.magnification / fit
        guard zoomFactor <= 1.05 else { return }
        guard loadedAtMaxPixel > Self.fastMaxPixel, let fast = fastImage else { return }
        loadedAtMaxPixel = Self.fastMaxPixel
        replaceImagePreservingZoom(fast)
    }

    private func upgradeIfNeeded() {
        let fit = imageScrollView.minMagnification
        guard fit > 0 else { return }
        let zoomFactor = imageScrollView.magnification / fit
        guard zoomFactor > 1.5 else { return }
        guard loadedAtMaxPixel < Self.detailMaxPixel else { return }
        guard currentIndex >= 0, currentIndex < assets.count else { return }

        let snapshotGen = loadGeneration
        let asset = assets[currentIndex]
        let url = library.absoluteURL(forRelative: asset.primary)
        let targetMaxPixel = Self.detailMaxPixel
        loadedAtMaxPixel = targetMaxPixel  // optimistic — prevents duplicate decodes

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let image = Self.decodeDownsampled(url: url, maxPixel: targetMaxPixel)
            DispatchQueue.main.async {
                guard let self = self,
                      self.loadGeneration == snapshotGen,
                      let image = image else { return }
                // No crossfade here: this is the *same* photo at higher
                // resolution. Cross-dissolving it ghosts/flickers because the
                // documentView frame doubles mid-transition (the before/after
                // layer snapshots are at different scales). An instant,
                // geometry-preserving swap reads as "it just got sharper".
                self.replaceImagePreservingZoom(image)
            }
        }
    }

    /// Swap to a higher-res image without yanking the user's pan / zoom back
    /// to fit. We map the old visible center point into the new (larger) doc
    /// coordinate space and recompute magnification so the on-screen size of
    /// the photo stays constant — the only visible change is "image got
    /// sharper" instead of "image jumped around".
    private func replaceImagePreservingZoom(_ image: NSImage) {
        let oldImgWidth   = imageView.frame.width
        let oldImgHeight  = imageView.frame.height
        let oldMag        = imageScrollView.magnification
        let oldClipBounds = imageScrollView.contentView.bounds

        guard oldImgWidth > 0, oldImgHeight > 0 else {
            applyImage(image)
            return
        }

        // Visible-center in OLD documentView coords.
        let centerOldX = oldClipBounds.origin.x + oldClipBounds.size.width  / 2
        let centerOldY = oldClipBounds.origin.y + oldClipBounds.size.height / 2

        let scaleX = image.size.width  / oldImgWidth
        let scaleY = image.size.height / oldImgHeight

        // Apply the document resize, magnification, and re-center as one atomic,
        // non-animated batch. Disabling implicit actions stops the (now
        // layer-backed) image view from animating its contents/bounds, and doing
        // it all inside one CATransaction keeps AppKit from rendering the
        // transient "frame doubled but magnification not yet halved" state — that
        // intermediate is the flicker.
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Resize document.
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)

        // New fit + preserved-visual-zoom magnification.
        let scrollSize = imageScrollView.frame.size
        let newFitMag = min(scrollSize.width / image.size.width,
                            scrollSize.height / image.size.height)
        imageScrollView.minMagnification = newFitMag
        imageScrollView.maxMagnification = max(newFitMag * 6.0, newFitMag + 0.01)
        let preservedMag = oldMag / scaleX   // same visual zoom (X ≈ Y since aspect equal)
        imageScrollView.magnification = max(newFitMag,
                                             min(imageScrollView.maxMagnification, preservedMag))

        // Re-center on the same image content as before.
        let newClipBounds = imageScrollView.contentView.bounds
        let newCenterX = centerOldX * scaleX
        let newCenterY = centerOldY * scaleY
        let newOrigin = NSPoint(
            x: newCenterX - newClipBounds.size.width  / 2,
            y: newCenterY - newClipBounds.size.height / 2
        )
        imageScrollView.contentView.scroll(to: newOrigin)
        imageScrollView.reflectScrolledClipView(imageScrollView.contentView)

        CATransaction.commit()
    }

    /// Set the image into the scrollable view at its native pixel size, then
    /// compute fit-to-window magnification.
    private func applyImage(_ image: NSImage) {
        imageView.image = image
        let size = image.size
        imageView.frame = NSRect(origin: .zero, size: size)
        fitImageToView()
    }

    /// Recompute `minMagnification` = fit, `maxMagnification` = 6× fit, and
    /// snap current magnification back to fit. Pinch-to-zoom from there.
    private func fitImageToView() {
        let scrollSize = imageScrollView.frame.size
        let imgSize = imageView.frame.size
        guard imgSize.width > 0, imgSize.height > 0,
              scrollSize.width > 0, scrollSize.height > 0 else { return }
        let fitMag = min(scrollSize.width / imgSize.width,
                          scrollSize.height / imgSize.height)
        imageScrollView.minMagnification = fitMag
        imageScrollView.maxMagnification = max(fitMag * 6.0, fitMag + 0.01)
        imageScrollView.magnification = fitMag
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Refit on resize *only* if user hasn't zoomed in (preserve their pan/zoom).
        if abs(imageScrollView.magnification - imageScrollView.minMagnification) < 0.001 {
            fitImageToView()
        }
        // Same for the Live Photo surface when it's the visible one.
        if let scroll = livePhotoScrollView, !scroll.isHidden,
           abs(scroll.magnification - scroll.minMagnification) < 0.001 {
            fitLivePhotoToView()
        }
    }

    private static func decodeDownsampled(url: URL, maxPixel: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
    }

    // MARK: - Actions

    @objc func close(_ sender: Any?)   { onClose() }

    @objc func toggleFavorite(_ sender: Any?) {
        guard currentIndex >= 0, currentIndex < assets.count else { return }
        let newValue = !assets[currentIndex].isFavorite
        do {
            try library.setFavorite(assets[currentIndex], isFavorite: newValue)
        } catch {
            NSAlert(error: error).runModal()
            return
        }
        // Update our local mirror so the heart icon and the photo's badge in
        // the filmstrip stay consistent without a full reload.
        assets[currentIndex].isFavorite = newValue
        refreshFavoriteIcon()
    }

    private func refreshFavoriteIcon() {
        guard currentIndex >= 0, currentIndex < assets.count else { return }
        let isFav = assets[currentIndex].isFavorite
        favoriteButton.setSymbol(isFav ? "heart.fill" : "heart",
                                 tint: isFav ? PlateColor.accent : nil)
    }
    // MARK: - EXIF panel

    @objc private func toggleExif() {
        exifVisible.toggle()
        exifPanel.isHidden = !exifVisible
        infoButton.setSymbol(exifVisible ? "info.circle.fill" : "info.circle",
                             tint: exifVisible ? PlateColor.accent : nil)
        if exifVisible { populateExif() }
        showChrome()
    }

    /// Read EXIF for the current asset off-main and drop it into the panel.
    /// Guarded by `currentIndex` so a slow read for a since-navigated-away photo
    /// can't clobber the panel.
    private func populateExif() {
        guard currentIndex >= 0, currentIndex < assets.count else { return }
        let idx = currentIndex
        let asset = assets[idx]
        let url = library.absoluteURL(forRelative: asset.primary)
        exifLabel.attributedStringValue = Self.exifPlaceholder("Reading…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size])
                .flatMap { ($0 as? NSNumber)?.int64Value }
            // Movies carry no ImageIO EXIF; describe them from the row instead
            // (resolution, duration, date, size) rather than "No EXIF metadata".
            let text: NSAttributedString = (asset.mediaType == .video)
                ? Self.formatVideoInfo(asset, fileSize: size)
                : Self.formatExif(ExifInfo.read(url: url), fileSize: size)
            DispatchQueue.main.async {
                guard let self = self, self.exifVisible, self.currentIndex == idx else { return }
                self.exifLabel.attributedStringValue = text
            }
        }
    }

    /// Info-panel block for a video, built from the stored row (no ImageIO).
    /// "Video" header, then resolution · duration, capture date, file size, GPS.
    private static func formatVideoInfo(_ asset: Asset, fileSize: Int64?) -> NSAttributedString {
        let primary: [NSAttributedString.Key: Any] = [
            .font: PlateFont.mono(11, weight: .medium),
            .foregroundColor: PlateColor.textPrimary,
        ]
        let muted: [NSAttributedString.Key: Any] = [
            .font: PlateFont.mono(10),
            .foregroundColor: PlateColor.textMuted,
            .kern: 0.3,
        ]
        var lines: [(String, [NSAttributedString.Key: Any])] = [("Video", primary)]

        var dims: [String] = []
        if let w = asset.pixelWidth, let h = asset.pixelHeight { dims.append("\(w) × \(h)") }
        if let d = asset.duration, d > 0 {
            let t = Int(d.rounded())
            dims.append(String(format: "%d:%02d", t / 60, t % 60))
        }
        if let bytes = fileSize {
            dims.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if !dims.isEmpty { lines.append((dims.joined(separator: "  ·  "), muted)) }

        if let d = asset.capturedAt { lines.append((exifDateFormatter.string(from: d), muted)) }
        if let lat = asset.latitude, let lon = asset.longitude {
            lines.append((String(format: "%.5f, %.5f", lat, lon), muted))
        }

        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: line.0, attributes: line.1))
        }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        out.addAttribute(.paragraphStyle, value: para,
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy 'at' HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static func exifPlaceholder(_ s: String) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: PlateFont.mono(11),
            .foregroundColor: PlateColor.textMuted,
        ])
    }

    /// Build the multi-line EXIF block. Camera/lens lines read as primary text;
    /// the technical lines (exposure, dimensions, date, GPS) are muted. Missing
    /// fields are simply omitted.
    private static func formatExif(_ info: ExifInfo, fileSize: Int64?) -> NSAttributedString {
        let primary: [NSAttributedString.Key: Any] = [
            .font: PlateFont.mono(11, weight: .medium),
            .foregroundColor: PlateColor.textPrimary,
        ]
        let muted: [NSAttributedString.Key: Any] = [
            .font: PlateFont.mono(10),
            .foregroundColor: PlateColor.textMuted,
            .kern: 0.3,
        ]

        var lines: [(String, [NSAttributedString.Key: Any])] = []

        let camera = [info.cameraMake, info.cameraModel]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !camera.isEmpty { lines.append((camera, primary)) }
        if let lens = info.lensModel?.trimmingCharacters(in: .whitespaces), !lens.isEmpty {
            lines.append((lens, primary))
        }

        var exposure: [String] = []
        if let iso = info.iso { exposure.append("ISO \(iso)") }
        if let t = info.exposureTime { exposure.append(shutterString(t)) }
        if let f = info.fNumber { exposure.append("ƒ/\(numString(f))") }
        if let fl = info.focalLength { exposure.append("\(numString(fl))mm") }
        if !exposure.isEmpty { lines.append((exposure.joined(separator: "  ·  "), muted)) }

        var dims: [String] = []
        if let w = info.pixelWidth, let h = info.pixelHeight {
            dims.append("\(w) × \(h)")
            let mp = Double(w * h) / 1_000_000
            if mp >= 1 { dims.append("\(numString(mp)) MP") }
        }
        if let bytes = fileSize {
            dims.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if !dims.isEmpty { lines.append((dims.joined(separator: "  ·  "), muted)) }

        if let d = info.capturedAt { lines.append((exifDateFormatter.string(from: d), muted)) }
        if let lat = info.latitude, let lon = info.longitude {
            lines.append((String(format: "%.5f, %.5f", lat, lon), muted))
        }

        if lines.isEmpty { return exifPlaceholder("No EXIF metadata") }

        let out = NSMutableAttributedString()
        for (i, line) in lines.enumerated() {
            if i > 0 { out.append(NSAttributedString(string: "\n")) }
            out.append(NSAttributedString(string: line.0, attributes: line.1))
        }
        let para = NSMutableParagraphStyle()
        para.lineSpacing = 2
        out.addAttribute(.paragraphStyle, value: para,
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    /// "1/250s", "2s", "1.3s" — EXIF shutter speed in conventional notation.
    private static func shutterString(_ t: Double) -> String {
        if t >= 1 { return "\(numString(t))s" }
        guard t > 0 else { return "—" }
        return "1/\(Int((1 / t).rounded()))s"
    }

    /// Drop a trailing ".0" but keep one decimal otherwise ("2.8", "38", "1.3").
    private static func numString(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    @objc func previous(_ sender: Any?) {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
        loadCurrent()
    }
    @objc func nextItem(_ sender: Any?) {
        guard currentIndex < assets.count - 1 else { return }
        currentIndex += 1
        loadCurrent()
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:     close(nil)             // Escape
        case 49:                            // Space — play/pause media, else close
            if !handleSpaceForMedia() { close(nil) }
        case 123:    previous(nil)          // ←
        case 124:    nextItem(nil)          // →
        case 125:    nextItem(nil)          // ↓
        case 126:    previous(nil)          // ↑
        default:     super.keyDown(with: event)
        }
    }

    // MARK: - Helper types

    /// NSImageView would otherwise report `image.pixelSize` as its
    /// intrinsicContentSize — propagating up to `view.fittingSize` and asking
    /// the window to grow to match a 100MP source.
    private final class NonGreedyImageView: NSImageView {
        override var intrinsicContentSize: NSSize {
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }
}

// MARK: - Pass-through overlay

/// NSView subclass that lets mouse / gesture events fall through to the views
/// below when the point isn't on a subview. AppKit's default `hitTest` claims
/// the point as long as it's within bounds, even if no subview is there —
/// which would swallow trackpad pinch / two-finger pan on the photo.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        return result === self ? nil : result
    }
}

// MARK: - Centering clip view

/// Standard Apple recipe for centering an NSScrollView's documentView when
/// (post-magnification) it's smaller than the visible area on either axis.
/// Without this the photo sticks to the bottom-left at fit magnification.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let docView = documentView else { return rect }
        // rect.size is the visible area in documentView coords (pre-magnification).
        // When docView is smaller than that on an axis, shift origin negative so
        // the document renders centered in the visible area.
        let docFrame = docView.frame
        if docFrame.width < rect.width {
            rect.origin.x = -(rect.width - docFrame.width) / 2
        }
        if docFrame.height < rect.height {
            rect.origin.y = -(rect.height - docFrame.height) / 2
        }
        return rect
    }
}

// MARK: - Mouse tracking root

/// Full-view mouse-moved tracking so chrome can fade back in on any movement.
private final class MouseTrackingView: NSView {
    var onMouseMoved: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        let new = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(new)
        area = new
    }

    override func mouseMoved(with event: NSEvent) { onMouseMoved?() }
}

// MARK: - Thumbnail strip

/// Photos.app-style horizontal thumbnail filmstrip. Highlights the current
/// asset, auto-centers it after a navigation, click any tile to jump to it.
/// Scrolls horizontally on trackpad / shift-wheel; takes vertical wheel as
/// horizontal too so a plain mouse still works.
private final class ThumbnailStrip: NSView {

    var library: PlateLibrary?
    var assets: [Asset] = [] {
        didSet { rebuild() }
    }
    var currentIndex: Int = 0 {
        didSet { updateHighlight(); scrollToCurrent(animated: true) }
    }
    var onSelect: ((Int) -> Void)?

    private let scrollView = HorizontalWheelScrollView()
    private let stackView = NSStackView()
    private var cells: [ThumbnailCell] = []
    private var didLayoutOnce = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true

        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.usesPredominantAxisScrolling = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        stackView.orientation = .horizontal
        stackView.spacing = 4
        stackView.alignment = .centerY
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stackView

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.contentView.heightAnchor),
        ])
    }

    override func layout() {
        super.layout()
        // Center the current thumbnail the first time we get real geometry.
        if !didLayoutOnce, bounds.width > 0 {
            didLayoutOnce = true
            scrollToCurrent(animated: false)
        }
    }

    private func rebuild() {
        cells.forEach { $0.removeFromSuperview() }
        cells = []
        guard let library = library else { return }
        for (i, asset) in assets.enumerated() {
            let thumbURL = asset.thumbnail.map { library.absoluteURL(forRelative: $0) }
            let cell = ThumbnailCell(index: i, asset: asset, thumbnailURL: thumbURL)
            cell.onClick = { [weak self] idx in self?.onSelect?(idx) }
            stackView.addArrangedSubview(cell)
            cells.append(cell)
        }
        updateHighlight()
        didLayoutOnce = false
        needsLayout = true
    }

    private func updateHighlight() {
        for (i, cell) in cells.enumerated() {
            cell.isCurrent = (i == currentIndex)
        }
    }

    private func scrollToCurrent(animated: Bool) {
        guard currentIndex >= 0, currentIndex < cells.count else { return }
        let cell = cells[currentIndex]
        // Translate cell.frame (in stack) to documentView coordinates — same
        // since stack IS the documentView.
        let visibleWidth = scrollView.contentView.bounds.width
        guard visibleWidth > 0 else { return }
        let docWidth = stackView.frame.width
        let centeredX = cell.frame.midX - visibleWidth / 2
        let clampedX = max(0, min(centeredX, max(0, docWidth - visibleWidth)))
        let target = NSPoint(x: clampedX, y: 0)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(target)
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            scrollView.contentView.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}

/// NSScrollView that maps plain mouse-wheel (vertical) deltas to horizontal,
/// so a normal mouse can scroll the filmstrip without needing shift+wheel.
private final class HorizontalWheelScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        // Trackpad or shift-wheel already produce horizontal deltas — pass through.
        if abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) {
            super.scrollWheel(with: event)
            return
        }
        // Synthesize a horizontal scroll from vertical deltas.
        guard let cg = event.cgEvent?.copy() else {
            super.scrollWheel(with: event)
            return
        }
        let dy = event.scrollingDeltaY
        cg.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: 0)
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(dy))
        cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        if let synthetic = NSEvent(cgEvent: cg) {
            super.scrollWheel(with: synthetic)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

private final class ThumbnailCell: NSView {

    let index: Int
    var onClick: ((Int) -> Void)?
    var isCurrent: Bool = false { didSet { updateAppearance() } }

    private let imageView = NSImageView()
    private var isHovering = false { didSet { updateAppearance() } }

    init(index: Int, asset: Asset, thumbnailURL: URL?) {
        self.index = index
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.masksToBounds = true
        layer?.backgroundColor = PlateColor.surface.cgColor
        layer?.borderColor = PlateColor.accent.cgColor

        // Fixed height; width derived from aspect ratio.
        let aspect: CGFloat = {
            if let w = asset.pixelWidth, let h = asset.pixelHeight, h > 0 {
                return CGFloat(w) / CGFloat(h)
            }
            return 4.0 / 3.0
        }()
        let height: CGFloat = 56
        let width = max(28, min(180, height * aspect))
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true

        imageView.imageScaling = .scaleAxesIndependently
        imageView.translatesAutoresizingMaskIntoConstraints = false
        if let url = thumbnailURL {
            imageView.image = NSImage(contentsOf: url)
        }
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateAppearance() {
        layer?.borderWidth = isCurrent ? 2 : (isHovering ? 1 : 0)
        layer?.opacity = isCurrent ? 1.0 : (isHovering ? 0.85 : 0.55)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { isHovering = true; NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent)  { isHovering = false; NSCursor.arrow.set() }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?(index)
        }
    }
}

// MARK: - Floating button

/// Round HUD button with semi-transparent dark fill, hover ring in faint warm
/// neutral, and pressed/disabled states. Used for close + prev + next.
// MARK: - EXIF reader

/// On-demand EXIF extraction for the detail panel. Reads a single ImageIO
/// property pass from the asset's primary file (display master or RAW — ImageIO
/// surfaces EXIF for both). Display-only, so it lives in the app rather than
/// PlateCore.
private struct ExifInfo {
    var cameraMake: String?
    var cameraModel: String?
    var lensModel: String?
    var iso: Int?
    var exposureTime: Double?
    var fNumber: Double?
    var focalLength: Double?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var capturedAt: Date?
    var latitude: Double?
    var longitude: Double?

    private static let exifDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        return f
    }()

    static func read(url: URL) -> ExifInfo {
        var info = ExifInfo()
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return info }

        var w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        var h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        if let o = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue, (5...8).contains(o) {
            swap(&w, &h)
        }
        info.pixelWidth = w
        info.pixelHeight = h

        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            info.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.intValue
            info.exposureTime = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue
            info.fNumber = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue
            info.focalLength = (exif[kCGImagePropertyExifFocalLength] as? NSNumber)?.doubleValue
            info.lensModel = exif[kCGImagePropertyExifLensModel] as? String
            if let s = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                info.capturedAt = exifDate.date(from: s)
            }
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            info.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            info.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
            if info.capturedAt == nil, let s = tiff[kCGImagePropertyTIFFDateTime] as? String {
                info.capturedAt = exifDate.date(from: s)
            }
        }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue {
                let ref = gps[kCGImagePropertyGPSLatitudeRef] as? String
                info.latitude = (ref == "S") ? -lat : lat
            }
            if let lon = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue {
                let ref = gps[kCGImagePropertyGPSLongitudeRef] as? String
                info.longitude = (ref == "W") ? -lon : lon
            }
        }
        return info
    }
}

private final class FloatingButton: NSView {

    var action: () -> Void = {}
    var isEnabled = true { didSet { updateAppearance() } }

    private let iconView = NSImageView()
    private let textFallback = NSTextField(labelWithString: "")
    private let symbolName: String
    private let buttonSize: CGFloat

    private var isHovering = false { didSet { updateAppearance() } }
    private var isPressed = false  { didSet { updateAppearance() } }

    init(symbol: String, size: CGFloat, weight: NSFont.Weight = .regular) {
        self.symbolName = symbol
        self.buttonSize = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        wantsLayer = true
        layer?.cornerRadius = size / 2
        layer?.masksToBounds = true

        if #available(macOS 11.0, *) {
            let conf = NSImage.SymbolConfiguration(pointSize: size * 0.38, weight: weight)
            iconView.image = NSImage(systemSymbolName: symbol,
                                     accessibilityDescription: nil)?
                .withSymbolConfiguration(conf)
            iconView.imageScaling = .scaleProportionallyUpOrDown
            iconView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(iconView)
            NSLayoutConstraint.activate([
                iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
                iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        } else {
            textFallback.font = PlateFont.body(size * 0.42, weight: weight)
            textFallback.alignment = .center
            textFallback.textColor = PlateColor.textPrimary
            textFallback.stringValue = Self.fallbackGlyph(for: symbol)
            textFallback.translatesAutoresizingMaskIntoConstraints = false
            addSubview(textFallback)
            NSLayoutConstraint.activate([
                textFallback.centerXAnchor.constraint(equalTo: centerXAnchor),
                textFallback.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        updateAppearance()
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func fallbackGlyph(for symbol: String) -> String {
        switch symbol {
        case "chevron.left":  return "‹"
        case "chevron.right": return "›"
        case "xmark":         return "✕"
        case "heart":         return "♡"
        case "heart.fill":    return "♥"
        default:              return "?"
        }
    }

    /// Swap the rendered SF Symbol — used by the favorite toggle to flip
    /// between `heart` and `heart.fill` without rebuilding the button.
    func setSymbol(_ symbol: String, tint: NSColor? = nil) {
        if #available(macOS 11.0, *) {
            let conf = NSImage.SymbolConfiguration(pointSize: buttonSize * 0.38, weight: .medium)
            iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(conf)
            iconView.contentTintColor = tint ?? PlateColor.textPrimary
        } else {
            textFallback.stringValue = Self.fallbackGlyph(for: symbol)
            textFallback.textColor = tint ?? PlateColor.textPrimary
        }
    }

    private func updateAppearance() {
        let tint: NSColor = isEnabled
            ? PlateColor.textPrimary
            : PlateColor.textPrimary.withAlphaComponent(0.3)
        let bg: NSColor
        if !isEnabled {
            bg = NSColor.black.withAlphaComponent(0.35)
        } else if isPressed {
            bg = NSColor.black.withAlphaComponent(0.82)
        } else if isHovering {
            bg = NSColor.black.withAlphaComponent(0.68)
        } else {
            bg = NSColor.black.withAlphaComponent(0.48)
        }
        layer?.backgroundColor = bg.cgColor
        layer?.borderWidth = isHovering && isEnabled ? 1 : 0
        layer?.borderColor = PlateColor.textFaint.cgColor

        if #available(macOS 11.0, *) {
            iconView.contentTintColor = tint
        } else {
            textFallback.textColor = tint
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled else { return }
        isHovering = true
        NSCursor.pointingHand.set()
    }
    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
    }
    override func mouseDown(with event: NSEvent) {
        if isEnabled { isPressed = true }
    }
    override func mouseUp(with event: NSEvent) {
        let wasPressed = isPressed
        isPressed = false
        if wasPressed, bounds.contains(convert(event.locationInWindow, from: nil)) {
            action()
        }
    }
}

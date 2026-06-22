import AppKit
import CoreImage
import Metal
import QuartzCore

/// EDR-capable still-image surface. `NSImageView` (the SDR path in
/// `DetailViewController`) draws through AppKit's standard compositing, which
/// tone-maps any extended-range content down to SDR — so an HDR photo looks
/// flat and clipped. To actually light up the bright highlights an HDR photo
/// carries, the content has to reach the display through a half-float,
/// extended-range surface: a `CAMetalLayer` with `wantsExtendedDynamicRangeContent`.
///
/// This view is that surface. It holds an HDR `CIImage` (values can exceed 1.0)
/// and renders it through Core Image into the Metal layer's drawable in an
/// extended-linear Display-P3 space, so headroom is preserved end to end. On a
/// non-EDR display the system simply clamps to SDR — the same photo still shows,
/// just without the extra brightness, so this path is always safe to use.
///
/// It's used only for images ImageIO reports as HDR (gain-map or PQ/HLG), and
/// only on macOS 14+. Everything else stays on the untouched `NSImageView` path.
///
/// Rendering is on-demand (not a 60fps loop): photos are static, so we redraw
/// only when the image, the frame, or the backing/display changes. While the
/// user pinch-zooms, the enclosing `NSScrollView` scales the already-rendered
/// drawable — no per-frame Metal work.
final class HDRImageView: NSView {

    /// Long-edge ceiling (in drawable pixels) for the Metal texture. Mirrors the
    /// detail viewer's 4096px SDR decode cap: keeps the half-float drawable to a
    /// sane size (~90MB at 4096²) while staying crisp at fit and moderate zoom.
    static let maxDrawablePixels: CGFloat = 4096

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let ciContext: CIContext
    /// Extended-range working + output space. Values above 1.0 survive into the
    /// float drawable and are read back out as HDR by the EDR-enabled layer.
    private let workingColorSpace: CGColorSpace

    /// The HDR image to display, already oriented and (optionally) gain-map
    /// expanded by the caller. nil clears the surface.
    private var image: CIImage?

    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    /// Returns nil when the machine has no Metal device (render falls back to the
    /// SDR path in that case). In practice every modern Mac has one.
    static func make() -> HDRImageView? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let space = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        else { return nil }
        return HDRImageView(device: device, commandQueue: queue, colorSpace: space)
    }

    private init(device: MTLDevice, commandQueue: MTLCommandQueue, colorSpace: CGColorSpace) {
        self.device = device
        self.commandQueue = commandQueue
        self.workingColorSpace = colorSpace
        self.ciContext = CIContext(mtlCommandQueue: commandQueue, options: [
            .workingColorSpace: colorSpace,
            .cacheIntermediates: false,
            .name: "PlateHDR",
        ])
        super.init(frame: .zero)
        wantsLayer = true
        // The drawable is a fixed-size texture we scale via the layer; pin
        // contentsScale to 1 so `drawableSize` is in the same units as `bounds`
        // and stays bounded (matches the SDR view's 4096px bitmap being scaled
        // by magnification rather than re-rasterized per Retina pixel).
        metalLayer.contentsScale = 1
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer {
        let l = CAMetalLayer()
        l.device = device
        l.pixelFormat = .rgba16Float          // half-float: holds values > 1.0
        l.framebufferOnly = false             // Core Image must write into the texture
        l.wantsExtendedDynamicRangeContent = true
        l.colorspace = workingColorSpace
        l.isOpaque = true
        l.needsDisplayOnBoundsChange = false  // we drive renders ourselves
        l.allowsNextDrawableTimeout = true
        return l
    }

    /// The document-view size (points) the caller should use for this image:
    /// the image's oriented aspect, long edge capped at `maxDrawablePixels`. The
    /// enclosing scroll view's "fit" magnification is computed from this, exactly
    /// like the SDR `NSImageView`'s pixel-sized frame.
    static func displaySize(forExtent extent: CGRect) -> CGSize {
        let w = max(extent.width, 1), h = max(extent.height, 1)
        let long = max(w, h)
        let scale = long > maxDrawablePixels ? maxDrawablePixels / long : 1
        return CGSize(width: max(1, (w * scale).rounded()),
                      height: max(1, (h * scale).rounded()))
    }

    func setImage(_ image: CIImage?) {
        self.image = image
        render()
    }

    func clear() {
        image = nil
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        render()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        // Moving the window to another display can change EDR headroom; re-render
        // so highlights track the new screen.
        render()
    }

    /// Render the current image into a fresh drawable. Cheap to call repeatedly;
    /// no-ops when there's nothing to draw or the view has no size / drawable yet
    /// (the caller re-invokes from `viewDidLayout` once geometry settles).
    func render() {
        guard let image = image else { return }
        let w = Int(bounds.width.rounded()), h = Int(bounds.height.rounded())
        guard w >= 1, h >= 1 else { return }

        if Int(metalLayer.drawableSize.width) != w || Int(metalLayer.drawableSize.height) != h {
            metalLayer.drawableSize = CGSize(width: w, height: h)
        }
        guard let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        // Scale the image so its extent fills the drawable, with origin at 0,0.
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let sx = CGFloat(w) / extent.width
        let sy = CGFloat(h) / extent.height
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x,
                                               y: -extent.origin.y))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy))

        // CIRenderDestination (vs. the older render(_:to texture:)) renders
        // upright into the Metal texture and lets us pin the output color space.
        let destination = CIRenderDestination(
            width: w, height: h,
            pixelFormat: .rgba16Float,
            commandBuffer: commandBuffer,
            mtlTextureProvider: { drawable.texture }
        )
        destination.colorSpace = workingColorSpace
        do {
            try ciContext.startTask(toRender: scaled, to: destination)
        } catch {
            // A failed render just leaves the prior frame on screen — not fatal.
            NSLog("HDRImageView render failed: \(error.localizedDescription)")
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

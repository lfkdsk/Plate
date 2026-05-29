import UIKit
import PlateCore

/// Minimal iPad shell that proves the macOS `PlateCore` runs **unchanged** on
/// iOS. On first launch it:
///   1. creates a real `.plate` library in the app sandbox (`PlateLibrary.create`)
///   2. imports generated images through the production `importPairs` pipeline
///      (hash dedup, ImageIO metadata, thumbnail render, SQLite insert)
///   3. queries `library.assets` and renders the thumbnails
///
/// i.e. the exact data path the AppKit grid uses, with a native
/// `UICollectionView` (the 1:1 counterpart of the Mac `NSCollectionView`) on
/// top. Re-launch just re-opens the existing library.
final class LibraryGridViewController: UIViewController {

    private var assets: [Asset] = []
    private var thumbs: [UUID: UIImage] = [:]
    private var library: PlateLibrary?

    private let statusLabel = UILabel()
    private let footerLabel = UILabel()
    private var collectionView: UICollectionView!

    private let cellID = "thumb"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = PlateColor.primary
        title = "Plate"
        configureNavBar()
        configureCollectionView()
        configureStatus()
        loadLibrary()
    }

    // MARK: - UI

    private func configureNavBar() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = PlateColor.surface
        appearance.shadowColor = PlateColor.hairline
        appearance.titleTextAttributes = [.foregroundColor: PlateColor.textPrimary]
        appearance.largeTitleTextAttributes = [.foregroundColor: PlateColor.textPrimary]
        navigationController?.navigationBar.standardAppearance = appearance
        navigationController?.navigationBar.scrollEdgeAppearance = appearance
        navigationController?.navigationBar.prefersLargeTitles = true
        navigationController?.navigationBar.tintColor = PlateColor.accent
    }

    private func configureCollectionView() {
        let layout = UICollectionViewFlowLayout()
        layout.sectionInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        layout.minimumInteritemSpacing = 6
        layout.minimumLineSpacing = 6
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(ThumbCell.self, forCellWithReuseIdentifier: cellID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureStatus() {
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = PlateColor.textMuted
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.text = "Running PlateCore import pipeline…"
        view.addSubview(statusLabel)

        footerLabel.translatesAutoresizingMaskIntoConstraints = false
        footerLabel.textColor = PlateColor.textSubtle
        footerLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        footerLabel.numberOfLines = 0
        footerLabel.textAlignment = .center
        view.addSubview(footerLabel)

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            footerLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            footerLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            footerLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            footerLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16),
        ])
    }

    // MARK: - Pipeline (all PlateCore, off the main thread)

    private func loadLibrary() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.buildOrOpenLibrary()
                DispatchQueue.main.async {
                    self.library = result.library
                    self.assets = result.assets
                    self.thumbs = result.thumbs
                    self.statusLabel.isHidden = !result.assets.isEmpty
                    self.title = "Plate — \(result.assets.count) photos"
                    self.footerLabel.text = result.footer
                    self.collectionView.reloadData()
                }
            } catch {
                DispatchQueue.main.async {
                    self.statusLabel.text = "Pipeline error:\n\(error)"
                }
            }
        }
    }

    private struct LoadResult {
        let library: PlateLibrary
        let assets: [Asset]
        let thumbs: [UUID: UIImage]
        let footer: String
    }

    private func buildOrOpenLibrary() throws -> LoadResult {
        let fm = FileManager.default
        let docs = try fm.url(for: .documentDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        let libURL = docs.appendingPathComponent("PlateDemo.plate", isDirectory: true)

        let library: PlateLibrary
        if fm.fileExists(atPath: libURL.appendingPathComponent("library.db").path) {
            library = try PlateLibrary.open(at: libURL)
        } else {
            library = try PlateLibrary.create(at: libURL)
        }

        // Import once — re-launch just re-opens the existing library.
        if library.assetCount == 0 {
            let srcDir = fm.temporaryDirectory.appendingPathComponent("plate-demo-src", isDirectory: true)
            let files = try DemoImageGenerator.generate(count: 12, into: srcDir)
            let pairs = AssetPairer.pair(files: files)
            try library.importPairs(pairs, thumbnailPixel: 512)
            try? fm.removeItem(at: srcDir)
        }

        let assets = library.assets
        var thumbs: [UUID: UIImage] = [:]
        for asset in assets {
            if let rel = asset.thumbnail,
               let img = UIImage(contentsOfFile: library.absoluteURL(forRelative: rel).path) {
                thumbs[asset.id] = img
            }
        }

        let device = UIDevice.current
        let footer = "\(libURL.lastPathComponent)/library.db · \(assets.count) assets · "
            + "iOS \(device.systemVersion) · \(device.model) · PlateCore shared & unchanged"
        return LoadResult(library: library, assets: assets, thumbs: thumbs, footer: footer)
    }
}

// MARK: - Collection view

extension LibraryGridViewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        assets.count
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: cellID, for: indexPath) as! ThumbCell
        let asset = assets[indexPath.item]
        cell.configure(image: thumbs[asset.id], asset: asset)
        return cell
    }

    func collectionView(_ collectionView: UICollectionView,
                        layout collectionViewLayout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        // Fixed row height, aspect-correct widths — echoes the Mac justified grid
        // and proves the ImageIO-derived dimensions flowed through PlateCore.
        let asset = assets[indexPath.item]
        let h: CGFloat = traitCollection.horizontalSizeClass == .regular ? 200 : 130
        let w = max(h * 0.6, min(h * 2.2, h * CGFloat(asset.aspectRatio)))
        return CGSize(width: w.rounded(), height: h)
    }
}

// MARK: - Cell

private final class ThumbCell: UICollectionViewCell {
    private let imageView = UIImageView()
    private let placeholder = UILabel()
    private let badge = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = PlateColor.surface
        contentView.layer.cornerRadius = 4
        contentView.layer.masksToBounds = true
        contentView.layer.borderWidth = 1
        contentView.layer.borderColor = PlateColor.hairline.cgColor

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        placeholder.text = "no preview"
        placeholder.textColor = PlateColor.textSubtle
        placeholder.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(placeholder)

        badge.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        badge.textColor = PlateColor.textPrimary
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        badge.textAlignment = .center
        badge.layer.cornerRadius = 3
        badge.layer.masksToBounds = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badge)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            badge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            badge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            badge.heightAnchor.constraint(equalToConstant: 15),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(image: UIImage?, asset: Asset) {
        imageView.image = image
        placeholder.isHidden = image != nil
        let dims = (asset.pixelWidth != nil && asset.pixelHeight != nil)
            ? " · \(asset.pixelWidth!)×\(asset.pixelHeight!)" : ""
        badge.text = "  \(asset.formatLabel)\(dims)  "
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.image = nil
    }
}

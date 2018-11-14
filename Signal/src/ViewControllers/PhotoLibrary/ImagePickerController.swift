//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import Photos
import PromiseKit

@objc(OWSImagePickerControllerDelegate)
protocol ImagePickerControllerDelegate {
    func imagePicker(_ imagePicker: ImagePickerGridController, didPickImageAttachments attachments: [SignalAttachment])
}

@objc(OWSImagePickerGridController)
class ImagePickerGridController: UICollectionViewController, PhotoLibraryDelegate, PhotoAlbumPickerDelegate {

    @objc
    weak var delegate: ImagePickerControllerDelegate?

    private let library: PhotoLibrary = PhotoLibrary()
    private var photoCollection: PhotoCollection
    private var libraryAlbum: PhotoLibraryAlbum

    var collectionViewFlowLayout: UICollectionViewFlowLayout

    init() {
        collectionViewFlowLayout = type(of: self).buildLayout()
        photoCollection = library.collectionForAllPhotos()
        libraryAlbum = photoCollection.contents()

        super.init(collectionViewLayout: collectionViewFlowLayout)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        library.add(delegate: self)

        guard let collectionView = collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        collectionView.register(PhotoGridViewCell.self, forCellWithReuseIdentifier: PhotoGridViewCell.reuseIdentifier)

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel,
                                                           target: self,
                                                           action: #selector(didPressCancel))

        let titleLabel = UILabel()
        titleLabel.text = libraryAlbum.localizedTitle
        titleLabel.textColor = Theme.primaryColor
        titleLabel.font = UIFont.ows_dynamicTypeBody.ows_mediumWeight()

        let titleIconView = UIImageView()
        titleIconView.tintColor = Theme.primaryColor
        titleIconView.image = UIImage(named: "navbar_disclosure_down")?.withRenderingMode(.alwaysTemplate)

        let titleView = UIStackView(arrangedSubviews: [titleLabel, titleIconView])
        titleView.axis = .horizontal
        titleView.alignment = .center
        titleView.spacing = 10
        titleView.isUserInteractionEnabled = true
        titleView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(titleTapped)))
        navigationItem.titleView = titleView

        let featureFlag_isMultiselectEnabled = true
        if featureFlag_isMultiselectEnabled {
            updateSelectButton()
        }

        collectionView.backgroundColor = Theme.backgroundColor
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateLayout()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Determine the size of the thumbnails to request
        let scale = UIScreen.main.scale
        let cellSize = collectionViewFlowLayout.itemSize
        libraryAlbum.thumbnailSize = CGSize(width: cellSize.width * scale, height: cellSize.height * scale)
    }

    // MARK: Actions

    @objc
    func didPressCancel(sender: UIBarButtonItem) {
        self.dismiss(animated: true)
    }

    // MARK: Layout

    static let kInterItemSpacing: CGFloat = 2
    private class func buildLayout() -> UICollectionViewFlowLayout {
        let layout = UICollectionViewFlowLayout()

        if #available(iOS 11, *) {
            layout.sectionInsetReference = .fromSafeArea
        }
        layout.minimumInteritemSpacing = kInterItemSpacing
        layout.minimumLineSpacing = kInterItemSpacing
        layout.sectionHeadersPinToVisibleBounds = true

        return layout
    }

    func updateLayout() {
        let containerWidth: CGFloat
        if #available(iOS 11.0, *) {
            containerWidth = self.view.safeAreaLayoutGuide.layoutFrame.size.width
        } else {
            containerWidth = self.view.frame.size.width
        }

        let kItemsPerPortraitRow = 4
        let screenWidth = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let approxItemWidth = screenWidth / CGFloat(kItemsPerPortraitRow)

        let itemCount = round(containerWidth / approxItemWidth)
        let spaceWidth = (itemCount + 1) * type(of: self).kInterItemSpacing
        let availableWidth = containerWidth - spaceWidth

        let itemWidth = floor(availableWidth / CGFloat(itemCount))
        let newItemSize = CGSize(width: itemWidth, height: itemWidth)

        if (newItemSize != collectionViewFlowLayout.itemSize) {
            collectionViewFlowLayout.itemSize = newItemSize
            collectionViewFlowLayout.invalidateLayout()
        }
    }

    // MARK: Batch Selection

    lazy var doneButton: UIBarButtonItem = {
        return UIBarButtonItem(barButtonSystemItem: .done,
                               target: self,
                               action: #selector(didPressDone))
    }()

    lazy var selectButton: UIBarButtonItem = {
        return UIBarButtonItem(title: NSLocalizedString("BUTTON_SELECT", comment: "Button text to enable batch selection mode"),
                               style: .plain,
                               target: self,
                               action: #selector(didTapSelect))
    }()

    var isInBatchSelectMode = false {
        didSet {
            collectionView!.allowsMultipleSelection = isInBatchSelectMode
            updateSelectButton()
            updateDoneButton()
        }
    }

    @objc
    func didPressDone(_ sender: Any) {
        Logger.debug("")

        guard let collectionView = self.collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        guard let indexPaths = collectionView.indexPathsForSelectedItems else {
            owsFailDebug("indexPaths was unexpectedly nil")
            return
        }

        let assets: [PHAsset] = indexPaths.compactMap { return self.libraryAlbum.asset(at: $0.row) }
        let promises = assets.map { return libraryAlbum.outgoingAttachment(for: $0) }
        when(fulfilled: promises).map { attachments in
            self.dismiss(animated: true) {
                self.delegate?.imagePicker(self, didPickImageAttachments: attachments)
            }
        }.retainUntilComplete()
    }

    func updateDoneButton() {
        guard let collectionView = self.collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        if let count = collectionView.indexPathsForSelectedItems?.count, count > 0 {
            self.doneButton.isEnabled = true
        } else {
            self.doneButton.isEnabled = false
        }
    }

    func updateSelectButton() {
        navigationItem.rightBarButtonItem = isInBatchSelectMode ? doneButton : selectButton
    }

    @objc
    func didTapSelect(_ sender: Any) {
        isInBatchSelectMode = true

        // disabled until at least one item is selected
        self.doneButton.isEnabled = false
    }

    @objc
    func didCancelSelect(_ sender: Any) {
        endSelectMode()
    }

    func endSelectMode() {
        isInBatchSelectMode = false

        guard let collectionView = self.collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        // deselect any selected
        collectionView.indexPathsForSelectedItems?.forEach { collectionView.deselectItem(at: $0, animated: false)}
    }

    // MARK: PhotoLibraryDelegate

    func photoLibraryDidChange(_ photoLibrary: PhotoLibrary) {
        collectionView?.reloadData()
    }

    // MARK: PhotoAlbumPickerDelegate

    func albumPicker(_ imagePicker: PhotoAlbumPickerController, didPickCollection collection: PhotoCollection) {
        photoCollection = collection
        libraryAlbum = photoCollection.contents()

        collectionView?.reloadData()
    }

    // MARK: - Event Handlers

    @objc func titleTapped(sender: UIGestureRecognizer) {
        guard sender.state == .recognized else {
            return
        }
        let view = PhotoAlbumPickerController(library: library,
                                              lastLibraryAlbum: libraryAlbum,
                                              albumDelegate: self)
        let nav = UINavigationController(rootViewController: view)
        self.present(nav, animated: true, completion: nil)
    }

    // MARK: UICollectionView

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if isInBatchSelectMode {
            updateDoneButton()
        } else {
            let asset = libraryAlbum.asset(at: indexPath.row)
            firstly {
                libraryAlbum.outgoingAttachment(for: asset)
            }.map { attachment in
                self.dismiss(animated: true) {
                    self.delegate?.imagePicker(self, didPickImageAttachments: [attachment])
                }
            }.retainUntilComplete()
        }
    }

    public override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        Logger.debug("")

        if isInBatchSelectMode {
            updateDoneButton()
        }
    }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return libraryAlbum.count
    }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoGridViewCell.reuseIdentifier, for: indexPath) as? PhotoGridViewCell else {
            owsFail("cell was unexpectedly nil")
        }

        let mediaItem = libraryAlbum.mediaItem(at: indexPath.item)
        cell.configure(item: mediaItem)
        return cell
    }

}

//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import Photos
import PromiseKit

protocol PhotoAlbumPickerDelegate: class {
    func albumPicker(_ imagePicker: PhotoAlbumPickerController, didPickCollection collection: PhotoCollection)
}

class PhotoAlbumPickerController: OWSTableViewController, PhotoLibraryDelegate {

    private weak var albumDelegate: PhotoAlbumPickerDelegate?

    private let library: PhotoLibrary
    private let lastLibraryAlbum: PhotoLibraryAlbum
    private var photoCollections: PhotoCollections

    required init(library: PhotoLibrary,
                  lastLibraryAlbum: PhotoLibraryAlbum,
                  albumDelegate: PhotoAlbumPickerDelegate) {
        self.library = library
        self.lastLibraryAlbum = lastLibraryAlbum
        self.photoCollections = library.allPhotoCollections()
        self.albumDelegate = albumDelegate
        super.init()
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        self.title = lastLibraryAlbum.localizedTitle

        library.add(delegate: self)

        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel,
                                                           target: self,
                                                           action: #selector(didPressCancel))

        updateContents()
    }

    private func updateContents() {
        photoCollections = library.allPhotoCollections()

        let section = OWSTableSection()
        let count = photoCollections.count
        for index in 0..<count {
            let collection = photoCollections.collection(at: index)
            section.add(OWSTableItem.init(customCellBlock: { () -> UITableViewCell in
                let cell = OWSTableItem.newCell()

                let titleLabel = UILabel()
                titleLabel.text = collection.localizedTitle()
                titleLabel.font = UIFont.ows_regularFont(withSize: 18)
                titleLabel.textColor = Theme.primaryColor

                let stackView = UIStackView(arrangedSubviews: [titleLabel])
                stackView.axis = .horizontal
                stackView.alignment = .center
                stackView.spacing = 10

                cell.contentView.addSubview(stackView)
                stackView.ows_autoPinToSuperviewMargins()

                return cell
            },
                                          customRowHeight: UITableViewAutomaticDimension,
                                          actionBlock: { [weak self] in
                                            guard let strongSelf = self else { return }
                                            strongSelf.didSelectCollection(collection: collection)
            }))
        }
        let contents = OWSTableContents()
        contents.addSection(section)
        self.contents = contents
    }

    // MARK: Actions

    @objc
    func didPressCancel(sender: UIBarButtonItem) {
        self.dismiss(animated: true)
    }

    func didSelectCollection(collection: PhotoCollection) {
        albumDelegate?.albumPicker(self, didPickCollection: collection)

        self.dismiss(animated: true)
    }

    // MARK: PhotoLibraryDelegate

    func photoLibraryDidChange(_ photoLibrary: PhotoLibrary) {
        updateContents()
    }
}

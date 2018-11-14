//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import Photos
import PromiseKit

protocol PhotoLibraryDelegate: class {
    func photoLibraryDidChange(_ photoLibrary: PhotoLibrary)
}

class ImagePickerGridItem: PhotoGridItem {

    let asset: PHAsset
    let album: PhotoLibraryAlbum

    init(asset: PHAsset, album: PhotoLibraryAlbum) {
        self.asset = asset
        self.album = album
    }

    // MARK: PhotoGridItem

    var type: PhotoGridItemType {
        if asset.mediaType == .video {
            return .video
        }

        // TODO show GIF badge?

        return  .photo
    }

    func asyncThumbnail(completion: @escaping (UIImage?) -> Void) -> UIImage? {
        album.requestThumbnail(for: self.asset) { image, _ in
            completion(image)
        }
        return nil
    }
}

class PhotoLibraryAlbum {

    let fetchResult: PHFetchResult<PHAsset>
    let localizedTitle: String?
    var thumbnailSize: CGSize = .zero

    enum PhotoLibraryError: Error {
        case assertionError(description: String)
        case unsupportedMediaType

    }

    init(fetchResult: PHFetchResult<PHAsset>, localizedTitle: String?) {
        self.fetchResult = fetchResult
        self.localizedTitle = localizedTitle
    }

    var count: Int {
        return fetchResult.count
    }

    private let imageManager = PHCachingImageManager()

    func asset(at index: Int) -> PHAsset {
        return fetchResult.object(at: index)
    }

    func mediaItem(at index: Int) -> ImagePickerGridItem {
        let mediaAsset = asset(at: index)
        return ImagePickerGridItem(asset: mediaAsset, album: self)
    }

    // MARK: ImageManager

    func requestThumbnail(for asset: PHAsset, resultHandler: @escaping (UIImage?, [AnyHashable: Any]?) -> Void) {
        _ = imageManager.requestImage(for: asset, targetSize: thumbnailSize, contentMode: .aspectFill, options: nil, resultHandler: resultHandler)
    }

    private func requestImageDataSource(for asset: PHAsset) -> Promise<(dataSource: DataSource, dataUTI: String)> {
        return Promise { resolver in
            _ = imageManager.requestImageData(for: asset, options: nil) { imageData, dataUTI, _, _ in
                guard let imageData = imageData else {
                    resolver.reject(PhotoLibraryError.assertionError(description: "imageData was unexpectedly nil"))
                    return
                }

                guard let dataUTI = dataUTI else {
                    resolver.reject(PhotoLibraryError.assertionError(description: "dataUTI was unexpectedly nil"))
                    return
                }

                guard let dataSource = DataSourceValue.dataSource(with: imageData, utiType: dataUTI) else {
                    resolver.reject(PhotoLibraryError.assertionError(description: "dataSource was unexpectedly nil"))
                    return
                }

                resolver.fulfill((dataSource: dataSource, dataUTI: dataUTI))
            }
        }
    }

    private func requestVideoDataSource(for asset: PHAsset) -> Promise<(dataSource: DataSource, dataUTI: String)> {
        return Promise { resolver in

            _ = imageManager.requestExportSession(forVideo: asset, options: nil, exportPreset: AVAssetExportPresetMediumQuality) { exportSession, _ in

                guard let exportSession = exportSession else {
                    resolver.reject(PhotoLibraryError.assertionError(description: "exportSession was unexpectedly nil"))
                    return
                }

                exportSession.outputFileType = AVFileType.mp4
                exportSession.metadataItemFilter = AVMetadataItemFilter.forSharing()

                let exportPath = OWSFileSystem.temporaryFilePath(withFileExtension: "mp4")
                let exportURL = URL(fileURLWithPath: exportPath)
                exportSession.outputURL = exportURL

                Logger.debug("starting video export")
                exportSession.exportAsynchronously {
                    Logger.debug("Completed video export")

                    guard let dataSource = DataSourcePath.dataSource(with: exportURL, shouldDeleteOnDeallocation: true) else {
                        resolver.reject(PhotoLibraryError.assertionError(description: "Failed to build data source for exported video URL"))
                        return
                    }

                    resolver.fulfill((dataSource: dataSource, dataUTI: kUTTypeMPEG4 as String))
                }
            }
        }
    }

    func outgoingAttachment(for asset: PHAsset) -> Promise<SignalAttachment> {
        switch asset.mediaType {
        case .image:
            return requestImageDataSource(for: asset).map { (dataSource: DataSource, dataUTI: String) in
                return SignalAttachment.attachment(dataSource: dataSource, dataUTI: dataUTI, imageQuality: .medium)
            }
        case .video:
            return requestVideoDataSource(for: asset).map { (dataSource: DataSource, dataUTI: String) in
                return SignalAttachment.attachment(dataSource: dataSource, dataUTI: dataUTI)
            }
        default:
            return Promise(error: PhotoLibraryError.unsupportedMediaType)
        }
    }
}

protocol PhotoCollection: class {
    func localizedTitle() -> String
    func contents() -> PhotoLibraryAlbum
}

class PhotoCollectionAllPhotos: PhotoCollection {
    func localizedTitle() -> String {
        return NSLocalizedString("PHOTO_PICKER_DEFAULT_ALBUM", comment: "navbar title when viewing the default photo album, which includes all photos")
    }

    func contents() -> PhotoLibraryAlbum {
        let allPhotosOptions = PHFetchOptions()
        allPhotosOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetchResult = PHAsset.fetchAssets(with: allPhotosOptions)

        return PhotoLibraryAlbum(fetchResult: fetchResult, localizedTitle: localizedTitle())
    }
}

class PhotoCollectionDefault: PhotoCollection {
    private let collection: PHAssetCollection

    init(collection: PHAssetCollection) {
        self.collection = collection
    }

    func localizedTitle() -> String {
        guard let localizedTitle = collection.localizedTitle?.stripped,
            localizedTitle.count > 0 else {
            return NSLocalizedString("PHOTO_PICKER_UNNAMED_COLLECTION", comment: "label for system photo collections which have no name.")
        }
        return localizedTitle
    }

    func contents() -> PhotoLibraryAlbum {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetchResult = PHAsset.fetchAssets(in: collection, options: options)

        return PhotoLibraryAlbum(fetchResult: fetchResult, localizedTitle: localizedTitle())
    }
}

class PhotoCollections {
    let collections: [PhotoCollection]

    init(collections: [PhotoCollection]) {
        self.collections = collections
    }

    var count: Int {
        return collections.count
    }

    func collection(at index: Int) -> PhotoCollection {
        return collections[index]
    }
}

class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    final class WeakDelegate {
        weak var delegate: PhotoLibraryDelegate?
        init(_ value: PhotoLibraryDelegate) {
            delegate = value
        }
    }
    var delegates = [WeakDelegate]()

    public func add(delegate: PhotoLibraryDelegate) {
        delegates.append(WeakDelegate(delegate))
    }

    var assetCollection: PHAssetCollection!

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            for weakDelegate in self.delegates {
                weakDelegate.delegate?.photoLibraryDidChange(self)
            }
        }
    }

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func collectionForAllPhotos() -> PhotoCollection {
        return PhotoCollectionAllPhotos()
    }

    func allPhotoCollections() -> PhotoCollections {
        // TODO: Sort

        var collections = [PhotoCollection]()
        collections.append(PhotoCollectionAllPhotos())

        let processPHCollection: (PHCollection) -> Void = { (collection) in
            guard let assetCollection = collection as? PHAssetCollection else {
                owsFailDebug("Asset collection has unexpected type: \(type(of: collection))")
                return
            }
            Logger.verbose("----- collection: \(collection.localizedTitle)")
            let photoCollection = PhotoCollectionDefault(collection: assetCollection)
            guard photoCollection.contents().count > 0 else {
                return
            }
            collections.append(photoCollection)
        }
        let processPHAssetCollections: (PHFetchResult<PHAssetCollection>) -> Void = { (fetchResult) in
            for index in 0..<fetchResult.count {
                processPHCollection(fetchResult.object(at: index))
            }
        }
        let processPHCollections: (PHFetchResult<PHCollection>) -> Void = { (fetchResult) in
            for index in 0..<fetchResult.count {
                processPHCollection(fetchResult.object(at: index))
            }
        }
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "endDate", ascending: true)]
        let userCollections: PHFetchResult<PHCollection> =
            PHAssetCollection.fetchTopLevelUserCollections(with: fetchOptions)
        processPHCollections(userCollections)
        processPHAssetCollections(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .albumRegular, options: fetchOptions))

//        PHFetchResult *albums = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeSmartAlbum subtype:PHAssetCollectionSubtypeAlbumRegular options:nil];
//        for (PHAssetCollection *sub in albums)
//        {
//            PHFetchResult *fetchResult = [PHAsset fetchAssetsInAssetCollection:sub options:options];
//        }

        Logger.verbose("userCollections: \(userCollections.count)")
//        Logger.verbose("userCollections: \(PHAssetCollection.fetchAssetCollections(with: .album, subtype: PHAssetCollectionSubtype, options: <#T##PHFetchOptions?#>).count)")
        Logger.flush()

//            PHAssetCollection.fetchTopLevelUserCollections(with: nil)
//        let userCollections : PHFetchResult<PHCollection> =
//        PHAssetCollection.fetchTopLevelUserCollections(with: nil)
//        var photoCollections = [PhotoCollection]()

        return PhotoCollections(collections: collections)
//        PHAssetCollection.fetchass
//        PHAssetCollection.fetchAssetCollections(with: PHAssetCollectionType, subtype: <#T##PHAssetCollectionSubtype#>, options: <#T##PHFetchOptions?#>)
//        case album
//        
//        case smartAlbum
//        
//        case moment

//    NSArray *collectionsFetchResults;
//    NSMutableArray *localizedTitles = [[NSMutableArray alloc] init];
//
//    PHFetchResult *smartAlbums = [PHAssetCollection       fetchAssetCollectionsWithType:PHAssetCollectionTypeSmartAlbum
//    subtype:PHAssetCollectionSubtypeAlbumRegular options:nil];
//    PHFetchResult *syncedAlbums = [PHAssetCollection fetchAssetCollectionsWithType:PHAssetCollectionTypeAlbum
//    subtype:PHAssetCollectionSubtypeAlbumSyncedAlbum options:nil];
//    PHFetchResult *userCollections = [PHCollectionList fetchTopLevelUserCollectionsWithOptions:nil];
//
//    // Add each PHFetchResult to the array
//    collectionsFetchResults = @[smartAlbums, userCollections, syncedAlbums];
//
//    for (int i = 0; i < collectionsFetchResults.count; i ++) {
//
//    PHFetchResult *fetchResult = collectionsFetchResults[i];
//
//    for (int x = 0; x < fetchResult.count; x ++) {
//
//    PHCollection *collection = fetchResult[x];
//    localizedTitles[x] = collection.localizedTitle;
//
//    }
    }
}

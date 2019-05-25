
import UIKit
import AVFoundation


class VideoPreview: UIView {

	// This view should have a AVCaptureVideoPreviewLayer as its main layer
	override class var layerClass: AnyClass { return AVCaptureVideoPreviewLayer.self }
	var videoPreviewLayer: AVCaptureVideoPreviewLayer { return layer as! AVCaptureVideoPreviewLayer }


	lazy var session: AVCaptureSession = {
		let session = AVCaptureSession()
		videoPreviewLayer.session = session
		return session
	}()

	lazy var queue = { return DispatchQueue(label: String(describing: self)) }()

}

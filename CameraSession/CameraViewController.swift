
import UIKit
import AVFoundation
import Photos


class CameraViewController: UIViewController, CameraSessionViewDelegate {

	// To be moved to VideoPreview or removed completely
	private var session: AVCaptureSession { return cameraSessionView.session }
	private var sessionQueue: DispatchQueue { return cameraSessionView.queue }

	func cameraSessionView(_ cameraSessionView: CameraSessionView, didCompleteConfigurationWithStatus status: CameraSessionView.Status) {
		switch status {
		case .undefined:
			preconditionFailure()

		case .configured:
			self.cameraButton.isEnabled = cameraSessionView.hasBackAndFront
			// TODO: enable the two below based on output object availability
			self.recordButton.isEnabled = cameraSessionView.isVideo
			self.photoButton.isEnabled = cameraSessionView.isPhoto
			self.captureModeControl.isEnabled = true
			self.captureModeControl.selectedSegmentIndex = cameraSessionView.isPhoto ? 0 : 1
			break

		case .notAuthorized:
			let alertController = UIAlertController(title: "Camera", message: "The app doesn't have permission to use the camera, please change privacy settings", preferredStyle: .alert)
			alertController.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
			alertController.addAction(UIAlertAction(title: "Settings", style: .`default`, handler: { _ in
				UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
			}))
			self.present(alertController, animated: true, completion: nil)

		case let .configurationFailed(message):
			let alertController = UIAlertController(title: "Camera", message: message, preferredStyle: .alert)
			alertController.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
			self.present(alertController, animated: true, completion: nil)
		}
	}


	func cameraSessionViewWillCapturePhoto(_ cameraSessionView: CameraSessionView) {
		// Flash the screen to signal that CameraSessionView took a photo.
		self.cameraSessionView.videoPreviewLayer.opacity = 0
		UIView.animate(withDuration: 0.25) {
			self.cameraSessionView.videoPreviewLayer.opacity = 1
		}
	}


	func cameraSessionView(_ cameraSessionView: CameraSessionView, didCapturePhoto photo: AVCapturePhoto?, error: Error?) {
		if let data = photo?.fileDataRepresentation() {
			PHPhotoLibrary.requestAuthorization { status in
				if status == .authorized {
					PHPhotoLibrary.shared().performChanges({
						let options = PHAssetResourceCreationOptions()
						options.uniformTypeIdentifier = AVFileType.jpg.rawValue
						let creationRequest = PHAssetCreationRequest.forAsset()
						creationRequest.addResource(with: .photo, data: data, options: options)
					},
					completionHandler: { _, error in
						if let error = error {
							print("Error occurred while saving photo to photo library: \(error)")
						}
					})
				}
			}
		}
	}


	func cameraSessionViewDidStartRecording(_ cameraSessionView: CameraSessionView) {
		self.recordButton.isEnabled = true
		self.recordButton.setImage(#imageLiteral(resourceName: "CaptureStop"), for: [])
	}


	func cameraSessionView(_ cameraSessionView: CameraSessionView, didFinishRecordingTo fileUrl: URL, error: Error?) {

		// Note: Since we use a unique file path for each recording, a new recording won't overwrite a recording mid-save.
		func cleanup() {
			try? FileManager.default.removeItem(at: fileUrl)
		}

		var success = true

		if error != nil {
			print("Movie file finishing error: \(String(describing: error))")
			success = (((error! as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as AnyObject).boolValue)!
		}

		if success {
			// Check authorization status.
			PHPhotoLibrary.requestAuthorization { status in
				if status == .authorized {
					// Save the movie file to the photo library and cleanup.
					PHPhotoLibrary.shared().performChanges({
						let options = PHAssetResourceCreationOptions()
						options.shouldMoveFile = true
						let creationRequest = PHAssetCreationRequest.forAsset()
						creationRequest.addResource(with: .video, fileURL: fileUrl, options: options)
					}, completionHandler: { success, error in
						if !success {
							print("CameraSessionView couldn't save the movie to your photo library: \(String(describing: error))")
						}
						cleanup()
					}
					)
				} else {
					cleanup()
				}
			}
		} else {
			cleanup()
		}

		// Enable the Camera and Record buttons to let the user switch camera and start another recording.
		// Only enable the ability to change camera if the device has more than one camera.
		self.cameraButton.isEnabled = self.cameraSessionView.hasBackAndFront
		self.recordButton.isEnabled = true
		self.captureModeControl.isEnabled = true
		self.recordButton.setImage(#imageLiteral(resourceName: "CaptureVideo"), for: [])
	}


	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

	// MARK: View Controller Life Cycle

	override func viewDidLoad() {
		super.viewDidLoad()

		// Disable UI. Enable the UI later when (and if) the session starts running.
		disableAllControls()

		cameraSessionView.initialize(delegate: self, isPhoto: false, isFront: false)
	}


	private func disableAllControls() {
		cameraButton.isEnabled = false
		recordButton.isEnabled = false
		photoButton.isEnabled = false
		captureModeControl.isEnabled = false
	}


	@IBOutlet private weak var cameraSessionView: CameraSessionView!

	@IBAction private func resumeInterruptedSession(_ resumeButton: UIButton) {
		sessionQueue.async {
			/*
			The session might fail to start running, e.g., if a phone or FaceTime call is still
			using audio or video. A failure to start the session running will be communicated via
			a session runtime error notification. To avoid repeatedly failing to start the session
			running, we only try to restart the session running in the session runtime error handler
			if we aren't trying to resume the session running.
			*/
			self.session.startRunning()
			self.cameraSessionView.isSessionRunning = self.session.isRunning
			if !self.session.isRunning {
				DispatchQueue.main.async {
					let alertController = UIAlertController(title: "Camera", message: "Unable to resume", preferredStyle: .alert)
					let cancelAction = UIAlertAction(title: "OK", style: .cancel, handler: nil)
					alertController.addAction(cancelAction)
					self.present(alertController, animated: true, completion: nil)
				}
			} else {
				DispatchQueue.main.async {
					self.resumeButton.isHidden = true
				}
			}
		}
	}

	private enum CaptureMode: Int {
		case photo = 0
		case movie = 1
	}

	@IBOutlet private weak var captureModeControl: UISegmentedControl!

	@IBAction private func toggleCaptureMode(_ captureModeControl: UISegmentedControl) {
		disableAllControls()
		cameraSessionView.isPhoto = captureModeControl.selectedSegmentIndex == CaptureMode.photo.rawValue
	}

	// MARK: Device Configuration

	@IBOutlet private weak var cameraButton: UIButton!

	@IBOutlet private weak var cameraUnavailableLabel: UILabel!

	@IBAction private func changeCamera(_ cameraButton: UIButton) {
		disableAllControls()
		cameraSessionView.isFront = !cameraSessionView.isFront
	}

	@IBAction private func focusAndExposeTap(_ gestureRecognizer: UITapGestureRecognizer) {
		cameraSessionView.focus(with: .autoFocus, exposureMode: .autoExpose, atPoint: gestureRecognizer.location(in: cameraSessionView), monitorSubjectAreaChange: true)
	}

	// MARK: Capturing Photos

	@IBOutlet private weak var photoButton: UIButton!

	@IBAction private func capturePhoto(_ photoButton: UIButton) {
		cameraSessionView.capturePhoto()
	}

	// MARK: Recording Movies

	@IBOutlet private weak var recordButton: UIButton!

	@IBOutlet private weak var resumeButton: UIButton!

	@IBAction private func toggleMovieRecording(_ recordButton: UIButton) {

		cameraButton.isEnabled = false
		recordButton.isEnabled = false
		captureModeControl.isEnabled = false

		if cameraSessionView.isRecording {
			cameraSessionView.stopRecording()
		}
		else {
			let outputFileName = NSUUID().uuidString
			let outputFilePath = (NSTemporaryDirectory() as NSString).appendingPathComponent((outputFileName as NSString).appendingPathExtension("mp4")!)
			cameraSessionView.startVideoRecording(toFileURL: URL(fileURLWithPath: outputFilePath))
		}
	}
}



import UIKit
import AVFoundation
import Photos

class CameraViewController: UIViewController, AVCaptureFileOutputRecordingDelegate, CameraViewDelegate {

	// To be moved to VideoPreview or removed completely
	private var session: AVCaptureSession { return videoPreview.session }
	private var sessionQueue: DispatchQueue { return videoPreview.queue }
	private var status: CameraViewStatus { get { return videoPreview.status } }
	private var movieFileOutput: AVCaptureMovieFileOutput? { return videoPreview.videoOutput }

	func cameraView(_ cameraView: CameraView, didCompleteConfigurationWithStatus status: CameraViewStatus) {
		switch status {
		case .undefined:
			preconditionFailure()

		case .configured:
			self.cameraButton.isEnabled = videoPreview.hasBackAndFront
			// TODO: enable the two below based on output object availability
			self.recordButton.isEnabled = cameraView.isVideo
			self.photoButton.isEnabled = cameraView.isPhoto
			self.captureModeControl.isEnabled = true
			self.captureModeControl.selectedSegmentIndex = cameraView.isPhoto ? 0 : 1
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


	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -

	// MARK: View Controller Life Cycle

	override func viewDidLoad() {
		super.viewDidLoad()

		// Disable UI. Enable the UI later when (and if) the session starts running.
		disableAllControls()

		videoPreview.initialize(delegate: self, isPhoto: false, isFront: false)
	}


	private func disableAllControls() {
		cameraButton.isEnabled = false
		recordButton.isEnabled = false
		photoButton.isEnabled = false
		captureModeControl.isEnabled = false
	}


	@IBOutlet private weak var videoPreview: CameraView!

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
			self.videoPreview.isSessionRunning = self.session.isRunning
			if !self.session.isRunning {
				DispatchQueue.main.async {
					let message = NSLocalizedString("Unable to resume", comment: "Alert message when unable to resume the session running")
					let alertController = UIAlertController(title: "AVCam", message: message, preferredStyle: .alert)
					let cancelAction = UIAlertAction(title: NSLocalizedString("OK", comment: "Alert OK button"), style: .cancel, handler: nil)
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

	/// - Tag: EnableDisableModes
	@IBAction private func toggleCaptureMode(_ captureModeControl: UISegmentedControl) {
		disableAllControls()
		videoPreview.isPhoto = captureModeControl.selectedSegmentIndex == CaptureMode.photo.rawValue
	}

	// MARK: Device Configuration

	@IBOutlet private weak var cameraButton: UIButton!

	@IBOutlet private weak var cameraUnavailableLabel: UILabel!

	/// - Tag: ChangeCamera
	@IBAction private func changeCamera(_ cameraButton: UIButton) {
		disableAllControls()
		videoPreview.isFront = !videoPreview.isFront
	}

	@IBAction private func focusAndExposeTap(_ gestureRecognizer: UITapGestureRecognizer) {
		let devicePoint = videoPreview.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: gestureRecognizer.location(in: gestureRecognizer.view))
		videoPreview.focus(with: .autoFocus, exposureMode: .autoExpose, at: devicePoint, monitorSubjectAreaChange: true)
	}

	// MARK: Capturing Photos

	private var inProgressPhotoCaptureDelegates = [Int64: PhotoCaptureProcessor]()

	@IBOutlet private weak var photoButton: UIButton!

	/// - Tag: CapturePhoto
	@IBAction private func capturePhoto(_ photoButton: UIButton) {
		/*
		Retrieve the video preview layer's video orientation on the main queue before
		entering the session queue. We do this to ensure UI elements are accessed on
		the main thread and session configuration is done on the session queue.
		*/
		guard let photoOutput = videoPreview.photoOutput else {
			preconditionFailure()
		}
		let videoPreviewLayerOrientation = videoPreview.videoPreviewLayer.connection?.videoOrientation

		sessionQueue.async {
			if let photoOutputConnection = photoOutput.connection(with: .video) {
				photoOutputConnection.videoOrientation = videoPreviewLayerOrientation!
			}
			var photoSettings = AVCapturePhotoSettings()

			// Capture HEIF photos when supported. Enable auto-flash and high-resolution photos.
			if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
				photoSettings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
			}

			if self.videoPreview.videoDeviceInput.device.isFlashAvailable {
				photoSettings.flashMode = .auto
			}

			photoSettings.isHighResolutionPhotoEnabled = true
			if !photoSettings.__availablePreviewPhotoPixelFormatTypes.isEmpty {
				photoSettings.previewPhotoFormat = [kCVPixelBufferPixelFormatTypeKey as String: photoSettings.__availablePreviewPhotoPixelFormatTypes.first!]
			}

			let photoCaptureProcessor = PhotoCaptureProcessor(with: photoSettings, willCapturePhotoAnimation: {
				// Flash the screen to signal that AVCam took a photo.
				DispatchQueue.main.async {
					self.videoPreview.videoPreviewLayer.opacity = 0
					UIView.animate(withDuration: 0.25) {
						self.videoPreview.videoPreviewLayer.opacity = 1
					}
				}
			}, completionHandler: { photoCaptureProcessor in
				// When the capture is complete, remove a reference to the photo capture delegate so it can be deallocated.
				self.sessionQueue.async {
					self.inProgressPhotoCaptureDelegates[photoCaptureProcessor.requestedPhotoSettings.uniqueID] = nil
				}
			}
			)

			// The photo output keeps a weak reference to the photo capture delegate and stores it in an array to maintain a strong reference.
			self.inProgressPhotoCaptureDelegates[photoCaptureProcessor.requestedPhotoSettings.uniqueID] = photoCaptureProcessor
			photoOutput.capturePhoto(with: photoSettings, delegate: photoCaptureProcessor)
		}
	}

	// MARK: Recording Movies

	private var backgroundRecordingID: UIBackgroundTaskIdentifier?

	@IBOutlet private weak var recordButton: UIButton!

	@IBOutlet private weak var resumeButton: UIButton!

	@IBAction private func toggleMovieRecording(_ recordButton: UIButton) {
		guard let movieFileOutput = self.movieFileOutput else {
			return
		}

		/*
		Disable the Camera button until recording finishes, and disable
		the Record button until recording starts or finishes.

		See the AVCaptureFileOutputRecordingDelegate methods.
		*/
		cameraButton.isEnabled = false
		recordButton.isEnabled = false
		captureModeControl.isEnabled = false

		let videoPreviewLayerOrientation = videoPreview.videoPreviewLayer.connection?.videoOrientation

		sessionQueue.async {
			if !movieFileOutput.isRecording {
				if UIDevice.current.isMultitaskingSupported {
					self.backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
				}

				// Update the orientation on the movie file output video connection before recording.
				let movieFileOutputConnection = movieFileOutput.connection(with: .video)
				movieFileOutputConnection?.videoOrientation = videoPreviewLayerOrientation!

				let availableVideoCodecTypes = movieFileOutput.availableVideoCodecTypes

				if availableVideoCodecTypes.contains(.hevc) {
					movieFileOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: movieFileOutputConnection!)
				}

				// Start recording video to a temporary file.
				let outputFileName = NSUUID().uuidString
				let outputFilePath = (NSTemporaryDirectory() as NSString).appendingPathComponent((outputFileName as NSString).appendingPathExtension("mov")!)
				movieFileOutput.startRecording(to: URL(fileURLWithPath: outputFilePath), recordingDelegate: self)
			} else {
				movieFileOutput.stopRecording()
			}
		}
	}

	/// - Tag: DidStartRecording
	func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
		// Enable the Record button to let the user stop recording.
		DispatchQueue.main.async {
			self.recordButton.isEnabled = true
			self.recordButton.setImage(#imageLiteral(resourceName: "CaptureStop"), for: [])
		}
	}

	/// - Tag: DidFinishRecording
	func fileOutput(_ output: AVCaptureFileOutput,
					didFinishRecordingTo outputFileURL: URL,
					from connections: [AVCaptureConnection],
					error: Error?) {
		// Note: Since we use a unique file path for each recording, a new recording won't overwrite a recording mid-save.
		func cleanup() {
			let path = outputFileURL.path
			if FileManager.default.fileExists(atPath: path) {
				do {
					try FileManager.default.removeItem(atPath: path)
				} catch {
					print("Could not remove file at url: \(outputFileURL)")
				}
			}

			if let currentBackgroundRecordingID = backgroundRecordingID {
				backgroundRecordingID = UIBackgroundTaskIdentifier.invalid

				if currentBackgroundRecordingID != UIBackgroundTaskIdentifier.invalid {
					UIApplication.shared.endBackgroundTask(currentBackgroundRecordingID)
				}
			}
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
						creationRequest.addResource(with: .video, fileURL: outputFileURL, options: options)
					}, completionHandler: { success, error in
						if !success {
							print("AVCam couldn't save the movie to your photo library: \(String(describing: error))")
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
		DispatchQueue.main.async {
			// Only enable the ability to change camera if the device has more than one camera.
			self.cameraButton.isEnabled = self.videoPreview.hasBackAndFront
			self.recordButton.isEnabled = true
			self.captureModeControl.isEnabled = true
			self.recordButton.setImage(#imageLiteral(resourceName: "CaptureVideo"), for: [])
		}
	}

}


//
//  CameraViewController.swift
//
//  Created by Hovik Melikyan on 26/05/2019.
//  Copyright © 2019 Hovik Melikyan. All rights reserved.
//


import UIKit
import Photos
import MetalPetal


class CameraViewController: UIViewController, CameraSessionDelegate {

	func cameraSession(_ cameraSession: CameraSession, didCompleteConfigurationWithStatus status: CameraSession.Status) {
		switch status {
		case .undefined:
			preconditionFailure()

		case .configured:
			cameraButton.isEnabled = cameraSession.hasBackAndFront
			recordButton.isEnabled = true
			photoButton.isEnabled = true
			zoomButton.isEnabled = cameraSession.hasZoom
			zoomButton.isHidden = !cameraSession.hasZoom
			torchButton.isEnabled = cameraSession.hasTorch
			torchButton.isHidden = !cameraSession.hasTorch
			if videoEffects == nil {
				videoEffects = VideoEffects(dimensions: cameraSession.videoDimensions!, initialFilterType: .monochrome)
			}
			break

		case .notAuthorized:
			let alertController = UIAlertController(title: "Camera", message: "The app doesn't have permission to use the camera, please change privacy settings", preferredStyle: .alert)
			alertController.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
			alertController.addAction(UIAlertAction(title: "Settings", style: .`default`, handler: { _ in
				UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:], completionHandler: nil)
			}))
			present(alertController, animated: true, completion: nil)

		case let .configurationFailed(message):
			let alertController = UIAlertController(title: "Camera", message: message, preferredStyle: .alert)
			alertController.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
			present(alertController, animated: true, completion: nil)
		}
	}


	func cameraSessionDidChangeZoomLevel(_ cameraSession: CameraSession) {
		zoomButton.setTitle("\(Int(cameraSession.zoomLevel))x", for: .normal)
	}

	func cameraSessionWillCapturePhoto(_ cameraSession: CameraSession) {
		// Flash the screen to signal that CameraSession took a photo.
		self.cameraPreview.alpha = 0
		UIView.animate(withDuration: 0.25) {
			self.cameraPreview.alpha = 1
		}
	}


	func cameraSession(_ cameraSession: CameraSession, didCapturePhoto photo: AVCapturePhoto?, error: Error?) {
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


	func cameraSessionDidStartRecording(_ cameraSession: CameraSession) {
		self.recordButton.isEnabled = true
		self.recordButton.setImage(#imageLiteral(resourceName: "CaptureStop"), for: [])
	}


	func cameraSession(_ cameraSession: CameraSession, didFinishRecordingTo fileUrl: URL?, error: Error?) {

		if let error = error {
			print("Movie file finishing error: \(String(describing: error))")
			// success = ((error! as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as AnyObject).boolValue ?? false
		}

		else if let fileUrl = fileUrl {
			let videoFileUrl = self.videoFileUrl
			try? FileManager.default.removeItem(at: videoFileUrl)
			try! FileManager.default.moveItem(at: fileUrl, to: videoFileUrl)
			PHPhotoLibrary.requestAuthorization { status in
				if status == .authorized {
					// Save the movie file to the photo library and cleanup.
					PHPhotoLibrary.shared().performChanges({
						let options = PHAssetResourceCreationOptions()
						options.shouldMoveFile = true
						let creationRequest = PHAssetCreationRequest.forAsset()
						creationRequest.addResource(with: .video, fileURL: videoFileUrl, options: options)
					}, completionHandler: { success, error in
						if !success {
							print("CameraSession couldn't save the movie to your photo library: \(String(describing: error))")
						}
					}
					)
				}
			}
		}

		// Enable the Camera and Record buttons to let the user switch camera and start another recording.
		// Only enable the ability to change camera if the device has more than one camera.
		self.cameraButton.isEnabled = self.cameraSession.hasBackAndFront
		self.recordButton.isEnabled = true
		self.recordButton.setImage(#imageLiteral(resourceName: "CaptureVideo"), for: [])
	}


	func cameraSession(_ cameraSession: CameraSession, wasInterruptedWithError: Error?) {
		self.resumeButton.isHidden = false
	}


	func cameraSession(_ cameraSession: CameraSession, wasInterruptedWithReason reason: AVCaptureSession.InterruptionReason) {
		var showResumeButton = false
		if reason == .audioDeviceInUseByAnotherClient || reason == .videoDeviceInUseByAnotherClient {
			showResumeButton = true
		} else if reason == .videoDeviceNotAvailableWithMultipleForegroundApps {
			// Fade-in a label to inform the user that the camera is unavailable.
			cameraUnavailableLabel.alpha = 0
			cameraUnavailableLabel.isHidden = false
			UIView.animate(withDuration: 0.25) {
				self.cameraUnavailableLabel.alpha = 1
			}
		} else if reason == .videoDeviceNotAvailableDueToSystemPressure {
			print("CameraSession error: Session stopped running due to shutdown system pressure level.")
		}
		if showResumeButton {
			// Fade-in a button to enable the user to try to resume the session running.
			resumeButton.alpha = 0
			resumeButton.isHidden = false
			UIView.animate(withDuration: 0.25) {
				self.resumeButton.alpha = 1
			}
		}
	}


	func cameraSession(_ cameraSession: CameraSession, didResumeInterruptedSessionWithResult result: Bool) {
		if !result {
			let alertController = UIAlertController(title: "Camera", message: "Unable to resume", preferredStyle: .alert)
			let cancelAction = UIAlertAction(title: "OK", style: .cancel, handler: nil)
			alertController.addAction(cancelAction)
			self.present(alertController, animated: true, completion: nil)
		}
		else {
			if !resumeButton.isHidden {
				UIView.animate(withDuration: 0.25, animations: {
					self.resumeButton.alpha = 0
				}, completion: { _ in
					self.resumeButton.isHidden = true
				})
			}
			if !cameraUnavailableLabel.isHidden {
				UIView.animate(withDuration: 0.25, animations: {
					self.cameraUnavailableLabel.alpha = 0
				}, completion: { _ in
					self.cameraUnavailableLabel.isHidden = true
				})
			}
		}
	}


	func cameraSession(_ cameraSession: CameraSession, didCaptureBuffer sampleBuffer: CMSampleBuffer) -> CMSampleBuffer {
		if let outputImage = videoEffects.applyEffect(on: sampleBuffer) {
			DispatchQueue.main.async {
				self.cameraPreview.image = outputImage
			}
			return videoEffects.replaceSampleBuffer(sampleBuffer, withImage: outputImage)
		}
		else {
			return sampleBuffer
		}
	}


	private var videoFileUrl: URL {
		return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("video").appendingPathExtension(CameraSession.videoFileExt)
	}


	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -


	override func viewDidLoad() {
		super.viewDidLoad()
		disableAllControls()

		zoomButton.layer.borderColor = zoomButton.tintColor.cgColor
		zoomButton.layer.borderWidth = 1
		zoomButton.layer.cornerRadius = 5

		cameraPreview.resizingMode = .aspectFill
		cameraSession = CameraSession(delegate: self, isFront: false)
	}


	private func disableAllControls() {
		cameraButton.isEnabled = false
		recordButton.isEnabled = false
		photoButton.isEnabled = false
		torchButton.isEnabled = false
	}


	@IBOutlet private weak var cameraPreview: MTIImageView!
	private var cameraSession: CameraSession!
	private var videoEffects: VideoEffects!


	private enum CaptureMode: Int {
		case photo = 0
		case movie = 1
	}

	@IBOutlet private weak var cameraButton: UIButton!

	@IBOutlet private weak var cameraUnavailableLabel: UILabel!

	@IBAction private func changeCamera(_ cameraButton: UIButton) {
		disableAllControls()
		cameraSession.isFront = !cameraSession.isFront
	}


	@IBAction private func focusAndExposeTap(_ gestureRecognizer: UITapGestureRecognizer) {
//		let devicePoint = cameraPreview.videoPreviewLayer.captureDevicePointConverted(fromLayerPoint: gestureRecognizer.location(in: cameraPreview))
//		cameraSession.focus(with: .autoFocus, exposureMode: .autoExpose, atDevicePoint: devicePoint, monitorSubjectAreaChange: true)
	}


	@IBOutlet private weak var photoButton: UIButton!

	@IBAction private func capturePhoto(_ photoButton: UIButton) {
		cameraSession.capturePhoto()
	}


	@IBOutlet private weak var resumeButton: UIButton!

	@IBAction private func resumeInterruptedSession(_ resumeButton: UIButton) {
		cameraSession.resumeInterruptedSession()
	}


	@IBOutlet private weak var recordButton: UIButton!

	@IBAction private func toggleMovieRecording(_ recordButton: UIButton) {

		cameraButton.isEnabled = false
		recordButton.isEnabled = false

		if cameraSession.isRecording {
			cameraSession.stopVideoRecording()
		}
		else {
			cameraSession.startVideoRecording()
		}
	}


	@IBOutlet weak var zoomButton: UIButton!

	@IBAction func zoomAction(_ sender: Any) {
		cameraSession.zoomLevel = cameraSession.zoomLevel == 1 ? 2 : 1
	}


	@IBOutlet weak var torchButton: UIButton!

	@IBAction func torchAction(_ sender: Any) {
		cameraSession.isTorchOn = !cameraSession.isTorchOn
	}
}


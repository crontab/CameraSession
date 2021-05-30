//
//  CameraViewController.swift
//
//  Created by Hovik Melikyan on 26/05/2019.
//  Copyright © 2019 Hovik Melikyan. All rights reserved.
//


import UIKit
import AVFoundation
import Photos


class CameraViewController: UIViewController, CameraSessionViewDelegate {

	func cameraSessionView(_ cameraSessionView: CameraSessionView, didCompleteConfigurationWithStatus status: CameraSessionView.Status) {
		switch status {
		case .undefined:
			preconditionFailure()

		case .configured:
			cameraButton.isEnabled = cameraSessionView.hasBackAndFront
			recordButton.isEnabled = cameraSessionView.isVideo
			photoButton.isEnabled = cameraSessionView.isPhoto
			captureModeControl.isEnabled = true
			captureModeControl.selectedSegmentIndex = cameraSessionView.isPhoto ? 0 : 1
			zoomButton.isEnabled = cameraSessionView.hasZoom
			zoomButton.isHidden = !cameraSessionView.hasZoom
			torchButton.isEnabled = cameraSessionView.hasTorch
			torchButton.isHidden = !cameraSessionView.hasTorch
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


	func cameraSessionViewDidChangeZoomLevel(_ cameraSessionView: CameraSessionView) {
		zoomButton.setTitle("\(Int(cameraSessionView.zoomLevel))x", for: .normal)
	}

	func cameraSessionViewWillCapturePhoto(_ cameraSessionView: CameraSessionView) {
		// Flash the screen to signal that CameraSessionView took a photo.
		self.cameraSessionView.alpha = 0
		UIView.animate(withDuration: 0.25) {
			self.cameraSessionView.alpha = 1
		}
	}


	func cameraSessionView(_ cameraSessionView: CameraSessionView, didCapturePhoto photo: AVCapturePhoto?, error: Error?) {
		guard let data = photo?.fileDataRepresentation() else {
			print("Error capturing the photo: \(error?.localizedDescription ?? "?")")
			return
		}
		cameraSessionView.stopSession() {
			PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
				if status == .authorized || status == .limited {
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
						DispatchQueue.main.async {
							self.cameraSessionView.startSession()
						}
					})
				}
				else {
					self.cameraSessionView.startSession()
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
			success = ((error! as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as AnyObject).boolValue ?? false
		}

		if success {
			// Check authorization status.
			PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
				if status == .authorized || status == .limited {
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


	func cameraSessionView(_ cameraSessionView: CameraSessionView, wasInterruptedWithError: Error?) {
		self.resumeButton.isHidden = false
	}


	func cameraSessionView(_ cameraSessionView: CameraSessionView, wasInterruptedWithReason reason: AVCaptureSession.InterruptionReason) {
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
			print("CameraSessionView error: Session stopped running due to shutdown system pressure level.")
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


	func cameraSessionView(_ cameraSessionView: CameraSessionView, didResumeInterruptedSessionWithResult result: Bool) {
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


	// - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - - -


	override func viewDidLoad() {
		super.viewDidLoad()
		disableAllControls()

		zoomButton.layer.borderColor = zoomButton.tintColor.cgColor
		zoomButton.layer.borderWidth = 1
		zoomButton.layer.cornerRadius = 5

		cameraSessionView.initialize(delegate: self, isPhoto: false, isFront: false)
	}


	private func disableAllControls() {
		cameraButton.isEnabled = false
		recordButton.isEnabled = false
		photoButton.isEnabled = false
		captureModeControl.isEnabled = false
		zoomButton.isEnabled = false
		torchButton.isEnabled = false
	}


	@IBOutlet private weak var cameraSessionView: CameraSessionView!


	private enum CaptureMode: Int {
		case photo = 0
		case movie = 1
	}

	@IBOutlet private weak var captureModeControl: UISegmentedControl!

	@IBAction private func toggleCaptureMode(_ captureModeControl: UISegmentedControl) {
		disableAllControls()
		cameraSessionView.isPhoto = captureModeControl.selectedSegmentIndex == CaptureMode.photo.rawValue
	}


	@IBOutlet private weak var cameraButton: UIButton!

	@IBOutlet private weak var cameraUnavailableLabel: UILabel!

	@IBAction private func changeCamera(_ cameraButton: UIButton) {
		disableAllControls()
		cameraSessionView.isFront = !cameraSessionView.isFront
	}


	@IBAction private func focusAndExposeTap(_ gestureRecognizer: UITapGestureRecognizer) {
		cameraSessionView.focus(with: .autoFocus, exposureMode: .autoExpose, atPoint: gestureRecognizer.location(in: cameraSessionView), monitorSubjectAreaChange: true)
	}


	@IBOutlet private weak var photoButton: UIButton!

	@IBAction private func capturePhoto(_ photoButton: UIButton) {
		cameraSessionView.capturePhoto()
	}


	@IBOutlet private weak var resumeButton: UIButton!

	@IBAction private func resumeInterruptedSession(_ resumeButton: UIButton) {
		cameraSessionView.resumeInterruptedSession()
	}


	@IBOutlet private weak var recordButton: UIButton!

	@IBAction private func toggleMovieRecording(_ recordButton: UIButton) {

		cameraButton.isEnabled = false
		recordButton.isEnabled = false
		captureModeControl.isEnabled = false

		if cameraSessionView.isRecording {
			cameraSessionView.stopVideoRecording()
		}
		else {
			let outputFileName = NSUUID().uuidString
			let outputFilePath = (NSTemporaryDirectory() as NSString).appendingPathComponent((outputFileName as NSString).appendingPathExtension("mp4")!)
			cameraSessionView.startVideoRecording(toFileURL: URL(fileURLWithPath: outputFilePath))
		}
	}


	@IBOutlet weak var zoomButton: UIButton!

	@IBAction func zoomAction(_ sender: Any) {
		cameraSessionView.zoomLevel = cameraSessionView.zoomLevel == 1 ? 2 : 1
	}


	@IBOutlet weak var torchButton: UIButton!

	@IBAction func torchAction(_ sender: Any) {
		cameraSessionView.isTorchOn = !cameraSessionView.isTorchOn
	}
}


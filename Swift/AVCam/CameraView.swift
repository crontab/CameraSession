
import UIKit
import AVFoundation


// TODO: implement session interruption observers


enum CameraViewStatus: Equatable {
	case undefined
	case configured
	case notAuthorized
	case configurationFailed(message: String)
}


protocol CameraViewDelegate: class {
	func cameraViewDidCompleteConfiguration(withStatus status: CameraViewStatus)
	func cameraViewSessionStarted()
}


class CameraView: UIView {

	var isPhoto: Bool = true // otherwise video
	var isFront: Bool = false


	func initialize(delegate: CameraViewDelegate, isPhoto: Bool, isFront: Bool) {
		precondition(status == .undefined)
		precondition(Thread.isMainThread)

		self.delegate = delegate
		self.isPhoto = isPhoto
		self.isFront = isFront

		if session == nil {
			session = AVCaptureSession()
			videoPreviewLayer.session = session
		}

		checkAuthorization() // runs on main thread, blocks the session thread

		queue.async {
			self.configureSession()
		}
	}


	deinit {
		removeObservers()
	}


	func focus(with focusMode: AVCaptureDevice.FocusMode, exposureMode: AVCaptureDevice.ExposureMode, at devicePoint: CGPoint,  monitorSubjectAreaChange: Bool) {

		queue.async {
			let device = self.videoDeviceInput.device
			do {
				try device.lockForConfiguration()
				if device.isFocusPointOfInterestSupported && device.isFocusModeSupported(focusMode) {
					device.focusPointOfInterest = devicePoint
					device.focusMode = focusMode
				}
				if device.isExposurePointOfInterestSupported && device.isExposureModeSupported(exposureMode) {
					device.exposurePointOfInterest = devicePoint
					device.exposureMode = exposureMode
				}
				device.isSubjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange
				device.unlockForConfiguration()
			} catch {
				print("CameraView error: Could not lock device for configuration: \(error)")
			}
		}
	}


	// Protected part: potentially everything here should be private

	// This view should have a AVCaptureVideoPreviewLayer as its main layer
	override class var layerClass: AnyClass { return AVCaptureVideoPreviewLayer.self }
	var videoPreviewLayer: AVCaptureVideoPreviewLayer { return layer as! AVCaptureVideoPreviewLayer }


	private weak var delegate: CameraViewDelegate?
	var status: CameraViewStatus = .undefined
	var isSessionRunning = false
	var videoDeviceInput: AVCaptureDeviceInput!
	let photoOutput = AVCapturePhotoOutput()

	private(set) var session: AVCaptureSession!

	lazy var queue = { return DispatchQueue(label: String(describing: self)) }()


	
	// - - -  SETUP


	private func checkAuthorization() {
		/*
		Check video authorization status. Video access is required and audio
		access is optional. If the user denies audio access, AVCam won't
		record audio during movie recording.
		*/
		switch AVCaptureDevice.authorizationStatus(for: .video) {
		case .authorized:
			// The user has previously granted access to the camera.
			break

		case .notDetermined:
			/*
			The user has not yet been presented with the option to grant
			video access. We suspend the session queue to delay session
			setup until the access request has completed.

			Note that audio access will be implicitly requested when we
			create an AVCaptureDeviceInput for audio during session setup.
			*/
			queue.suspend()
			AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
				if !granted {
					self.status = .notAuthorized
				}
				self.queue.resume()
			})

		default:
			// The user has previously denied access.
			status = .notAuthorized
		}
	}


	// Call this on the session queue.
	/// - Tag: ConfigureSession
	private func configureSession() {
		if status != .undefined {
			return
		}

		session.beginConfiguration()

		/*
		We do not create an AVCaptureMovieFileOutput when setting up the session because
		Live Photo is not supported when AVCaptureMovieFileOutput is added to the session.
		*/
		session.sessionPreset = .photo

		// Add video input.
		do {
			var defaultVideoDevice: AVCaptureDevice?

			// Choose the back dual camera if available, otherwise default to a wide angle camera.

			if let dualCameraDevice = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
				defaultVideoDevice = dualCameraDevice
			} else if let backCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
				// If a rear dual camera is not available, default to the rear wide angle camera.
				defaultVideoDevice = backCameraDevice
			} else if let frontCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) {
				// In the event that the rear wide angle camera isn't available, default to the front wide angle camera.
				defaultVideoDevice = frontCameraDevice
			}
			guard let videoDevice = defaultVideoDevice else {
				configurationFailed(message: "Default video device is unavailable.")
				return
			}
			let videoDeviceInput = try AVCaptureDeviceInput(device: videoDevice)

			if session.canAddInput(videoDeviceInput) {
				session.addInput(videoDeviceInput)
				self.videoDeviceInput = videoDeviceInput

				DispatchQueue.main.async {
					self.videoPreviewLayer.connection?.videoOrientation = .portrait
				}
			} else {
				configurationFailed(message: "Couldn't add video device input to the session.")
				return
			}
		} catch {
			configurationFailed(message: "Couldn't create video device input: \(error)")
			return
		}

		// Add audio input.
		do {
			let audioDevice = AVCaptureDevice.default(for: .audio)
			let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice!)

			if session.canAddInput(audioDeviceInput) {
				session.addInput(audioDeviceInput)
			} else {
				print("Could not add audio device input to the session")
			}
		} catch {
			print("Could not create audio device input: \(error)")
		}

		// Add photo output.
		if session.canAddOutput(photoOutput) {
			session.addOutput(photoOutput)

			photoOutput.isHighResolutionCaptureEnabled = true

		} else {
			configurationFailed(message: "Could not add photo output to the session")
			return
		}

		session.commitConfiguration()
		status = .configured

		addObservers()
		session.startRunning()
		isSessionRunning = self.session.isRunning

		DispatchQueue.main.async {
			self.delegate?.cameraViewDidCompleteConfiguration(withStatus: self.status)
		}
	}


	private func configurationFailed(message: String) {
		status = .configurationFailed(message: message)
		session.commitConfiguration()
		DispatchQueue.main.async {
			self.delegate?.cameraViewDidCompleteConfiguration(withStatus: self.status)
		}
	}


	// - - -  OBSERVERS

	private var keyValueObservations = [NSKeyValueObservation]()

	private func addObservers() {
		let keyValueObservation = session.observe(\.isRunning, options: .new) { _, change in
			if change.newValue ?? false {
				DispatchQueue.main.async {
					self.delegate?.cameraViewSessionStarted()
				}
			}
		}
		keyValueObservations.append(keyValueObservation)

		NotificationCenter.default.addObserver(self, selector: #selector(subjectAreaDidChange), name: .AVCaptureDeviceSubjectAreaDidChange, object: videoDeviceInput.device)

		// NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: .AVCaptureSessionRuntimeError, object: session)

		/*
		A session can only run when the app is full screen. It will be interrupted
		in a multi-app layout, introduced in iOS 9, see also the documentation of
		AVCaptureSessionInterruptionReason. Add observers to handle these session
		interruptions and show a preview is paused message. See the documentation
		of AVCaptureSessionWasInterruptedNotification for other interruption reasons.
		*/
		// NotificationCenter.default.addObserver(self, selector: #selector(sessionWasInterrupted), name: .AVCaptureSessionWasInterrupted, object: session)
		// NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded), name: AVCaptureSessionInterruptionEnded, object: session)
	}


	private func removeObservers() {
		NotificationCenter.default.removeObserver(self)

		for keyValueObservation in keyValueObservations {
			keyValueObservation.invalidate()
		}
		keyValueObservations.removeAll()
	}


	@objc
	func subjectAreaDidChange(notification: NSNotification) {
		let devicePoint = CGPoint(x: 0.5, y: 0.5)
		focus(with: .continuousAutoFocus, exposureMode: .continuousAutoExposure, at: devicePoint, monitorSubjectAreaChange: false)
	}

/*
	/// - Tag: HandleRuntimeError
	@objc
	func sessionRuntimeError(notification: NSNotification) {
		guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }

		print("Capture session runtime error: \(error)")
		// If media services were reset, and the last start succeeded, restart the session.
		if error.code == .mediaServicesWereReset {
			queue.async {
				if self.session.isSessionRunning {
					self.session.startRunning()
					self.isSessionRunning = self.session.isRunning
				} else {
					DispatchQueue.main.async {
						self.resumeButton.isHidden = false
					}
				}
			}
		} else {
			resumeButton.isHidden = false
		}
	}


	/// - Tag: HandleInterruption
	@objc
	func sessionWasInterrupted(notification: NSNotification) {
		/*
		In some scenarios we want to enable the user to resume the session running.
		For example, if music playback is initiated via control center while
		using AVCam, then the user can let AVCam resume
		the session running, which will stop music playback. Note that stopping
		music playback in control center will not automatically resume the session
		running. Also note that it is not always possible to resume, see `resumeInterruptedSession(_:)`.
		*/
		if let userInfoValue = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as AnyObject?,
			let reasonIntegerValue = userInfoValue.integerValue,
			let reason = AVCaptureSession.InterruptionReason(rawValue: reasonIntegerValue) {
			print("Capture session was interrupted with reason \(reason)")

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
				print("Session stopped running due to shutdown system pressure level.")
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
	}

	@objc
	func sessionInterruptionEnded(notification: NSNotification) {
		print("Capture session interruption ended")

		if !resumeButton.isHidden {
			UIView.animate(withDuration: 0.25,
						   animations: {
							self.resumeButton.alpha = 0
			}, completion: { _ in
				self.resumeButton.isHidden = true
			})
		}
		if !cameraUnavailableLabel.isHidden {
			UIView.animate(withDuration: 0.25,
						   animations: {
							self.cameraUnavailableLabel.alpha = 0
			}, completion: { _ in
				self.cameraUnavailableLabel.isHidden = true
			}
			)
		}
	}
*/
}

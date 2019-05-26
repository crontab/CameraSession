
import UIKit
import AVFoundation


// TODO: implement session interruption observers


private let VIDEO_SESSION_PRESET = AVCaptureSession.Preset.hd1920x1080


enum CameraViewStatus: Equatable {
	case undefined
	case configured
	case notAuthorized
	case configurationFailed(message: String)
}


protocol CameraViewDelegate: class {
	func cameraView(_ cameraView: CameraView, didCompleteConfigurationWithStatus status: CameraViewStatus)
}


class CameraView: UIView {

	var isPhoto: Bool = true {
		didSet {
			if status == .configured && oldValue != isPhoto {
				didSwitchPhotoVideoMode()
			}
		}
	}

	var isVideo: Bool {
		get { return !isPhoto }
		set { isPhoto = !newValue }
	}

	var isFront: Bool = false

	var hasBackAndFront: Bool {
		return videoDeviceDiscoverySession.uniqueDevicePositions.count > 0
	}


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

		if queue == nil {
			queue = DispatchQueue(label: String(describing: self))
		}

		checkAuthorization() // runs on main thread, blocks the session thread if UI is involved

		queue.async {
			self.configureSession()
		}
	}


	deinit {
		removeObservers()
	}


	// TODO: take the point in view coordinates, convert
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
	var audioDeviceInput: AVCaptureDeviceInput?
	var videoOutput: AVCaptureMovieFileOutput?
	var photoOutput: AVCapturePhotoOutput?

	// TODO: add .builtinTelelensCamera discovery
	let videoDeviceDiscoverySession = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTrueDepthCamera], mediaType: .video, position: .unspecified)


	private(set) var session: AVCaptureSession!
	private(set) var queue: DispatchQueue!


	
	// - - -  SETUP


	private func checkAuthorization() {
		switch AVCaptureDevice.authorizationStatus(for: .video) {
		case .authorized:
			break

		case .notDetermined:
			queue.suspend()
			AVCaptureDevice.requestAccess(for: .video, completionHandler: { granted in
				if !granted {
					self.status = .notAuthorized
				}
				self.queue.resume()
			})

		default:
			status = .notAuthorized
		}
	}


	private func didSwitchPhotoVideoMode() {
		queue.async {
			self.configureSession()
		}
	}


	// Call this on the session queue.
	private func configureSession() {
		precondition(!Thread.isMainThread)

		guard status == .undefined || status == .configured else {
			return
		}

		session.beginConfiguration()

		session.sessionPreset = isPhoto ? .photo : VIDEO_SESSION_PRESET

		configureVideoInput()
		configureAudioInput()
		configureVideoOutput()
		configurePhotoOutput()

		session.commitConfiguration()

		if status == .undefined {
			addObservers()
		}

		status = .configured
		session.startRunning()
		isSessionRunning = self.session.isRunning

		DispatchQueue.main.async {
			self.delegate?.cameraView(self, didCompleteConfigurationWithStatus: self.status)
		}
	}


	private func configureVideoInput() {
		if videoDeviceInput == nil {
			do {
				if let videoDevice = findMatchingDevice() {
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
				}
				else {
					configurationFailed(message: "No cameras found on this device. Is this a rotary phone or what?")
				}
			} catch {
				configurationFailed(message: "Couldn't create video device input: \(error)")
				return
			}
		}
	}


	private func findMatchingDevice() -> AVCaptureDevice? {
		let type: AVCaptureDevice.DeviceType = isFront ? .builtInWideAngleCamera : .builtInDualCamera
		let position: AVCaptureDevice.Position = isFront ? .front : .back

		// First, look for a device with both the preferred position and device type
		if let device = videoDeviceDiscoverySession.devices.first(where: { $0.deviceType == type && $0.position == position }) {
			return device
		}

		// Otherwise, look for a device with only the preferred position
		if let device = videoDeviceDiscoverySession.devices.first(where: { $0.position == position }) {
			return device
		}

		// Or else, return just any device
		return videoDeviceDiscoverySession.devices.first
	}


	private func configureAudioInput() {
		if isVideo && audioDeviceInput == nil {
			do {
				let audioDevice = AVCaptureDevice.default(for: .audio)
				let audioDeviceInput = try AVCaptureDeviceInput(device: audioDevice!)
				if session.canAddInput(audioDeviceInput) {
					session.addInput(audioDeviceInput)
					self.audioDeviceInput = audioDeviceInput
				} else {
					print("CameraView error: Could not add audio device input to the session")
				}
			} catch {
				print("CameraView error: Could not create audio device input: \(error)")
			}
		}
		else if !isVideo, let audioDeviceInput = audioDeviceInput {
			session.removeInput(audioDeviceInput)
			self.audioDeviceInput = nil
		}
	}


	private func configureVideoOutput() {
		if isVideo && videoOutput == nil {
			let videoOutput = AVCaptureMovieFileOutput()
			if session.canAddOutput(videoOutput) {
				session.addOutput(videoOutput)
				if let connection = videoOutput.connection(with: .video) {
					if connection.isVideoStabilizationSupported {
						connection.preferredVideoStabilizationMode = .auto
					}
				}
				self.videoOutput = videoOutput
			}
		}
		else if !isVideo, let videoOutput = videoOutput {
			session.removeOutput(videoOutput)
			self.videoOutput = nil
		}
	}


	private func configurePhotoOutput() {
		if isPhoto && photoOutput == nil {
			let photoOutput = AVCapturePhotoOutput()
			if session.canAddOutput(photoOutput) {
				session.addOutput(photoOutput)
				photoOutput.isHighResolutionCaptureEnabled = true
				self.photoOutput = photoOutput
			} else {
				configurationFailed(message: "Could not add photo output to the session")
				return
			}
		}
		else if !isPhoto, let photoOutput = photoOutput {
			session.removeOutput(photoOutput)
			self.photoOutput = nil
		}
	}


	private func configurationFailed(message: String) {
		status = .configurationFailed(message: message)
		session.commitConfiguration()
		DispatchQueue.main.async {
			self.delegate?.cameraView(self, didCompleteConfigurationWithStatus: self.status)
		}
	}


	// - - -  OBSERVERS

	private var keyValueObservations = [NSKeyValueObservation]()

	private func addObservers() {
//		let keyValueObservation = session.observe(\.isRunning, options: .new) { _, change in
//			if change.newValue ?? false {
//				DispatchQueue.main.async {
//					self.delegate?.cameraViewSessionStarted(self)
//				}
//			}
//		}
//		keyValueObservations.append(keyValueObservation)

		// TODO: add/remove should be done in configureSession() since the device can change
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

		print("CameraView error: Capture session runtime error: \(error)")
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
			print("CameraView error: Capture session was interrupted with reason \(reason)")

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
				print("CameraView error: Session stopped running due to shutdown system pressure level.")
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
		print("CameraView error: Capture session interruption ended")

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


private extension AVCaptureDevice.DiscoverySession {
	var uniqueDevicePositions: [AVCaptureDevice.Position] {
		var result: [AVCaptureDevice.Position] = []
		for device in devices {
			if !result.contains(device.position) {
				result.append(device.position)
			}
		}
		return result
	}
}
